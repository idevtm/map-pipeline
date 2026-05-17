# map-pipeline

Deterministic tile build and serving pipeline for OpenStreetMap extracts on a single Ubuntu host.

The pipeline turns `.osm.pbf` files into versioned `.mbtiles` archives with Planetiler, validates them, publishes each map under a named Martin catalogue entry, and serves one or more MapLibre styles for those catalogues.

## Data Flow

```text
.osm.pbf
  -> Planetiler
  -> data/build/<catalogue>/<timestamped>.mbtiles
  -> data/published/<catalogue>/current.mbtiles
  -> Martin serves /<catalogue> and /style/<style-id>
```

The default catalogue is `basemap`, but the scripts support any URL-safe catalogue name, such as `berlin`, `brandenburg`, or `planet-2026`.

## Repository Layout

```text
.
├── docker-compose.yml
├── doc/
├── scripts/
├── viewer/
├── data/
│   ├── incoming/
│   ├── build/
│   │   └── <catalogue>/
│   ├── published/
│   │   └── <catalogue>/
│   │       └── current.mbtiles
│   ├── martin/
│   │   ├── .gitkeep
│   │   └── config.yaml  # generated, ignored
│   ├── styles/
│   │   └── <catalogue>/
│   │       ├── default.json
│   │       └── labels.json
│   └── cache/
└── templates/
    └── styles/
        └── default.json
```

`data/martin/config.yaml` is generated from the published catalogue symlinks and user style files under `data/styles/`. Files under `data/martin/` are ignored by Git except for `data/martin/.gitkeep`.

## Requirements

- Ubuntu 20.04+
- Docker with the `docker compose` plugin
- `sqlite3` for publish-time MBTiles validation
- `python3` for default style creation, config generation, and endpoint validation

Install the required packages on Ubuntu:

```bash
sudo apt update
sudo apt install docker.io docker-compose-plugin sqlite3 python3 -y
sudo usermod -aG docker "$USER"
```

## Configuration

Defaults live in `.env` and `.env.example`.

Key variables:

- `MARTIN_PORT`: Host port exposed for Martin. Default `3000`.
- `MARTIN_WEBUI`: Martin embedded UI mode. Default `enable-for-all`. Use `disable` to turn it off.
- `DEFAULT_CATALOGUE`: Default catalogue when `--catalogue` is omitted. Default `basemap`.
- `PLANETILER_JAVA_XMX`: JVM heap for Planetiler. Default `8g`.
- `PLANETILER_STORAGE`: Planetiler temp storage mode. Default `mmap`.
- `BUILD_RETENTION`: Number of build artifacts retained per catalogue after successful publish. Default `3`.

Dependency versions for Martin and Planetiler are pinned in Dockerfiles under `docker/`.

## Start Martin

Generate config and start Martin:

```bash
./scripts/generate-martin-config.sh
docker compose up -d martin
```

Martin's embedded UI is enabled by default at:

```text
http://localhost:3000/
```

Disable the UI:

```bash
MARTIN_WEBUI=disable docker compose up -d martin
```

## Build And Publish One Catalogue

Build and publish the default `basemap` catalogue:

```bash
./scripts/rebuild-and-publish.sh --catalogue basemap data/incoming/berlin.osm.pbf
```

Build and publish a separate catalogue:

```bash
./scripts/rebuild-and-publish.sh --catalogue brandenburg data/incoming/brandenburg.osm.pbf
```

Each catalogue gets its own stable endpoint:

```text
http://localhost:3000/basemap
http://localhost:3000/brandenburg
```

Publishing refreshes Martin automatically, so clients see the newly selected `current.mbtiles`.
If `data/styles/<catalogue>/default.json` does not exist, publishing also creates it from `templates/styles/default.json`; the resulting style is served as `/style/<catalogue>`.

Use a custom default style template during the full pipeline:

```bash
./scripts/rebuild-and-publish.sh --catalogue brandenburg --style-template templates/styles/default.json data/incoming/brandenburg.osm.pbf
```

Skip automatic default style creation:

```bash
./scripts/rebuild-and-publish.sh --catalogue brandenburg --no-style-template data/incoming/brandenburg.osm.pbf
```

## Build And Publish Separately

Build only:

```bash
./scripts/build-tiles.sh --catalogue berlin data/incoming/berlin.osm.pbf
```

Publish an existing build:

```bash
./scripts/publish-tiles.sh --catalogue berlin data/build/berlin/berlin-20260516T090000Z.mbtiles
```

When `--catalogue` is omitted, publish infers it from `data/build/<catalogue>/...`. Root-level legacy build files publish to `DEFAULT_CATALOGUE`.

Use a custom style template for the auto-created default style:

```bash
./scripts/publish-tiles.sh --catalogue berlin --style-template templates/styles/default.json data/build/berlin/berlin-20260516T090000Z.mbtiles
```

Skip automatic style creation:

```bash
./scripts/publish-tiles.sh --catalogue berlin --no-style-template data/build/berlin/berlin-20260516T090000Z.mbtiles
```

## MVT And MLT

Planetiler supports MVT and MLT tile payloads inside MBTiles. MVT is the default.

```bash
./scripts/rebuild-and-publish.sh --catalogue berlin --tile-format mvt data/incoming/berlin.osm.pbf
./scripts/rebuild-and-publish.sh --catalogue berlin --tile-format mlt data/incoming/berlin.osm.pbf
./scripts/rebuild-and-publish.sh --catalogue berlin --mlt data/incoming/berlin.osm.pbf
```

The bundled viewer and style template are designed for MVT. Treat MLT as a server/archive option unless your client stack supports MLT.

## Styles

Martin serves user-owned style JSON from `data/styles/<catalogue>/*.json`. Files under `data/styles/` are intentionally ignored by Git, except for `data/styles/.gitkeep`.

The committed default template is `templates/styles/default.json`. It uses one source named `basemap`, points to `/basemap` by default, and includes simple render layers for the current Planetiler/OpenMapTiles-compatible layer set. When publish creates `data/styles/<catalogue>/default.json`, it keeps the source key as `basemap`, rewrites the style name, and rewrites only the source URL to `/<catalogue>`.

The default template covers these emitted layers: `aerodrome_label`, `aeroway`, `boundary`, `building`, `housenumber`, `landcover`, `landuse`, `mountain_peak`, `park`, `place`, `poi`, `transportation`, `transportation_name`, `water`, `water_name`, and `waterway`.

Transportation styling is intentionally diagnostic:

- major roads use different widths and warm colors by `class`
- minor and service roads use narrower light lines
- construction, ferry, track, pedestrian, bicycle, bridleway, and steps are dashed with distinct colors
- rail-like `subclass` values render as dashed black-over-white lines
- busway/guideway and transit-like subclasses render as thin black overlays
- public transport POIs render differently from generic POIs; generic POIs remain small blue dots with labels
- `mountain_peak` cliff LineStrings render as cliff lines, while point features in that layer render as mountain peak points

Templates used with `--style-template` must be MapLibre style version 8 JSON, define a `sources.basemap` object, and only reference defined sources from layers.

Style IDs are derived from the path:

```text
data/styles/basemap/default.json -> /style/basemap
data/styles/basemap/labels.json  -> /style/basemap-labels
data/styles/berlin/default.json  -> /style/berlin
data/styles/berlin/dark.json     -> /style/berlin-dark
```

The style JSON should reference the matching catalogue source:

```json
{
  "version": 8,
  "name": "Berlin",
  "sources": {
    "basemap": {
      "type": "vector",
      "url": "/berlin"
    }
  },
  "layers": [
    {
      "id": "background",
      "type": "background",
      "paint": {
        "background-color": "#f4f0e6"
      }
    }
  ]
}
```

To add a style for a published catalogue:

```bash
mkdir -p data/styles/berlin
cp templates/styles/default.json data/styles/berlin/labels.json
```

Edit `data/styles/berlin/labels.json` so its `name` and source URL fit `berlin`. Keep the source key and layer `source` values as `basemap` unless you are intentionally creating a multi-source style. Then refresh Martin:

```bash
./scripts/refresh-martin.sh
```

Style-only edits do not require rebuilding MBTiles.

## Refresh Martin

Use this after adding/removing styles or after changing published catalogue folders by hand:

```bash
./scripts/refresh-martin.sh
```

The refresh script:

- regenerates `data/martin/config.yaml`
- starts Martin if needed
- restarts Martin so it reloads catalogue and style registrations

Tile publishing runs the same refresh automatically.

## Endpoints

```text
GET /                         Martin embedded UI when enabled
GET /catalog                  Catalogue of tile, style, sprite, and font sources
GET /<catalogue>              TileJSON for a catalogue
GET /<catalogue>/<z>/<x>/<y>  Tile payload
GET /style/<style-id>         MapLibre style JSON
```

Examples:

```bash
curl http://localhost:3000/catalog
curl http://localhost:3000/berlin
curl http://localhost:3000/style/berlin
curl http://localhost:3000/style/berlin-dark
```

## Smoke Tests

Test the default catalogue:

```bash
./scripts/smoke-test.sh
```

Test a specific catalogue and all styles under `data/styles/<catalogue>/`:

```bash
./scripts/smoke-test.sh --catalogue berlin
```

Test selected styles:

```bash
./scripts/smoke-test.sh --catalogue berlin --style berlin --style berlin-dark
```

Use a remote or forwarded Martin URL:

```bash
./scripts/smoke-test.sh --catalogue berlin http://localhost:3000
```

## Local Viewer

The repository includes a minimal viewer at [viewer/index.html](viewer/index.html) for manual visual validation. It fetches Martin's `/catalog` endpoint and presents a dynamic style dropdown.

Serve it locally:

```bash
python3 -m http.server --directory viewer 8081
```

Open:

```text
http://localhost:8081/?base=http://localhost:3000&style=basemap
```

Optional query parameters:

- `base`: Martin base URL, for example `http://localhost:3000`.
- `style`: Martin style ID to preselect. If absent or unavailable, the viewer selects `basemap` when present, otherwise the first style in `/catalog`.
- `debugTiles`: Set to `1` to show tile boundaries, coordinates, and sizes.
- `inspect`: Set to `0` to disable click inspection. It is enabled by default.

Examples:

```text
http://localhost:8081/?base=http://localhost:3000&style=basemap
http://localhost:8081/?base=http://localhost:3000&style=berlin
http://localhost:8081/?base=http://localhost:3000&style=berlin-dark&debugTiles=1
http://localhost:8081/?base=http://localhost:3000&style=basemap&inspect=0
```

`debugTiles=1` enables MapLibre's tile boundary, tile coordinate, and tile size overlay.

When inspection is enabled, clicking the map source-scans the currently loaded vector tiles in the browser, checks points and lines within 8 screen pixels, includes polygons that contain the clicked coordinate, and lists all feature properties in the sidebar. Results depend on the vector tiles currently loaded by MapLibre for the active viewport and zoom.

## Operational Notes

- Each catalogue has its own `data/published/<catalogue>/current.mbtiles` symlink.
- Symlink targets are relative so they resolve on the host and inside the Martin container.
- Publishing one catalogue does not change other catalogues.
- Martin is restarted after every publish so the MBTiles file handle is reopened.
- Retention cleanup runs per catalogue after a successful publish.
- The default style template uses the OpenMapTiles public glyph endpoint for text rendering in the local viewer.
- The embedded Martin UI is convenient for operators; disable or protect it for public deployments.

## Failure Handling

### Invalid MBTiles

Publish aborts and the active catalogue symlink remains unchanged.

### Docker or Planetiler Failure

If the build step fails, no publish occurs.

### Martin Refresh Failure

The publish step exits non-zero after the symlink swap. The new tiles remain selected on disk, but Martin must be refreshed successfully before clients will see the new version.

### Invalid Style Template

Publish aborts before refreshing Martin if the selected template is invalid JSON, is not MapLibre style version 8, does not define `sources.basemap`, or has layers referencing missing sources.

### Smoke Test Failure

Publish rolls the affected catalogue back to its previous symlink target when one existed, refreshes Martin again, and exits non-zero.
If publish created `data/styles/<catalogue>/default.json` during that failed publish, that newly created style is removed during rollback.
