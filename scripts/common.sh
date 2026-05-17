#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd -P)

log() {
  printf '[map-pipeline] %s\n' "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

resolve_path() {
  readlink -f -- "$1"
}

load_env() {
  local env_file="${REPO_ROOT}/.env"

  if [[ -f "${env_file}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
  fi

  : "${MARTIN_PORT:=3000}"
  if [[ -z "${DEFAULT_CATALOGUE:-}" ]]; then
    DEFAULT_CATALOGUE="${TILESET_NAME:-basemap}"
  fi
  : "${TILESET_NAME:=${DEFAULT_CATALOGUE}}"
  : "${MARTIN_WEBUI:=enable-for-all}"
  case "${MARTIN_WEBUI}" in
    enable-for-all|disable) ;;
    *) die "unsupported MARTIN_WEBUI value: ${MARTIN_WEBUI} (expected enable-for-all or disable)" ;;
  esac
  : "${PLANETILER_JAVA_XMX:=8g}"
  : "${PLANETILER_STORAGE:=mmap}"
  : "${BUILD_RETENTION:=3}"
  : "${MARTIN_CONTAINER_NAME:=map-pipeline-martin}"

  PLANETILER_RUNTIME_IMAGE="map-pipeline-planetiler:local"

  DATA_DIR="${REPO_ROOT}/data"
  DATA_INCOMING_DIR="${DATA_DIR}/incoming"
  DATA_BUILD_DIR="${DATA_DIR}/build"
  DATA_PUBLISHED_DIR="${DATA_DIR}/published"
  DATA_CACHE_DIR="${DATA_DIR}/cache"
  PLANETILER_CACHE_DIR="${DATA_CACHE_DIR}/planetiler"
  STYLES_DIR="${DATA_DIR}/styles"
  MARTIN_CONFIG_PATH="${REPO_ROOT}/martin/config.yaml"
}

ensure_directories() {
  mkdir -p \
    "${DATA_INCOMING_DIR}" \
    "${DATA_BUILD_DIR}" \
    "${DATA_PUBLISHED_DIR}" \
    "${PLANETILER_CACHE_DIR}/downloads" \
    "${PLANETILER_CACHE_DIR}/tmp" \
    "${STYLES_DIR}"

  migrate_legacy_default_catalogue
}

compose() {
  (
    cd -- "${REPO_ROOT}"
    docker compose "$@"
  )
}

assert_mbtiles_in_build_dir() {
  local mbtiles_path="$1"

  case "${mbtiles_path}" in
    "${DATA_BUILD_DIR}"/*) ;;
    *) die "publish input must live under ${DATA_BUILD_DIR}: ${mbtiles_path}" ;;
  esac
}

validate_catalogue_name() {
  local catalogue="$1"

  [[ "${catalogue}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] \
    || die "invalid catalogue name: ${catalogue} (use letters, numbers, underscores, and hyphens)"
}

catalogue_build_dir() {
  local catalogue="$1"
  validate_catalogue_name "${catalogue}"
  printf '%s/%s\n' "${DATA_BUILD_DIR}" "${catalogue}"
}

catalogue_published_dir() {
  local catalogue="$1"
  validate_catalogue_name "${catalogue}"
  printf '%s/%s\n' "${DATA_PUBLISHED_DIR}" "${catalogue}"
}

ensure_catalogue_directories() {
  local catalogue="$1"
  mkdir -p "$(catalogue_build_dir "${catalogue}")" "$(catalogue_published_dir "${catalogue}")"
}

relative_published_target() {
  local catalogue="$1"
  local mbtiles_path="$2"
  local published_dir

  published_dir=$(catalogue_published_dir "${catalogue}")
  realpath --relative-to="${published_dir}" "${mbtiles_path}"
}

infer_catalogue_from_mbtiles_path() {
  local mbtiles_path="$1"
  local relative_path
  local first_component

  relative_path=$(realpath --relative-to="${DATA_BUILD_DIR}" "${mbtiles_path}")
  first_component="${relative_path%%/*}"

  if [[ "${relative_path}" != "${first_component}" && "${first_component}" != "." && "${first_component}" != ".." ]]; then
    validate_catalogue_name "${first_component}"
    printf '%s\n' "${first_component}"
    return
  fi

  printf '%s\n' "${DEFAULT_CATALOGUE}"
}

migrate_legacy_default_catalogue() {
  local legacy_link="${DATA_PUBLISHED_DIR}/current.mbtiles"
  local default_dir="${DATA_PUBLISHED_DIR}/${DEFAULT_CATALOGUE}"
  local default_link="${default_dir}/current.mbtiles"

  if [[ -L "${legacy_link}" && ! -e "${default_link}" && ! -L "${default_link}" ]]; then
    mkdir -p "${default_dir}"
    ln -s ../current.mbtiles "${default_link}"
  fi
}

style_id_from_path() {
  local catalogue="$1"
  local style_path="$2"
  local style_name

  style_name=$(basename -- "${style_path}" .json)
  if [[ "${style_name}" == "default" ]]; then
    printf '%s\n' "${catalogue}"
  else
    printf '%s-%s\n' "${catalogue}" "${style_name}"
  fi
}

style_ids_for_catalogue() {
  local catalogue="$1"
  local style_dir="${STYLES_DIR}/${catalogue}"
  local style_path

  validate_catalogue_name "${catalogue}"
  [[ -d "${style_dir}" ]] || return 0

  while IFS= read -r style_path; do
    style_id_from_path "${catalogue}" "${style_path}"
  done < <(find "${style_dir}" -maxdepth 1 -type f -name '*.json' | sort)
}

generate_martin_config() {
  "${SCRIPT_DIR}/generate-martin-config.sh" >/dev/null
}

build_planetiler_runtime_image() {
  log "building local Planetiler runtime image"
  docker build \
    -t "${PLANETILER_RUNTIME_IMAGE}" \
    "${REPO_ROOT}/docker/planetiler"
}
