# Map Pipeline — Requirements & Implementation Guide

## Overview

**Repository name:** `map-pipeline`

This project defines a reproducible pipeline to:

1. Ingest `.osm.pbf` files
2. Generate vector tiles (MBTiles) using Planetiler
3. Publish tiles via Martin (MapLibre tile server) under one or more named catalogue entries
4. Serve one or more MapLibre styles per catalogue
5. Allow repeatable rebuilds and atomic switching to new datasets

The system is designed for:
- Single Ubuntu server
- Docker Compose deployment
- Deterministic, script-driven execution
- Safe updates (no partial serving of tiles)
- Multiple named map catalogues served by the same Martin deployment

---

## Architecture Summary

### Components

| Component | Role |
|----------|------|
| Planetiler | Converts `.osm.pbf` → `.mbtiles` |
| Martin | Serves tiles over HTTP |
| Docker Compose | Manages services |
| Bash scripts | Control pipeline lifecycle |

### Data Flow

```
.osm.pbf
  → Planetiler
  → data/build/<catalogue>/<timestamped>.mbtiles
  → data/published/<catalogue>/current.mbtiles symlink
  → Martin serves /<catalogue> and /style/<style_id>
```

---

## Repository Structure

```
map-pipeline/
├── docker-compose.yml
├── doc
│   └── map-pipeline-requirements.md
├── .env
├── .env.example
├── .gitignore
├── README.md
├── scripts/
│   ├── build-tiles.sh
│   ├── generate-martin-config.sh
│   ├── publish-tiles.sh
│   ├── refresh-martin.sh
│   └── rebuild-and-publish.sh
├── data/
│   ├── incoming/
│   ├── build/
│   │   └── <catalogue>/
│   ├── published/
│   │   └── <catalogue>/
│   │       └── current.mbtiles -> ../../build/<catalogue>/<artifact>.mbtiles
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

---

## Functional Requirements

### 1. Tile Generation

- Input: `.osm.pbf`
- Output: `.mbtiles`
- Tool: Planetiler (Dockerized)
- Build target must include a catalogue name
- Must support:
  - Custom memory limits (`JAVA_TOOL_OPTIONS`)
  - Repeatable runs
  - Versioned output filenames
  - Per-catalogue build directories

### 2. Tile Publishing

- Serve tiles via Martin
- Must support multiple stable catalogue names, for example:
  - `basemap`
  - `berlin`
  - `brandenburg`
- Default catalogue name must remain `basemap` for backwards compatibility
- A catalogue name is Martin's public tile source ID and appears in `/catalog`
- Underlying files must be replaceable without changing the catalogue endpoint
- Publishing one catalogue must not replace or invalidate any other catalogue
- Catalogue names must be validated as URL-safe slugs before use

### 3. Style Publishing

- Martin must serve MapLibre style JSON files via `/style/<style_id>`
- Multiple styles per catalogue must be supported
- Style IDs are globally visible in Martin's style catalogue and must be unique
- Style files are user data under `data/styles/<catalogue>/` and must not be committed, except `data/styles/.gitkeep`
- The repository keeps only reusable style templates under `templates/styles/`
- The repository must include `templates/styles/default.json` as the canonical default style template
- Publishing a catalogue must create `data/styles/<catalogue>/default.json` from the default template when missing, unless disabled by command-line option
- Auto-created default styles must keep the style source key `basemap` and rewrite the source URL to the target `/<catalogue>`
- Auto-created default styles must rewrite the style name to reflect the target catalogue
- Existing user-owned default styles must not be overwritten by publish
- Auto-created default styles must be written atomically through a same-directory temporary file and rename
- Style files may be grouped by catalogue on disk even when the public style IDs are flat
- Each style must reference one or more configured catalogue sources
- A style update must not require rebuilding MBTiles
- Adding or removing a style ID must refresh Martin so `/catalog` reflects the change
- The default template must cover the current Planetiler/OpenMapTiles-compatible layer set emitted by this pipeline:
  `aerodrome_label`, `aeroway`, `boundary`, `building`, `housenumber`, `landcover`, `landuse`, `mountain_peak`, `park`, `place`, `poi`, `transportation`, `transportation_name`, `water`, `water_name`, and `waterway`
- The default template must style transportation diagnostically by class/subclass:
  major roads with differentiated widths/colors, minor/service roads with narrower light lines, construction/ferry/track/pedestrian/bicycle/bridleway/steps as distinct dashed lines, railways as dashed black-over-white lines, and public transport overlays as thin black lines
- The default template must split public transport POIs from generic POIs
- The default template must render `mountain_peak` features with `class=cliff` and LineString geometry as lines, while Point geometries in the layer render as points
- Generic POIs must render as small blue dots with name labels
- Public transport POIs must render with distinct marker and label styling

### 4. Atomic Deployment

- New tiles must not overwrite existing tiles
- Use:
  - versioned files under `data/build/<catalogue>/`
  - symlink: `data/published/<catalogue>/current.mbtiles`
- Switch must be atomic per catalogue

### 5. Martin Refresh Strategy

- Martin must refresh after publishing tiles
- Reason:
  - ensure file handle refresh
  - avoid stale reads
- Martin must also refresh after catalogue or style registration changes

### 6. Martin Embedded UI

- Martin's embedded web UI must be controlled through Martin command-line arguments
- The default must be enabled:
  - `--webui enable-for-all`
- Operators must be able to disable it without editing the image:
  - `--webui disable`
- The Docker Compose configuration should expose this as an environment-controlled command argument
- The UI is available at `/` when enabled and should be documented as an operational dashboard, not as the primary production client

### 7. Local Viewer

- The local `viewer/index.html` must fetch Martin's `/catalog` endpoint
- The viewer must present available styles in a dropdown populated from `catalog.styles`
- The viewer must keep supporting `base`, `style`, `debugTiles`, and `inspect` query parameters
- If the requested style is unavailable, the viewer must select `basemap` when present, otherwise the first style in `/catalog`
- If no styles are available, the viewer must disable map loading and show a clear status message
- The viewer must enable click inspection by default and allow disabling it with `inspect=0`
- The viewer inspector must source-scan currently loaded vector tiles with `querySourceFeatures`
- The viewer inspector must include point/line hits within 8 screen pixels and polygon hits containing the clicked coordinate
- The viewer inspector must display all feature attributes present in the tile, grouped by source layer
- Viewer inspection is a local debugging aid and is limited to tiles loaded by the browser for the active viewport and zoom

### 8. Validation

Before publishing:
- Verify MBTiles integrity:
  - SQLite accessible
  - metadata present
- Verify target catalogue name is valid
- Verify selected style template JSON before auto-creating a default style
- Verify selected style template is MapLibre style version 8 and defines `sources.basemap`
- Verify style JSON is valid when styles are added or changed
- Verify style source references point at configured catalogue names

### 9. Repeatability

Pipeline must support:
- Running multiple times with different inputs
- Running multiple times against different catalogues
- Idempotent execution
- No manual cleanup required

---

## Non-Functional Requirements

### Performance

- Must handle large `.osm.pbf` files (multi-GB)
- Disk requirement:
  - 5–10× input size
- RAM:
  - configurable via `.env`

### Reliability

- No partial serving during updates
- Fail fast on invalid config or tiles
- Failure in one catalogue publish must leave all existing catalogues unchanged

### Maintainability

- Clear script-based workflow
- No hidden state
- On-disk paths must make catalogue ownership clear

---

## Environment Setup

### System Requirements

- Ubuntu 20.04+
- Docker + Docker Compose
- `sqlite3`
- `python3`
- Minimum:
  - 16 GB RAM (recommended)
  - SSD storage

### Install Docker

```bash
sudo apt update
sudo apt install docker.io docker-compose-plugin sqlite3 python3 -y
sudo usermod -aG docker $USER
```

---

## Configuration

### `.env`

```
MARTIN_PORT=3000
MARTIN_WEBUI=enable-for-all
PLANETILER_JAVA_XMX=8g
PLANETILER_STORAGE=mmap
DEFAULT_CATALOGUE=basemap
BUILD_RETENTION=3
```

Valid `MARTIN_WEBUI` values:

- `enable-for-all`
- `disable`

`TILESET_NAME=basemap` may be kept as a backwards-compatible alias, but new requirements should use catalogue terminology.

---

## Docker Compose

### Service: Martin

- Runs continuously
- Mounts:
  - generated config from `data/martin/config.yaml`
  - `data/` read-only, including generated Martin config, published tiles, and styles
- Passes Martin web UI state as a command-line argument

Required command shape:

```
martin --config /etc/martin/config.yaml --webui ${MARTIN_WEBUI:-enable-for-all}
```

---

## Martin Configuration

```
mbtiles:
  sources:
    basemap: /data/published/basemap/current.mbtiles
    berlin: /data/published/berlin/current.mbtiles

styles:
  sources:
    basemap: /data/styles/basemap/default.json
    basemap-labels: /data/styles/basemap/labels.json
    berlin: /data/styles/berlin/default.json
```

### Key Design Decision

- Fixed catalogue names are public source IDs
- The file behind each catalogue changes
- Each catalogue has its own atomic `current.mbtiles` symlink
- Style IDs are stable public names and can be grouped by catalogue folder on disk
- Martin configuration may be maintained directly or generated from the catalogue/style folder structure, but `/catalog` must expose all configured tile and style entries
- The current implementation generates ignored Martin configuration at `data/martin/config.yaml` from published catalogue symlinks and `data/styles/<catalogue>/*.json`

---

## Scripts

### build-tiles.sh

**Responsibility:**
- Run Planetiler
- Generate versioned MBTiles
- Target a named catalogue

**Input:**
- `.osm.pbf`
- `--catalogue <name>` or equivalent

**Output:**
- `data/build/<catalogue>/<name>-<timestamp>.mbtiles`

---

### publish-tiles.sh

**Responsibility:**
- Validate MBTiles
- Create a default style for the catalogue when missing
- Update the target catalogue symlink
- Refresh Martin

**Input options:**
- `--catalogue <name>` or equivalent
- `--style-template <path>` to choose the template used for auto-created `default.json`
- `--no-style-template` to skip automatic style creation

**Steps:**
1. Validate SQLite metadata
2. Validate or create target catalogue directory
3. Create temp symlink
4. Atomic rename → `data/published/<catalogue>/current.mbtiles`
5. Create `data/styles/<catalogue>/default.json` from the selected template if missing
6. Refresh Martin
7. Run smoke tests for the affected catalogue and registered styles
8. On smoke-test failure, roll back the catalogue symlink and remove only the style file auto-created during that failed publish

---

### generate-martin-config.sh

**Responsibility:**
- Generate `data/martin/config.yaml` from the on-disk catalogue and style structure
- Validate style JSON before Martin is refreshed
- Derive style IDs from `data/styles/<catalogue>/<style>.json`

**Examples:**
- `data/styles/basemap/default.json` becomes `/style/basemap`
- `data/styles/basemap/labels.json` becomes `/style/basemap-labels`
- `data/styles/berlin/dark.json` becomes `/style/berlin-dark`

---

### refresh-martin.sh

**Responsibility:**
- Regenerate Martin configuration
- Start Martin if needed
- Restart Martin so catalogue and style changes are visible

**Use cases:**
- Adding a new style file
- Removing a style file
- Manually arranging published catalogue symlinks

---

### rebuild-and-publish.sh

**Responsibility:**
- Orchestrate full pipeline
- Accept the target catalogue name and pass it through build and publish
- Forward `--style-template <path>` and `--no-style-template` to publish

---

## Execution Workflow

### First Run

```
docker compose up -d
./scripts/rebuild-and-publish.sh --catalogue basemap data/incoming/file.osm.pbf
```

### Subsequent Runs

```
./scripts/rebuild-and-publish.sh --catalogue berlin data/incoming/berlin.osm.pbf
./scripts/rebuild-and-publish.sh --catalogue brandenburg data/incoming/brandenburg.osm.pbf
```

Publishing a new catalogue creates `data/styles/<catalogue>/default.json` from `templates/styles/default.json` when that file is missing. The public style ID is `/style/<catalogue>`.

### Custom Or Skipped Default Styles

```
./scripts/rebuild-and-publish.sh --catalogue berlin --style-template templates/styles/default.json data/incoming/berlin.osm.pbf
./scripts/rebuild-and-publish.sh --catalogue berlin --no-style-template data/incoming/berlin.osm.pbf
```

### Disable Martin UI

```
MARTIN_WEBUI=disable docker compose up -d martin
```

### Add Or Refresh Styles

```
mkdir -p data/styles/berlin
cp templates/styles/default.json data/styles/berlin/labels.json
# edit data/styles/berlin/labels.json so its source URL references /berlin
./scripts/refresh-martin.sh
```

---

## API Endpoints

| Endpoint | Purpose |
|----------|--------|
| /catalog | List sources |
| / | Martin embedded UI when enabled |
| /<catalogue> | TileJSON for a catalogue |
| /<catalogue>/<z>/<x>/<y> | Tile payload |
| /style/<style_id> | MapLibre style JSON |

---

## Failure Modes & Handling

### Disk Full
- Build fails → no publish occurs

### Invalid MBTiles
- Publish script aborts
- Active catalogue symlink remains unchanged

### Martin startup failure
- Configuration error → container exits

### Invalid Catalogue Name
- Publish script aborts before writing files

### Invalid Style
- Style registration aborts or Martin config validation fails before deployment
- Invalid auto-style templates abort publish before Martin refresh

---

## Cleanup Strategy

Recommended:
- Keep last 3 builds per catalogue
- Remove older files from `data/build/<catalogue>/`
- Never remove the active target of any `data/published/<catalogue>/current.mbtiles` symlink

---

## Security Considerations

- No public write access
- Mount volumes as read-only where possible
- Run containers as non-root user
- Martin's embedded UI is enabled by default for operator convenience
- Public deployments should disable the UI or protect it behind network controls or authentication

---

## Future Extensions

- PMTiles support
- CDN integration
- Automated cron builds
- Multi-node or multi-region deployment

---

## Assumptions

- Single-node deployment
- No high-availability requirement
- Tiles served directly from disk
- Catalogue and style names are managed by operators through scripts or version-controlled files
- The default style template targets the current Planetiler/OpenMapTiles-compatible layer set emitted by this pipeline

---

## Risks

| Risk | Impact |
|------|--------|
| Large PBF files | Long build times |
| RAM misconfiguration | Build failure |
| Style mismatch | Broken rendering |
| Catalogue name collision | Wrong map served under a public endpoint |
| Public UI exposure | Operational metadata visible to untrusted users |

---

## Minimal Runbook

```
# start server
docker compose up -d

# build + publish
./scripts/rebuild-and-publish.sh --catalogue basemap data/incoming/map.osm.pbf

# verify
curl http://localhost:3000/catalog
curl http://localhost:3000/basemap
curl http://localhost:3000/style/basemap
```

---

## Conclusion

This pipeline is:

- Deterministic
- Safe (atomic updates)
- Simple to operate
- Easily version-controlled

It is suitable for:
- MVP
- Internal tooling
- Small-scale production

---

Last updated: 2026-05-17
