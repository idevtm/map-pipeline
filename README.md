# map-pipeline

Deterministic tile build and serving pipeline for OpenStreetMap extracts on a single Ubuntu host.

## What This Repository Does

The pipeline turns a `.osm.pbf` file into a versioned `.mbtiles` archive with Planetiler, validates the archive, promotes it atomically through a stable symlink, and serves it through Martin under a stable source name.

Data flow:

```text
.osm.pbf -> Planetiler -> data/build/<timestamped>.mbtiles -> current.mbtiles symlink -> Martin serves /basemap
```

Planetiler can generate either MVT or MLT tile payloads inside the MBTiles archive. This repository now exposes that choice through a build-time CLI flag.

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
- `BUILD_RETENTION`: Number of build artifacts retained after successful publish. Default `3`.

Dependency versions for Martin and Planetiler are not managed through `.env`. They are pinned in Dockerfiles under `docker/` so Dependabot can update them automatically.

## First Run

Start Martin in the background:

```bash
docker compose up -d
```

On the first run, Docker Compose builds the local Martin runtime image from `docker/martin/Dockerfile`.

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

Build MLT tiles instead of MVT:

```bash
./scripts/build-tiles.sh --tile-format mlt data/incoming/map.osm.pbf
```

Behavior:

- Validates the input path and file extension.
- Builds the local Planetiler runtime image from `docker/planetiler/Dockerfile`.
- Runs Planetiler in Docker using that local image.
- Uses Planetiler `--tile-format=mvt` by default.
- Passes `--tile-format=mlt` when requested through `--tile-format mlt` or `--mlt`.
- Writes a versioned MBTiles file to `data/build/`.
- Prints the absolute output path on success.

## Dependency Updates With Dependabot

Martin and Planetiler are pinned in these files:

- `docker/martin/Dockerfile`
- `docker/planetiler/Dockerfile`

Dependabot is configured in `.github/dependabot.yml` to watch both Dockerfile directories and open update PRs when new base images are available.

After merging a Dependabot PR:

```bash
docker compose build martin
./scripts/build-tiles.sh data/incoming/map.osm.pbf
```

That rebuilds the local Martin runtime image and the local Planetiler runtime image with the updated base image versions.

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

Full pipeline with MLT output:

```bash
./scripts/rebuild-and-publish.sh --tile-format mlt data/incoming/map.osm.pbf
```

Behavior:

- Runs build and publish sequentially.
- Stops on the first failure.
- Leaves the currently published tiles untouched if the build or validation fails.

## MVT And MLT Options

Planetiler supports generating MapLibre Tiles with `--tile-format=mlt` in addition to the default MVT output. Martin supports serving MLT tiles from MBTiles and detects them as `application/vnd.maplibre-vector-tile`.

Technical options in this repository:

- Default MVT build: `./scripts/build-tiles.sh data/incoming/map.osm.pbf`
- Explicit MVT build: `./scripts/build-tiles.sh --tile-format mvt data/incoming/map.osm.pbf`
- Explicit MLT build: `./scripts/build-tiles.sh --tile-format mlt data/incoming/map.osm.pbf`
- MLT shorthand: `./scripts/build-tiles.sh --mlt data/incoming/map.osm.pbf`
- Full pipeline with MLT: `./scripts/rebuild-and-publish.sh --mlt data/incoming/map.osm.pbf`

Operational notes:

- The published artifact is still an `.mbtiles` file in both cases. Only the tile payload format inside the archive changes.
- Martin can serve both formats from MBTiles.
- The current bundled MapLibre GL viewer and styles are designed for MVT. Treat MLT output as a server-side/archive option unless your downstream client stack explicitly supports MLT.
- Publish validation still checks SQLite integrity, metadata presence, and tile presence. It does not attempt client-side rendering validation for MLT.

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
