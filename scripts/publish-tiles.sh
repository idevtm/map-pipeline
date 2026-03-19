#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/publish-tiles.sh <path-to.mbtiles>

Validates an MBTiles artifact, atomically promotes it to current.mbtiles, restarts Martin,
and cleans up old build artifacts.
EOF
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
  local current_target="$1"
  local retention="$2"
  local index=0
  local build_path

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
  done < <(find "${DATA_BUILD_DIR}" -maxdepth 1 -type f -name '*.mbtiles' -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)
}

main() {
  load_env
  ensure_directories

  require_command docker

  if [[ $# -ne 1 ]]; then
    usage
    exit 1
  fi

  local mbtiles_arg="$1"
  local mbtiles_path
  local temp_link
  local current_link
  local current_target
  local relative_target
  local previous_target=""
  local previous_relative_target=""

  mbtiles_path=$(resolve_path "${mbtiles_arg}") || die "unable to resolve MBTiles path: ${mbtiles_arg}"

  [[ -f "${mbtiles_path}" ]] || die "MBTiles file not found: ${mbtiles_path}"
  [[ "${mbtiles_path}" == *.mbtiles ]] || die "publish input must end with .mbtiles: ${mbtiles_path}"
  assert_mbtiles_in_build_dir "${mbtiles_path}"

  log "validating ${mbtiles_path}"
  validate_mbtiles "${mbtiles_path}"

  relative_target=$(relative_published_target "${mbtiles_path}")
  temp_link="${DATA_PUBLISHED_DIR}/current.mbtiles.next"
  current_link="${DATA_PUBLISHED_DIR}/current.mbtiles"

  if [[ -L "${current_link}" ]]; then
    previous_target=$(resolve_path "${current_link}")
    previous_relative_target=$(readlink "${current_link}")
  fi

  ln -sfn "${relative_target}" "${temp_link}"
  mv -Tf -- "${temp_link}" "${current_link}"

  log "restarting Martin"
  compose restart martin >/dev/null

  log "running smoke tests"
  if ! "${SCRIPT_DIR}/smoke-test.sh" >/dev/null; then
    if [[ -n "${previous_relative_target}" ]]; then
      log "smoke tests failed; rolling back published symlink"
      ln -sfn "${previous_relative_target}" "${temp_link}"
      mv -Tf -- "${temp_link}" "${current_link}"
      compose restart martin >/dev/null || true
    fi
    die "smoke tests failed after publish"
  fi

  current_target=$(resolve_path "${current_link}")
  cleanup_builds "${current_target}" "${BUILD_RETENTION}"

  log "published ${mbtiles_path} as ${current_link}"
  printf '%s\n' "${current_link}"
}

main "$@"
