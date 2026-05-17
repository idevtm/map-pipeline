#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/refresh-martin.sh

Regenerates data/martin/config.yaml from published catalogues and style files, then refreshes Martin.
Use this after adding, removing, or editing styles without publishing new MBTiles.
EOF
}

main() {
  load_env
  ensure_directories

  if [[ $# -gt 0 ]]; then
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage
        exit 1
        ;;
    esac
  fi

  require_command docker

  generate_martin_config

  log "refreshing Martin"
  compose up -d martin >/dev/null
  compose restart martin >/dev/null

  log "Martin refreshed"
}

main "$@"
