#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/smoke-test.sh [base-url]

Verifies the live Martin endpoints used by this repository:
- /catalog
- /basemap
- /style/basemap
- /style/basemap-labels
EOF
}

wait_for_http() {
  local url="$1"
  local attempts="${2:-30}"
  local delay_seconds="${3:-1}"
  local attempt=1

  while (( attempt <= attempts )); do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep "${delay_seconds}"
    attempt=$((attempt + 1))
  done

  return 1
}

validate_catalog() {
  local payload="$1"

  BASE_URL="${2}" TILESET_NAME="${TILESET_NAME}" python3 - <<'PY' <<<"${payload}"
import json
import os
import sys

data = json.load(sys.stdin)
tileset = os.environ["TILESET_NAME"]
expected_styles = [tileset, f"{tileset}-labels"]

if tileset not in data.get("tiles", {}):
    raise SystemExit(f"catalog missing tiles.{tileset}")
styles = data.get("styles", {})
for style_id in expected_styles:
    if style_id not in styles:
        raise SystemExit(f"catalog missing styles.{style_id}")
PY
}

validate_tilejson() {
  local payload="$1"
  local base_url="$2"

  BASE_URL="${base_url}" TILESET_NAME="${TILESET_NAME}" python3 - <<'PY' <<<"${payload}"
import json
import os
import sys

data = json.load(sys.stdin)
base_url = os.environ["BASE_URL"].rstrip("/")
tileset = os.environ["TILESET_NAME"]
expected = f"{base_url}/{tileset}/{{z}}/{{x}}/{{y}}"

tiles = data.get("tiles", [])
if not tiles:
    raise SystemExit("tilejson missing tiles array")
if expected not in tiles:
    raise SystemExit(f"tilejson missing expected tiles URL: {expected}")
if data.get("minzoom") is None or data.get("maxzoom") is None:
    raise SystemExit("tilejson missing minzoom or maxzoom")
PY
}

validate_style() {
  local payload="$1"
  local base_url="$2"
  local style_id="$3"

  BASE_URL="${base_url}" TILESET_NAME="${TILESET_NAME}" STYLE_ID="${style_id}" python3 - <<'PY' <<<"${payload}"
import json
import os
import sys

data = json.load(sys.stdin)
base_url = os.environ["BASE_URL"].rstrip("/")
tileset = os.environ["TILESET_NAME"]
style_id = os.environ["STYLE_ID"]
source = data.get("sources", {}).get(tileset)

if data.get("version") != 8:
    raise SystemExit("style version must be 8")
if data.get("name") is None:
    raise SystemExit(f"style {style_id} is missing a name")
if not source:
    raise SystemExit(f"style missing source {tileset}")

source_url = source.get("url")
allowed = {f"/{tileset}", f"{base_url}/{tileset}"}
if source_url not in allowed:
    raise SystemExit(f"style source url must be one of {sorted(allowed)}, got {source_url!r}")

layers = data.get("layers", [])
if not layers:
    raise SystemExit("style has no layers")
PY
}

main() {
  load_env

  require_command curl
  require_command python3

  if [[ $# -gt 1 ]]; then
    usage
    exit 1
  fi

  local base_url="${1:-http://localhost:${MARTIN_PORT}}"
  local tileset_url="${base_url}/${TILESET_NAME}"
  local catalog
  local tilejson
  local style
  local style_id

  log "smoke testing ${base_url}"

  wait_for_http "${base_url}/health" || die "Martin did not become ready at ${base_url}/health"

  catalog=$(curl -fsS "${base_url}/catalog")
  validate_catalog "${catalog}" "${base_url}"

  tilejson=$(curl -fsS "${tileset_url}")
  validate_tilejson "${tilejson}" "${base_url}"

  for style_id in "${TILESET_NAME}" "${TILESET_NAME}-labels"; do
    style=$(curl -fsS "${base_url}/style/${style_id}")
    validate_style "${style}" "${base_url}" "${style_id}"
  done

  log "smoke tests passed"
}

main "$@"