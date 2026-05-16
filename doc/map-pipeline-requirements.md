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
├── martin/
│   └── config.yaml
├── scripts/
│   ├── build-tiles.sh
│   ├── publish-tiles.sh
│   └── rebuild-and-publish.sh
├── data/
│   ├── incoming/
│   ├── build/
│   │   └── <catalogue>/
│   ├── published/
│   │   └── <catalogue>/
│   │       └── current.mbtiles -> ../../build/<catalogue>/<artifact>.mbtiles
│   └── cache/
└── styles/
    └── <catalogue>/
        ├── default.json
        └── labels.json
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
- Style files may be grouped by catalogue on disk even when the public style IDs are flat
- Each style must reference one or more configured catalogue sources
- A style update must not require rebuilding MBTiles
- Adding or removing a style ID must refresh Martin so `/catalog` reflects the change

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

### 7. Validation

Before publishing:
- Verify MBTiles integrity:
  - SQLite accessible
  - metadata present
- Verify target catalogue name is valid
- Verify style JSON is valid when styles are added or changed
- Verify style source references point at configured catalogue names

### 8. Repeatability

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
- Minimum:
  - 16 GB RAM (recommended)
  - SSD storage

### Install Docker

```bash
sudo apt update
sudo apt install docker.io docker-compose-plugin -y
sudo usermod -aG docker $USER
```

---

## Configuration

### `.env`

```
MARTIN_PORT=3000
MARTIN_WEBUI=enable-for-all
PLANETILER_JAVA_XMX=8g
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
  - config
  - published tiles
  - styles
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
    basemap: /styles/basemap/default.json
    basemap-labels: /styles/basemap/labels.json
    berlin: /styles/berlin/default.json
```

### Key Design Decision

- Fixed catalogue names are public source IDs
- The file behind each catalogue changes
- Each catalogue has its own atomic `current.mbtiles` symlink
- Style IDs are stable public names and can be grouped by catalogue folder on disk
- Martin configuration may be maintained directly or generated from the catalogue/style folder structure, but `/catalog` must expose all configured tile and style entries

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
- Update the target catalogue symlink
- Refresh Martin

**Steps:**
1. Validate SQLite metadata
2. Validate or create target catalogue directory
3. Create temp symlink
4. Atomic rename → `data/published/<catalogue>/current.mbtiles`
5. Refresh Martin
6. Run smoke tests for the affected catalogue and registered styles

---

### rebuild-and-publish.sh

**Responsibility:**
- Orchestrate full pipeline
- Accept the target catalogue name and pass it through build and publish

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

### Disable Martin UI

```
MARTIN_WEBUI=disable docker compose up -d martin
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

Generated on: 2026-03-19T17:57:32.060625 UTC
