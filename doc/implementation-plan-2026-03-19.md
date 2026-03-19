# Map Pipeline Implementation Plan

Date: 2026-03-19

## Goal

Turn the repository from a stub into a reproducible single-node tile build and serving pipeline that:

1. Builds versioned MBTiles from `.osm.pbf` input with Planetiler.
2. Publishes the latest validated artifact atomically through `current.mbtiles`.
3. Serves a stable `basemap` source with Martin.
4. Supports repeatable rebuilds with scripted operations and no manual cleanup.

## Decisions Locked In

- Planetiler image is pinned to `ghcr.io/onthegomap/planetiler:0.10.1`.
- Martin image defaults to `ghcr.io/maplibre/martin:latest` because the release tag was not available in the registry during runtime validation.
- Martin refresh is handled by `docker compose restart martin` after publish.
- Retention keeps the newest three build artifacts after a successful publish.
- A working starter MapLibre style is included instead of a placeholder.

## Delivery Scope

### Infrastructure and Config

- Add `.env` and `.env.example` with runtime defaults.
- Add `docker-compose.yml` for the long-running Martin service.
- Add `martin/config.yaml` with an explicit stable source name and style registration.

### Pipeline Scripts

- `scripts/build-tiles.sh`
  - Validate input and Docker availability.
  - Run Planetiler with pinned image and configurable JVM heap.
  - Write output into `data/build/<name>-<timestamp>.mbtiles`.

- `scripts/publish-tiles.sh`
  - Validate the MBTiles archive as SQLite.
  - Require metadata keys `name`, `format`, `minzoom`, and `maxzoom`.
  - Ensure the `tiles` table is non-empty.
  - Swap `current.mbtiles` atomically through a temporary symlink.
  - Restart Martin and prune old build artifacts.

- `scripts/rebuild-and-publish.sh`
  - Run the full fail-fast pipeline from source extract to published tiles.

### Repository Layout

- Track the required `data/` directories with `.gitkeep` files.
- Add a starter `styles/style.json` that targets Martin’s `basemap` source.
- Expand `README.md` into an operator-facing runbook.

## Verification Plan

1. `bash -n` for each shell script.
2. `docker compose config` for compose and env interpolation.
3. Argument smoke tests for missing parameters.
4. One end-to-end build and publish against a valid `.osm.pbf` extract.
5. One negative publish test with an invalid MBTiles file.

## Follow-On Work After Bootstrap

- Add CI checks for shell syntax and compose validation.
- Add a small fixture-based integration test path if a sample `.osm.pbf` is available.
- Consider richer style assets, fonts, and labels once the tile schema is validated against generated data.
