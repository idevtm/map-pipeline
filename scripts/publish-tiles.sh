#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/publish-tiles.sh [--catalogue NAME] [--style-template PATH|--no-style-template] <path-to.mbtiles>

Validates an MBTiles artifact, atomically promotes it to
data/published/<catalogue>/current.mbtiles, refreshes Martin, and cleans up old build artifacts.

Options:
  --catalogue NAME       Catalogue to publish under. Inferred from data/build/<catalogue>/ when omitted.
  --catalog NAME         Alias for --catalogue.
  --style-template PATH  Template used to create data/styles/<catalogue>/default.json when missing.
                         Default: templates/styles/default.json.
  --no-style-template    Do not create a default style for this publish.
EOF
}

parse_args() {
  PUBLISH_CATALOGUE=""
  PUBLISH_MBTILES_ARG=""
  PUBLISH_STYLE_TEMPLATE="${REPO_ROOT}/templates/styles/default.json"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --catalogue|--catalog)
        [[ $# -ge 2 ]] || die "missing value for $1"
        PUBLISH_CATALOGUE="$2"
        shift 2
        ;;
      --catalogue=*|--catalog=*)
        PUBLISH_CATALOGUE="${1#*=}"
        shift
        ;;
      --style-template)
        [[ $# -ge 2 ]] || die "missing value for --style-template"
        PUBLISH_STYLE_TEMPLATE="$2"
        shift 2
        ;;
      --style-template=*)
        PUBLISH_STYLE_TEMPLATE="${1#*=}"
        shift
        ;;
      --no-style-template)
        PUBLISH_STYLE_TEMPLATE=""
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        if [[ -n "${PUBLISH_MBTILES_ARG}" ]]; then
          die "only one MBTiles file is supported"
        fi
        PUBLISH_MBTILES_ARG="$1"
        shift
        ;;
    esac
  done

  if [[ $# -gt 0 ]]; then
    [[ -z "${PUBLISH_MBTILES_ARG}" && $# -eq 1 ]] || die "unexpected extra arguments"
    PUBLISH_MBTILES_ARG="${1:-${PUBLISH_MBTILES_ARG}}"
  fi

  [[ -n "${PUBLISH_MBTILES_ARG}" ]] || {
    usage
    exit 1
  }

  if [[ -n "${PUBLISH_CATALOGUE}" ]]; then
    validate_catalogue_name "${PUBLISH_CATALOGUE}"
  fi
}

create_default_style_if_missing() {
  local catalogue="$1"
  local template_path="$2"
  local style_dir="${STYLES_DIR}/${catalogue}"
  local style_path="${style_dir}/default.json"
  local resolved_template

  AUTO_CREATED_STYLE_PATH=""

  if [[ -z "${template_path}" ]]; then
    log "default style creation disabled for catalogue ${catalogue}"
    return 0
  fi

  if [[ -e "${style_path}" ]]; then
    log "default style already exists for catalogue ${catalogue}: ${style_path}"
    return 0
  fi

  require_command python3

  resolved_template=$(resolve_path "${template_path}") || die "unable to resolve style template path: ${template_path}"
  [[ -f "${resolved_template}" ]] || die "style template not found: ${template_path}"

  mkdir -p -- "${style_dir}"

  CATALOGUE="${catalogue}" \
    TEMPLATE_PATH="${resolved_template}" \
    STYLE_PATH="${style_path}" \
    python3 - <<'PY'
import json
import os
from pathlib import Path


catalogue = os.environ["CATALOGUE"]
template_path = Path(os.environ["TEMPLATE_PATH"])
style_path = Path(os.environ["STYLE_PATH"])
temp_path = style_path.with_name(f".{style_path.name}.tmp")


def fail(message: str) -> None:
    raise SystemExit(message)


try:
    data = json.loads(template_path.read_text(encoding="utf-8"))
except json.JSONDecodeError as exc:
    fail(f"invalid JSON in style template {template_path}: {exc}")

if data.get("version") != 8:
    fail(f"style template {template_path} must use MapLibre style version 8")

sources = data.get("sources")
if not isinstance(sources, dict):
    fail(f"style template {template_path} must define sources")

basemap = sources.get("basemap")
if not isinstance(basemap, dict):
    fail(f"style template {template_path} must define a basemap source object")

for layer in data.get("layers", []):
    if not isinstance(layer, dict):
        fail(f"style template {template_path} contains a non-object layer")
    source_id = layer.get("source")
    if source_id is not None and source_id not in sources:
        layer_id = layer.get("id", "<unknown>")
        fail(f"style template {template_path} layer {layer_id} references missing source {source_id!r}")

display_name = catalogue.replace("-", " ").replace("_", " ").title()
data["name"] = f"{display_name} Default"
data["sources"]["basemap"]["url"] = f"/{catalogue}"

temp_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
temp_path.replace(style_path)
PY

  AUTO_CREATED_STYLE_PATH="${style_path}"
  log "created default style for catalogue ${catalogue}: ${style_path}"
}

sqlite_scalar() {
  local db_path="$1"
  local sql="$2"

  sqlite3 -batch -noheader "${db_path}" "${sql}"
}

validate_mbtiles() {
  local mbtiles_path="$1"
  local quick_check
  local has_metadata_table
  local tile_count
  local key

  require_command sqlite3

  quick_check=$(sqlite_scalar "${mbtiles_path}" 'PRAGMA quick_check;')
  [[ "${quick_check}" == "ok" ]] || die "SQLite quick_check failed for ${mbtiles_path}: ${quick_check}"

  has_metadata_table=$(sqlite_scalar "${mbtiles_path}" "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'metadata';")
  [[ "${has_metadata_table}" == "1" ]] || die "metadata table missing from ${mbtiles_path}"

  for key in name format minzoom maxzoom; do
    [[ "$(sqlite_scalar "${mbtiles_path}" "SELECT COUNT(*) FROM metadata WHERE name = '${key}' AND value IS NOT NULL AND value != '';" )" =~ ^[1-9][0-9]*$ ]] \
      || die "required metadata key missing or empty: ${key}"
  done

  tile_count=$(sqlite_scalar "${mbtiles_path}" 'SELECT COUNT(*) FROM tiles;')
  [[ "${tile_count}" =~ ^[1-9][0-9]*$ ]] || die "tiles table is empty in ${mbtiles_path}"
}

cleanup_builds() {
  local catalogue="$1"
  local current_target="$2"
  local retention="$3"
  local index=0
  local build_dir
  local build_path

  build_dir=$(catalogue_build_dir "${catalogue}")
  [[ -d "${build_dir}" ]] || return 0

  while IFS= read -r build_path; do
    index=$((index + 1))
    if [[ "${index}" -le "${retention}" ]]; then
      continue
    fi

    if [[ "$(resolve_path "${build_path}")" == "${current_target}" ]]; then
      continue
    fi

    log "removing old build artifact ${build_path}"
    rm -f -- "${build_path}"
  done < <(find "${build_dir}" -maxdepth 1 -type f -name '*.mbtiles' -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)
}

refresh_martin() {
  log "refreshing Martin"
  compose up -d martin >/dev/null
  compose restart martin >/dev/null
}

main() {
  load_env
  ensure_directories

  require_command docker

  parse_args "$@"

  local mbtiles_arg="${PUBLISH_MBTILES_ARG}"
  local catalogue="${PUBLISH_CATALOGUE}"
  local mbtiles_path
  local temp_link
  local current_link
  local current_target
  local relative_target
  local published_dir
  local config_backup
  local had_previous_link=0
  local previous_relative_target=""
  AUTO_CREATED_STYLE_PATH=""

  mbtiles_path=$(resolve_path "${mbtiles_arg}") || die "unable to resolve MBTiles path: ${mbtiles_arg}"

  [[ -f "${mbtiles_path}" ]] || die "MBTiles file not found: ${mbtiles_path}"
  [[ "${mbtiles_path}" == *.mbtiles ]] || die "publish input must end with .mbtiles: ${mbtiles_path}"
  assert_mbtiles_in_build_dir "${mbtiles_path}"

  if [[ -z "${catalogue}" ]]; then
    catalogue=$(infer_catalogue_from_mbtiles_path "${mbtiles_path}")
  fi
  validate_catalogue_name "${catalogue}"
  ensure_catalogue_directories "${catalogue}"

  log "validating ${mbtiles_path}"
  validate_mbtiles "${mbtiles_path}"

  config_backup=$(mktemp "${MARTIN_CONFIG_PATH}.backup.XXXXXX")
  if [[ -f "${MARTIN_CONFIG_PATH}" ]]; then
    cp -- "${MARTIN_CONFIG_PATH}" "${config_backup}"
  else
    : > "${config_backup}"
  fi
  trap 'rm -f -- "${config_backup}"' EXIT

  relative_target=$(relative_published_target "${catalogue}" "${mbtiles_path}")
  published_dir=$(catalogue_published_dir "${catalogue}")
  temp_link="${published_dir}/current.mbtiles.next"
  current_link="${published_dir}/current.mbtiles"

  if [[ -e "${current_link}" && ! -L "${current_link}" ]]; then
    die "published target exists but is not a symlink: ${current_link}"
  fi

  if [[ -L "${current_link}" ]]; then
    had_previous_link=1
    previous_relative_target=$(readlink "${current_link}")
  fi

  ln -sfn "${relative_target}" "${temp_link}"
  mv -Tf -- "${temp_link}" "${current_link}"

  create_default_style_if_missing "${catalogue}" "${PUBLISH_STYLE_TEMPLATE}"
  generate_martin_config
  refresh_martin

  log "running smoke tests"
  if ! "${SCRIPT_DIR}/smoke-test.sh" --catalogue "${catalogue}" >/dev/null; then
    if [[ "${had_previous_link}" -eq 1 ]]; then
      log "smoke tests failed; rolling back published symlink"
      ln -sfn "${previous_relative_target}" "${temp_link}"
      mv -Tf -- "${temp_link}" "${current_link}"
    else
      log "smoke tests failed; removing newly published symlink"
      rm -f -- "${current_link}"
    fi
    if [[ -n "${AUTO_CREATED_STYLE_PATH}" ]]; then
      log "removing auto-created default style after failed publish: ${AUTO_CREATED_STYLE_PATH}"
      rm -f -- "${AUTO_CREATED_STYLE_PATH}"
    fi
    mv -f -- "${config_backup}" "${MARTIN_CONFIG_PATH}"
    trap - EXIT
    refresh_martin || true
    die "smoke tests failed after publish"
  fi

  rm -f -- "${config_backup}"
  trap - EXIT

  current_target=$(resolve_path "${current_link}")
  cleanup_builds "${catalogue}" "${current_target}" "${BUILD_RETENTION}"

  log "published ${mbtiles_path} as catalogue ${catalogue} at ${current_link}"
  printf '%s\n' "${current_link}"
}

main "$@"
