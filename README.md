# map-pipeline

Deterministic tile build and serving pipeline for OpenStreetMap extracts on a single Ubuntu host.

## What This Repository Does

The pipeline turns a `.osm.pbf` file into a versioned `.mbtiles` archive with Planetiler, validates the archive, promotes it atomically through a stable symlink, and serves it through Martin under a stable source name.

Data flow:

```text
.osm.pbf -> Planetiler -> data/build/<timestamped>.mbtiles -> current.mbtiles symlink -> Martin serves /basemap
```

## Repository Layout

```text
.
├── docker-compose.yml
├── doc/
├── martin/
├── scripts/
├── viewer/
├── data/
│   ├── incoming/
│   ├── build/
│   ├── published/
│   └── cache/
└── styles/
```

## Requirements

- Ubuntu 20.04+
- Docker with the `docker compose` plugin
- `sqlite3` for publish-time MBTiles validation

Install the required packages on Ubuntu:

```bash
sudo apt update
sudo apt install docker.io docker-compose-plugin sqlite3 -y
sudo usermod -aG docker "$USER"
```

## Configuration

Defaults live in `.env` and `.env.example`.

Key variables:

- `MARTIN_PORT`: Host port exposed for Martin. Default `3000`.
- `TILESET_NAME`: Stable source ID used by the scripts and the bundled styles. Keep this at `basemap` unless you also update `martin/config.yaml` and the style source names.
- `PLANETILER_JAVA_XMX`: JVM heap for Planetiler. Default `8g`.
- `PLANETILER_STORAGE`: Planetiler temp storage mode. Default `mmap`.
- `PLANETILER_IMAGE`: Pinned Planetiler image. Current working default: `ghcr.io/onthegomap/planetiler:0.10.1`.
- `MARTIN_IMAGE`: Pinned Martin image. Current working default: `ghcr.io/maplibre/martin:latest`.
- `BUILD_RETENTION`: Number of build artifacts retained after successful publish. Default `3`.

## First Run

Start Martin in the background:

```bash
docker compose up -d
```

Build and publish tiles from a source extract:

```bash
./scripts/rebuild-and-publish.sh data/incoming/map.osm.pbf
```

If the input extract lives elsewhere on disk, pass its path directly. The build script mounts the input directory read-only into the Planetiler container.

## Repeat Runs

Run the same orchestration command again with a new or updated `.osm.pbf` file:

```bash
./scripts/rebuild-and-publish.sh /path/to/new.osm.pbf
```

Each build produces a new timestamped file in `data/build/`. Publishing never overwrites the previously active MBTiles file in place.

## Script Reference

### Build Only

```bash
./scripts/build-tiles.sh data/incoming/map.osm.pbf
```

Behavior:

- Validates the input path and file extension.
- Runs Planetiler in Docker using the pinned image.
- Writes a versioned MBTiles file to `data/build/`.
- Prints the absolute output path on success.

### Publish Only

```bash
./scripts/publish-tiles.sh data/build/map-20260319T180000Z.mbtiles
```

Behavior:

- Validates SQLite integrity with `PRAGMA quick_check`.
- Requires metadata keys `name`, `format`, `minzoom`, and `maxzoom`.
- Verifies that the `tiles` table is non-empty.
- Creates a temporary symlink and atomically renames it to `data/published/current.mbtiles`.
- Restarts Martin with `docker compose restart martin`.
- Runs endpoint smoke tests against `/catalog`, `/basemap`, `/style/basemap`, and `/style/basemap-labels`.
- Rolls back to the previous `current.mbtiles` symlink target if the smoke tests fail.
- Deletes older build artifacts while keeping the active target and the newest retained builds.

### Full Pipeline

```bash
./scripts/rebuild-and-publish.sh data/incoming/map.osm.pbf
```

Behavior:

- Runs build and publish sequentially.
- Stops on the first failure.
- Leaves the currently published tiles untouched if the build or validation fails.

### Smoke Test Only

```bash
./scripts/smoke-test.sh
```

Behavior:

- Verifies that `GET /catalog` returns `tiles.basemap`, `styles.basemap`, and `styles.basemap-labels`.
- Verifies that `GET /basemap` returns TileJSON with a valid tile URL.
- Verifies that `GET /style/basemap` returns a style document with a `basemap` source.
- Verifies that `GET /style/basemap-labels` returns a style document with a `basemap` source.
- Accepts an optional base URL, for example `./scripts/smoke-test.sh http://localhost:3000`.

## Martin Endpoints

- Catalog: `http://localhost:${MARTIN_PORT:-3000}/catalog`
- TileJSON for the stable source: `http://localhost:${MARTIN_PORT:-3000}/basemap`
- Minimal geometry style: `http://localhost:${MARTIN_PORT:-3000}/style/basemap`
- Label and POI style: `http://localhost:${MARTIN_PORT:-3000}/style/basemap-labels`

## Verification

Check the catalog:

```bash
curl http://localhost:3000/catalog
```

Check the source TileJSON:

```bash
curl http://localhost:3000/basemap
```

Check the served style:

```bash
curl http://localhost:3000/style/basemap
```

Check the label and POI style:

```bash
curl http://localhost:3000/style/basemap-labels
```

Run the automated endpoint smoke tests:

```bash
./scripts/smoke-test.sh
```

## Local Viewer

The repository includes a minimal viewer at [viewer/index.html](viewer/index.html) for manual visual validation.

Serve it locally:

```bash
python3 -m http.server --directory viewer 8081
```

Then open:

```text
http://localhost:8081
```

Optional query parameters:

- `base`: Martin base URL, for example `http://localhost:3000`
- `style`: Martin style id, default `basemap`

Example:

```text
http://localhost:8081/?base=http://localhost:3000&style=basemap-labels
```

Bundled styles:

- `basemap`: Minimal geometry-focused preview style.
- `basemap-labels`: More complete preview style with place labels, road labels, water labels, and POI markers.

## Operational Notes

- `current.mbtiles` is a symlink in `data/published/` that points at a versioned file in `data/build/`.
- The symlink target is relative so it resolves correctly both on the host and inside the Martin container.
- Martin is restarted after every publish to ensure the new file is reopened.
- Martin is configured with `cors: true` so the local viewer can fetch the style and tiles from another local port.
- The label-bearing style uses the OpenMapTiles public glyph endpoint for text rendering in the local viewer.
- Retention cleanup only runs after a successful publish.

## Failure Handling

### Invalid MBTiles

If validation fails, publish aborts and the active tiles remain unchanged.

### Docker or Planetiler Failure

If the build step fails, no publish occurs.

### Martin Restart Failure

The publish step exits non-zero after the symlink swap. The new tiles remain selected on disk, but Martin must be restarted successfully before clients will see the new version.

## Current Implementation Status

The pipeline has been tested end-to-end against real extracts and now includes automatic post-publish smoke tests plus a local MapLibre viewer for visual validation.
