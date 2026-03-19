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
  : "${TILESET_NAME:=basemap}"
  : "${PLANETILER_JAVA_XMX:=8g}"
  : "${PLANETILER_STORAGE:=mmap}"
  : "${PLANETILER_IMAGE:=ghcr.io/onthegomap/planetiler:0.10.1}"
  : "${MARTIN_IMAGE:=ghcr.io/maplibre/martin:latest}"
  : "${BUILD_RETENTION:=3}"
  : "${MARTIN_CONTAINER_NAME:=map-pipeline-martin}"

  DATA_DIR="${REPO_ROOT}/data"
  DATA_INCOMING_DIR="${DATA_DIR}/incoming"
  DATA_BUILD_DIR="${DATA_DIR}/build"
  DATA_PUBLISHED_DIR="${DATA_DIR}/published"
  DATA_CACHE_DIR="${DATA_DIR}/cache"
  PLANETILER_CACHE_DIR="${DATA_CACHE_DIR}/planetiler"
}

ensure_directories() {
  mkdir -p \
    "${DATA_INCOMING_DIR}" \
    "${DATA_BUILD_DIR}" \
    "${DATA_PUBLISHED_DIR}" \
    "${PLANETILER_CACHE_DIR}/downloads" \
    "${PLANETILER_CACHE_DIR}/tmp"
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

relative_published_target() {
  local mbtiles_path="$1"
  printf '../build/%s\n' "$(basename -- "${mbtiles_path}")"
}
