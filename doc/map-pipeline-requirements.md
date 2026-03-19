# Map Pipeline — Requirements & Implementation Guide

## Overview

**Repository name:** `map-pipeline`

This project defines a reproducible pipeline to:

1. Ingest `.osm.pbf` files
2. Generate vector tiles (MBTiles) using Planetiler
3. Publish tiles via Martin (MapLibre tile server)
4. Allow repeatable rebuilds and atomic switching to new datasets

The system is designed for:
- Single Ubuntu server
- Docker Compose deployment
- Deterministic, script-driven execution
- Safe updates (no partial serving of tiles)

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
.osm.pbf → Planetiler → versioned.mbtiles → symlink switch → Martin serves
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
│   ├── published/
│   └── cache/
└── styles/
    └── style.json
```

---

## Functional Requirements

### 1. Tile Generation

- Input: `.osm.pbf`
- Output: `.mbtiles`
- Tool: Planetiler (Dockerized)
- Must support:
  - Custom memory limits (`JAVA_TOOL_OPTIONS`)
  - Repeatable runs
  - Versioned output filenames

### 2. Tile Publishing

- Serve tiles via Martin
- Must expose a stable source name:
  - `basemap`
- Underlying file must be replaceable without changing endpoint

### 3. Atomic Deployment

- New tiles must not overwrite existing tiles
- Use:
  - versioned files (timestamped)
  - symlink: `current.mbtiles`
- Switch must be atomic

### 4. Restart Strategy

- Martin must restart after publish
- Reason:
  - ensure file handle refresh
  - avoid stale reads

### 5. Validation

Before publishing:
- Verify MBTiles integrity:
  - SQLite accessible
  - metadata present

### 6. Repeatability

Pipeline must support:
- Running multiple times with different inputs
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

### Maintainability

- Clear script-based workflow
- No hidden state

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
PLANETILER_JAVA_XMX=8g
TILESET_NAME=basemap
```

---

## Docker Compose

### Service: Martin

- Runs continuously
- Mounts:
  - config
  - published tiles
  - styles

---

## Martin Configuration

```
mbtiles:
  sources:
    basemap: /data/published/current.mbtiles
```

### Key Design Decision

- Fixed source name (`basemap`)
- File behind it changes

---

## Scripts

### build-tiles.sh

**Responsibility:**
- Run Planetiler
- Generate versioned MBTiles

**Input:**
- `.osm.pbf`

**Output:**
- `data/build/<name>-<timestamp>.mbtiles`

---

### publish-tiles.sh

**Responsibility:**
- Validate MBTiles
- Update symlink
- Restart Martin

**Steps:**
1. Validate SQLite metadata
2. Create temp symlink
3. Atomic rename → `current.mbtiles`
4. Restart Martin

---

### rebuild-and-publish.sh

**Responsibility:**
- Orchestrate full pipeline

---

## Execution Workflow

### First Run

```
docker compose up -d
./scripts/rebuild-and-publish.sh data/incoming/file.osm.pbf
```

### Subsequent Runs

```
./scripts/rebuild-and-publish.sh new.osm.pbf
```

---

## API Endpoints

| Endpoint | Purpose |
|----------|--------|
| /catalog | List sources |
| /basemap | Tile source |

---

## Failure Modes & Handling

### Disk Full
- Build fails → no publish occurs

### Invalid MBTiles
- Publish script aborts

### Martin startup failure
- Configuration error → container exits

---

## Cleanup Strategy

Recommended:
- Keep last 3 builds
- Remove older files from `data/build/`

---

## Security Considerations

- No public write access
- Mount volumes as read-only where possible
- Run containers as non-root user

---

## Future Extensions

- PMTiles support
- CDN integration
- Automated cron builds
- Multi-region deployment

---

## Assumptions

- Single-node deployment
- No high-availability requirement
- Tiles served directly from disk

---

## Risks

| Risk | Impact |
|------|--------|
| Large PBF files | Long build times |
| RAM misconfiguration | Build failure |
| Style mismatch | Broken rendering |

---

## Minimal Runbook

```
# start server
docker compose up -d

# build + publish
./scripts/rebuild-and-publish.sh data/incoming/map.osm.pbf

# verify
curl http://localhost:3000/catalog
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
