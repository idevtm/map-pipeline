#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/rebuild-and-publish.sh [--catalogue NAME] [--tile-format mvt|mlt] [--mlt] [--style-template PATH|--no-style-template] <path-to.osm.pbf>

Runs the full pipeline: build a versioned MBTiles artifact, validate it, publish it atomically,
and refresh Martin.

Options:
  --catalogue NAME      Catalogue to build and publish. Default: DEFAULT_CATALOGUE or basemap.
  --catalog NAME        Alias for --catalogue.
  --tile-format FORMAT  Output tile payload format. Supported: mvt, mlt.
  --mlt                 Shortcut for --tile-format mlt.
  --style-template PATH Template used to create data/styles/<catalogue>/default.json when missing.
  --no-style-template   Do not create a default style for this publish.
EOF
}

parse_args() {
  REBUILD_CATALOGUE="${DEFAULT_CATALOGUE}"
  REBUILD_TILE_FORMAT="mvt"
  REBUILD_INPUT_PATH=""
  REBUILD_STYLE_TEMPLATE_ARGS=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --catalogue|--catalog)
        [[ $# -ge 2 ]] || die "missing value for $1"
        REBUILD_CATALOGUE="$2"
        shift 2
        ;;
      --catalogue=*|--catalog=*)
        REBUILD_CATALOGUE="${1#*=}"
        shift
        ;;
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
      --style-template)
        [[ $# -ge 2 ]] || die "missing value for --style-template"
        REBUILD_STYLE_TEMPLATE_ARGS=(--style-template "$2")
        shift 2
        ;;
      --style-template=*)
        REBUILD_STYLE_TEMPLATE_ARGS=(--style-template "${1#*=}")
        shift
        ;;
      --no-style-template)
        REBUILD_STYLE_TEMPLATE_ARGS=(--no-style-template)
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

  validate_catalogue_name "${REBUILD_CATALOGUE}"

  [[ -n "${REBUILD_INPUT_PATH}" ]] || {
    usage
    exit 1
  }
}

main() {
  load_env
  parse_args "$@"

  local input_path="${REBUILD_INPUT_PATH}"
  local built_mbtiles

  log "starting rebuild-and-publish for catalogue ${REBUILD_CATALOGUE}: ${input_path} with tile format ${REBUILD_TILE_FORMAT}"
  built_mbtiles=$("${SCRIPT_DIR}/build-tiles.sh" --catalogue "${REBUILD_CATALOGUE}" --tile-format "${REBUILD_TILE_FORMAT}" "${input_path}")
  "${SCRIPT_DIR}/publish-tiles.sh" --catalogue "${REBUILD_CATALOGUE}" "${REBUILD_STYLE_TEMPLATE_ARGS[@]}" "${built_mbtiles}" >/dev/null
  log "pipeline completed successfully"
}

main "$@"
