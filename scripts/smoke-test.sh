#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/smoke-test.sh [--catalogue NAME] [--style STYLE_ID ...] [base-url]

Verifies the live Martin endpoints used by this repository:
- /catalog
- /<catalogue>
- /style/<style_id>

Options:
  --catalogue NAME  Catalogue to verify. Default: DEFAULT_CATALOGUE or basemap.
  --catalog NAME    Alias for --catalogue.
  --style STYLE_ID  Style ID to verify. May be provided multiple times.
EOF
}

parse_args() {
  SMOKE_CATALOGUE="${DEFAULT_CATALOGUE}"
  SMOKE_BASE_URL=""
  SMOKE_STYLE_IDS=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --catalogue|--catalog)
        [[ $# -ge 2 ]] || die "missing value for $1"
        SMOKE_CATALOGUE="$2"
        shift 2
        ;;
      --catalogue=*|--catalog=*)
        SMOKE_CATALOGUE="${1#*=}"
        shift
        ;;
      --style)
        [[ $# -ge 2 ]] || die "missing value for --style"
        SMOKE_STYLE_IDS+=("$2")
        shift 2
        ;;
      --style=*)
        SMOKE_STYLE_IDS+=("${1#*=}")
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
        if [[ -n "${SMOKE_BASE_URL}" ]]; then
          die "only one base URL is supported"
        fi
        SMOKE_BASE_URL="$1"
        shift
        ;;
    esac
  done

  if [[ $# -gt 0 ]]; then
    [[ -z "${SMOKE_BASE_URL}" && $# -eq 1 ]] || die "unexpected extra arguments"
    SMOKE_BASE_URL="${1:-${SMOKE_BASE_URL}}"
  fi

  validate_catalogue_name "${SMOKE_CATALOGUE}"

  if [[ "${#SMOKE_STYLE_IDS[@]}" -eq 0 ]]; then
    while IFS= read -r style_id; do
      SMOKE_STYLE_IDS+=("${style_id}")
    done < <(style_ids_for_catalogue "${SMOKE_CATALOGUE}")
  fi

  for style_id in "${SMOKE_STYLE_IDS[@]}"; do
    validate_catalogue_name "${style_id}"
  done
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
  local catalogue="$2"
  shift 2
  local styles_json="$1"

  CATALOGUE="${catalogue}" STYLES_JSON="${styles_json}" python3 -c '
import json
import os
import sys

data = json.load(sys.stdin)
catalogue = os.environ["CATALOGUE"]
expected_styles = json.loads(os.environ["STYLES_JSON"])

if catalogue not in data.get("tiles", {}):
    raise SystemExit(f"catalog missing tiles.{catalogue}")
styles = data.get("styles", {})
for style_id in expected_styles:
    if style_id not in styles:
        raise SystemExit(f"catalog missing styles.{style_id}")
' <<<"${payload}"
}

validate_tilejson() {
  local payload="$1"
  local base_url="$2"
  local catalogue="$3"

  BASE_URL="${base_url}" CATALOGUE="${catalogue}" python3 -c '
import json
import os
import sys

data = json.load(sys.stdin)
base_url = os.environ["BASE_URL"].rstrip("/")
catalogue = os.environ["CATALOGUE"]
expected = f"{base_url}/{catalogue}/{{z}}/{{x}}/{{y}}"

tiles = data.get("tiles", [])
if not tiles:
    raise SystemExit("tilejson missing tiles array")
if expected not in tiles:
    raise SystemExit(f"tilejson missing expected tiles URL: {expected}")
if data.get("minzoom") is None or data.get("maxzoom") is None:
    raise SystemExit("tilejson missing minzoom or maxzoom")
' <<<"${payload}"
}

validate_style() {
  local payload="$1"
  local base_url="$2"
  local style_id="$3"
  local catalogue="$4"

  BASE_URL="${base_url}" STYLE_ID="${style_id}" CATALOGUE="${catalogue}" python3 -c '
import json
import os
import sys

data = json.load(sys.stdin)
base_url = os.environ["BASE_URL"].rstrip("/")
style_id = os.environ["STYLE_ID"]
catalogue = os.environ["CATALOGUE"]
sources = data.get("sources", {})

if data.get("version") != 8:
    raise SystemExit("style version must be 8")
if data.get("name") is None:
    raise SystemExit(f"style {style_id} is missing a name")

allowed = {f"/{catalogue}", f"{base_url}/{catalogue}"}
source_urls = {source.get("url") for source in sources.values() if isinstance(source, dict)}
if not allowed.intersection(source_urls):
    raise SystemExit(f"style {style_id} must reference one of {sorted(allowed)}")

layers = data.get("layers", [])
if not layers:
    raise SystemExit("style has no layers")
for layer in layers:
    source_id = layer.get("source")
    if source_id is not None and source_id not in sources:
        layer_id = layer.get("id", "<unknown>")
        raise SystemExit(f"style {style_id} layer {layer_id} references missing source {source_id!r}")
' <<<"${payload}"
}

main() {
  load_env
  ensure_directories

  require_command curl
  require_command python3

  parse_args "$@"

  local base_url="${SMOKE_BASE_URL:-http://localhost:${MARTIN_PORT}}"
  local tileset_url="${base_url}/${SMOKE_CATALOGUE}"
  local catalog
  local tilejson
  local style
  local style_id
  local styles_json

  styles_json="["
  for style_id in "${SMOKE_STYLE_IDS[@]}"; do
    if [[ "${styles_json}" != "[" ]]; then
      styles_json+=","
    fi
    styles_json+="\"${style_id}\""
  done
  styles_json+="]"

  log "smoke testing ${base_url} catalogue ${SMOKE_CATALOGUE}"

  wait_for_http "${base_url}/health" || die "Martin did not become ready at ${base_url}/health"

  catalog=$(curl -fsS "${base_url}/catalog")
  validate_catalog "${catalog}" "${SMOKE_CATALOGUE}" "${styles_json}"

  tilejson=$(curl -fsS "${tileset_url}")
  validate_tilejson "${tilejson}" "${base_url}" "${SMOKE_CATALOGUE}"

  for style_id in "${SMOKE_STYLE_IDS[@]}"; do
    style=$(curl -fsS "${base_url}/style/${style_id}")
    validate_style "${style}" "${base_url}" "${style_id}" "${SMOKE_CATALOGUE}"
  done

  log "smoke tests passed"
}

main "$@"
