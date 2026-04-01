#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/rebuild-and-publish.sh [--tile-format mvt|mlt] [--mlt] <path-to.osm.pbf>

Runs the full pipeline: build a versioned MBTiles artifact, validate it, publish it atomically,
and restart Martin.
EOF
}

parse_args() {
  REBUILD_TILE_FORMAT="mvt"
  REBUILD_INPUT_PATH=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tile-format)
        [[ $# -ge 2 ]] || die "missing value for --tile-format"
        REBUILD_TILE_FORMAT="$2"
        shift 2
        ;;
      --tile-format=*)
        REBUILD_TILE_FORMAT="${1#*=}"
        shift
        ;;
      --mlt)
        REBUILD_TILE_FORMAT="mlt"
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
        if [[ -n "${REBUILD_INPUT_PATH}" ]]; then
          die "only one input file is supported"
        fi
        REBUILD_INPUT_PATH="$1"
        shift
        ;;
    esac
  done

  if [[ $# -gt 0 ]]; then
    [[ -z "${REBUILD_INPUT_PATH}" && $# -eq 1 ]] || die "unexpected extra arguments"
    REBUILD_INPUT_PATH="${1:-${REBUILD_INPUT_PATH}}"
  fi

  case "${REBUILD_TILE_FORMAT}" in
    mvt|mlt) ;;
    *) die "unsupported tile format: ${REBUILD_TILE_FORMAT} (expected mvt or mlt)" ;;
  esac

  [[ -n "${REBUILD_INPUT_PATH}" ]] || {
    usage
    exit 1
  }
}

main() {
  parse_args "$@"

  local input_path="${REBUILD_INPUT_PATH}"
  local built_mbtiles

  log "starting rebuild-and-publish for ${input_path} with tile format ${REBUILD_TILE_FORMAT}"
  built_mbtiles=$("${SCRIPT_DIR}/build-tiles.sh" --tile-format "${REBUILD_TILE_FORMAT}" "${input_path}")
  "${SCRIPT_DIR}/publish-tiles.sh" "${built_mbtiles}" >/dev/null
  log "pipeline completed successfully"
}

main "$@"
