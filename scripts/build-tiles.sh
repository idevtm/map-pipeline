#!/usr/bin/env bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/build-tiles.sh <path-to.osm.pbf>

Builds a versioned MBTiles artifact under data/build/ using Planetiler in Docker.
EOF
}

main() {
  load_env
  ensure_directories

  require_command docker

  if [[ $# -ne 1 ]]; then
    usage
    exit 1
  fi

  local input_arg="$1"
  local input_path
  input_path=$(resolve_path "${input_arg}") || die "unable to resolve input path: ${input_arg}"

  [[ -f "${input_path}" ]] || die "input file not found: ${input_path}"
  [[ "${input_path}" == *.osm.pbf ]] || die "input file must end with .osm.pbf: ${input_path}"

  local input_dir
  local input_name
  local base_name
  local timestamp
  local output_name
  local output_path
  local docker_args=()

  input_dir=$(dirname -- "${input_path}")
  input_name=$(basename -- "${input_path}")
  base_name=${input_name%.osm.pbf}
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  output_name="${base_name}-${timestamp}.mbtiles"
  output_path="${DATA_BUILD_DIR}/${output_name}"

  docker_args+=(--osm-path="/input/${input_name}")
  docker_args+=(--output="/workspace/data/build/${output_name}")
  docker_args+=(--tmpdir="/workspace/data/cache/planetiler/tmp")
  docker_args+=(--download-dir="/workspace/data/cache/planetiler/downloads")
  docker_args+=(--storage="${PLANETILER_STORAGE}")
  docker_args+=(--download)
  docker_args+=(--force)

  if [[ -n "${PLANETILER_THREADS:-}" ]]; then
    docker_args+=(--threads="${PLANETILER_THREADS}")
  fi

  build_planetiler_runtime_image

  log "building ${output_name} from ${input_path}"

  docker run --rm \
    -e "JAVA_TOOL_OPTIONS=-Xmx${PLANETILER_JAVA_XMX}" \
    -v "${REPO_ROOT}:/workspace" \
    -v "${input_dir}:/input:ro" \
    -w /workspace \
    "${PLANETILER_RUNTIME_IMAGE}" \
    "${docker_args[@]}" \
    1>&2

  [[ -s "${output_path}" ]] || die "planetiler did not produce a non-empty MBTiles file: ${output_path}"

  log "build completed: ${output_path}"
  printf '%s\n' "${output_path}"
}

main "$@"
