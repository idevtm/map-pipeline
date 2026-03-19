#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/rebuild-and-publish.sh <path-to.osm.pbf>

Runs the full pipeline: build a versioned MBTiles artifact, validate it, publish it atomically,
and restart Martin.
EOF
}

main() {
  if [[ $# -ne 1 ]]; then
    usage
    exit 1
  fi

  local input_path="$1"
  local built_mbtiles

  log "starting rebuild-and-publish for ${input_path}"
  built_mbtiles=$("${SCRIPT_DIR}/build-tiles.sh" "${input_path}")
  "${SCRIPT_DIR}/publish-tiles.sh" "${built_mbtiles}" >/dev/null
  log "pipeline completed successfully"
}

main "$@"
