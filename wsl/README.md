# Clair v4.9.0 — Local Image Scanning on WSL2

Scan any local Docker image for vulnerabilities using
[Clair v4](https://github.com/quay/clair) running entirely on your WSL2 machine.
No cloud account, no external registry, no license required.

---

## Files in this directory

| File | Purpose |
|------|---------|
| [`docker-compose.yml`](#docker-composeyml) | Spins up the 3 required containers: OCI registry, PostgreSQL, and Clair server |
| [`clair-config.yaml`](#clair-configyaml) | Clair server configuration (ports, DB connection, matchers, updater feeds) |
| [`scan.sh`](#scansh) | Helper script — tags, pushes and scans any local Docker image in one command |
| `clairctl-linux-amd64` | Official `clairctl` CLI binary downloaded from the Clair v4.9.0 release page |
| `clair` | Symlink / copy of `clairctl-linux-amd64` placed on `$PATH` |

---

## Architecture overview

```
WSL2 host
│
├── docker-compose.yml
│     ├── clair-registry  (registry:2)          :5000  ← stores image layers
│     ├── clair-db        (postgres:15-alpine)   :5432  ← stores vuln DB + index reports
│     └── clair-server    (clair:4.9.0)          :6060  ← API   :8089 ← metrics/health
│
└── clairctl (on $PATH)   ← CLI that talks to clair-server:6060
```

**Why a local registry?**
`clairctl` submits an image *manifest* (list of layer URLs) to Clair.
Clair then pulls the actual layer blobs over HTTP from those URLs.
Because it runs inside a container, it cannot reach the Docker daemon directly —
it needs an OCI registry. The `registry:2` container in the compose file serves that role.

---

## Prerequisites

- **Docker Desktop** (or Docker Engine) running in WSL2
- `clair` binary on `$PATH` (already set up if you are reading this)
- Internet access on first run (Clair downloads vulnerability feeds ~200 MB)

Verify:
```bash
docker version          # Docker is running
clair --version         # prints: clairctl v4.9.0 (claircore v1.5.48)
```

---

## One-time setup

### 1. Clone / copy this directory

```bash
# All files should already be present. Confirm:
ls docker-compose.yml clair-config.yaml scan.sh clair
```

### 2. Make scan.sh executable

```bash
chmod +x scan.sh
```

### 3. Start the Clair stack

```bash
docker compose up -d
```

This starts three containers:

| Container | Image | Role |
|-----------|-------|------|
| `clair-registry` | `registry:2` | Local OCI registry (port 5000) |
| `clair-db` | `postgres:15-alpine` | Vulnerability + index database (port 5432, internal) |
| `clair-server` | `quay.io/projectquay/clair:4.9.0` | Scanner API (port 6060) |

### 4. Wait for Clair to be ready

**First-ever start** takes **30–60 minutes** — Clair downloads vulnerability feeds
(RHEL, Ubuntu, Debian, Alpine, AWS, Oracle, SUSE, OSV) and loads them into PostgreSQL.

**Subsequent starts** with an existing DB take **~5 seconds**.

Poll until ready:
```bash
# Repeat until you get a JSON response (not "connection refused")
curl http://localhost:6060/openapi/v1
```

Expected output when ready:
```json
{"info": {"title": "Clair Container Analyzer", "version": "1.2.0"}, ...}
```

> **Tip — check progress while waiting:**
> ```bash
> docker logs clair-server --follow 2>&1 | grep -v ctxlock
> ```
> Watch for `"starting background updates"` — that means the first pass is done and port 6060 is open.

---

## Scanning an image

### Option A — scan.sh (recommended)

```bash
# Text output (default)
./scan.sh prometheus-ubi10:latest

# JSON output
./scan.sh prometheus-ubi10:latest json

# Any other local image
./scan.sh my-app:1.2.3
./scan.sh my-app:1.2.3 json
```

The script will:
1. Check Clair API is reachable
2. Verify the image exists locally
3. Tag and push it to `localhost:5000/<image>`
4. Submit the manifest to Clair and print the report
5. Save the report to `clair-report-<image>.<format>`

---

### Option B — manual step-by-step

```bash
# 1. Push your image to the local registry
docker tag my-app:latest localhost:5000/my-app:latest
docker push localhost:5000/my-app:latest

# 2. Request a text report
clair report \
  --host http://localhost:6060 \
  --out  text \
  localhost:5000/my-app:latest

# 3. Request a JSON report and save it
clair report \
  --host http://localhost:6060 \
  --out  json \
  localhost:5000/my-app:latest > clair-report-my-app.json
```

---

## Reading the report

### Text output

```
prometheus-ubi10:latest ok        ← "ok" means 0 vulnerabilities found by Clair
```

Or with findings:
```
┌──────────┬──────────────────────┬──────────┬──────────┬──────────────────┬──────────────┐
│ Package  │ Vulnerability        │ Severity │ Fixed In │ Installed        │ Description  │
└──────────┴──────────────────────┴──────────┴──────────┴──────────────────┴──────────────┘
```

### JSON output — key fields

```jsonc
{
  "manifest_hash": "sha256:...",    // unique ID of the scanned image
  "packages": { ... },              // all packages found (OS + language deps)
  "vulnerabilities": {              // CVEs matched — empty = clean
    "CVE-2021-1234": {
      "name": "CVE-2021-1234",
      "severity": "High",
      "package": { "name": "openssl", "version": "1.1.1" },
      "fixed_in_version": "1.1.1k"
    }
  }
}
```

### Check the index report directly (API)

```bash
# Get the manifest hash first
HASH=$(clair manifest localhost:5000/my-app:latest | python3 -c "import sys,json; print(json.load(sys.stdin)['hash'])")

# Fetch the full index report (packages + distributions found)
curl -s http://localhost:6060/indexer/api/v1/index_report/$HASH | python3 -m json.tool
```

---

## Stopping and restarting

```bash
# Stop (keeps the DB volume — fast restart next time)
docker compose down

# Stop AND delete the vulnerability DB (forces full re-download on next start)
docker compose down -v

# Restart (uses warm DB — port 6060 opens in ~5 seconds)
docker compose up -d
```

---

## Troubleshooting

### `curl: (56) Recv failure: Connection reset by peer` on port 6060

Clair is **still initialising** (running updaters / DB migrations).
The HTTP server only starts after the first updater pass completes.

```bash
# Watch progress
docker logs clair-server --follow 2>&1 | grep -v ctxlock | grep -v "driveUpdater"
# Wait for this line:
#   "message":"starting background updates"
```

### `ctxlock … /tmp/.s.PGSQL.5432 … no such file or directory` warnings

**Harmless — ignore.** This is a background reconnect loop inside Clair that
uses a Unix socket fallback. It does not affect functionality.
The `PGHOST` / `PGUSER` env vars in `docker-compose.yml` suppress it on the main code path.

### `unexpected return status: 500` from `clair report`

Clair's indexer could not fetch image layers. Check:
```bash
docker logs clair-server --tail 20 2>&1 | grep -v ctxlock
```

Common cause: the image was not pushed to the local registry before scanning.
Always push first:
```bash
docker tag my-app:latest localhost:5000/my-app:latest
docker push localhost:5000/my-app:latest
```

### `flag provided but not defined: -host`

The global `clair` command does not accept `--host`.
`--host` is a sub-command flag — it must come **after** `report`:
```bash
# Wrong
clair --host http://localhost:6060 report ...

# Correct
clair report --host http://localhost:6060 ...
```

### Port 5000 already allocated / `clair-registry` stuck in "Starting"

A stray `registry` container created outside of `docker compose` (e.g. by a plain
`docker run`) is holding port 5000, preventing `clair-registry` from binding it.

Diagnose:
```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep 5000
```

Fix — remove any non-compose registry containers, then bring the stack up:
```bash
# Remove all stray registry containers (adjust names as shown by docker ps above)
docker rm -f registry local-registry

# Bring compose stack up cleanly
docker compose up -d
```

> **Rule of thumb:** always manage the registry through `docker compose`, never
> with standalone `docker run`. The compose file owns all three services:
> `clair-registry`, `clair-db`, and `clair-server`.

---

## File reference

### `docker-compose.yml`

Defines all three services needed to run Clair locally.

Key design decisions:
- **`extra_hosts: ["localhost:172.18.0.1"]`** on `clair-server` — remaps `localhost` inside
  the container to the Docker bridge gateway (`172.18.0.1`), so Clair can reach
  `localhost:5000` (the registry) when fetching image layers.
- **`PGHOST` / `PGUSER` / `PGPASSWORD` env vars** on `clair-server` — ensures Clair's
  internal connection pool always uses TCP to `clair-db`, not a Unix socket fallback.
- **`clair-db` healthcheck** — Clair's `depends_on` waits for PostgreSQL to be fully
  ready before starting, preventing startup race conditions.
- **Named volume `clair-db-data`** — the downloaded vulnerability database persists
  across `docker compose down` / `up` cycles. Delete with `docker compose down -v`
  only when you want a full re-download.

### `clair-config.yaml`

Mounted read-only into the Clair container at `/etc/clair/config.yaml`.

| Section | What it controls |
|---------|-----------------|
| `http_listen_addr` | API port (`0.0.0.0:6060`) — what `clairctl` talks to |
| `introspection_addr` | Metrics + health port (`0.0.0.0:8089`) |
| `indexer.connstring` | PostgreSQL TCP connection for the layer indexer |
| `matcher.connstring` | PostgreSQL TCP connection for the vulnerability matcher |
| `matcher.indexer_addr` | Where matcher calls the indexer (same process = `localhost:6060`) |
| `matchers.names` | Active vulnerability matchers (rhel, ubuntu, alpine, gobin, etc.) |
| `updaters.sets` | Vulnerability feed sources to download (rhel, debian, ubuntu, osv, etc.) |

### `scan.sh`

Convenience wrapper around three `docker` + `clair` commands.

```
./scan.sh [IMAGE] [FORMAT]
```

Internally runs:
```bash
docker tag  <IMAGE>  localhost:5000/<IMAGE>
docker push localhost:5000/<IMAGE>
clair report --host http://localhost:6060 --out <FORMAT> localhost:5000/<IMAGE>
```

Output is both printed to the terminal and saved to `clair-report-<image>.<format>`.

### `clairctl-linux-amd64` / `clair`

The official CLI binary from the
[Clair v4.9.0 release](https://github.com/quay/clair/releases/tag/v4.9.0).
`clair` is the name on `$PATH` (symlink or copy of `clairctl-linux-amd64`).

Available sub-commands relevant to scanning:

| Command | Purpose |
|---------|---------|
| `clair report --host <url> <registry/image:tag>` | Run a full scan and print results |
| `clair manifest <registry/image:tag>` | Print the image manifest Clair would submit |
| `clair delete <manifest-hash>` | Remove a cached index report from Clair's DB |
| `clair check-config -c clair-config.yaml` | Validate config file without starting the server |

---

## Notes for WSL2

### Understanding `172.18.0.1` — where this IP comes from

This IP is the **gateway of the Docker bridge network** that `docker compose` creates
for this project. It is the address of the host machine as seen from inside any container
on that network.

**Why it is needed here:**
The `clair-server` container fetches image layers from the registry using URLs like
`http://localhost:5000/v2/…`. Inside a container, `localhost` resolves to the container's
own loopback (`127.0.0.1`), not the host. The `extra_hosts` entry in `docker-compose.yml`
overrides `/etc/hosts` inside `clair-server` so that `localhost` points to the host gateway
instead:

```
# Inside clair-server /etc/hosts (added by extra_hosts:)
172.18.0.1   localhost
```

---

### How to find YOUR gateway IP

Docker assigns a new subnet for each compose project. The compose network for this project
is named `v490_default` (derived from the directory name `v4.9.0`).
**Always query the compose network, not the default bridge.**

#### Step 1 — list all Docker networks

```bash
docker network ls
```

Example output:
```
NETWORK ID     NAME           DRIVER    SCOPE
389ba49caed1   bridge         bridge    local   ← Docker's default bridge (172.17.x.x)
08e31fe2fe9d   v490_default   bridge    local   ← this project's network (172.18.x.x)
a8ffb2eb0176   host           host      local
```

#### Step 2 — get the gateway of the compose network

```bash
docker network inspect v490_default \
  --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}'
```

Example output:
```
172.18.0.1
```

> **Note:** The default `bridge` network (used by plain `docker run`) typically has gateway
> `172.17.0.1` — **different** from the compose network. Do not mix them up.

#### Step 3 — one-liner to get it automatically

```bash
docker network inspect \
  "$(docker inspect clair-server --format '{{(index .NetworkSettings.Networks 0).NetworkID}}' 2>/dev/null || \
     docker network ls --filter name=default --quiet | head -1)" \
  --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}'
```

Or the simpler approach — inspect the running `clair-server` container directly:

```bash
docker inspect clair-server \
  --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}'
```

Example output:
```
172.18.0.1
```

#### Step 4 — verify it is set correctly inside the container

```bash
docker exec clair-server sh -c 'cat /etc/hosts | grep localhost'
```

Expected output (the third line is the one added by `extra_hosts`):
```
127.0.0.1    localhost
::1          localhost ip6-localhost ip6-loopback
172.18.0.1   localhost          ← ✓ this must match your gateway IP
```

---

### If your gateway IP is different

If Step 2 returns a different IP (e.g. `172.19.0.1`), update `docker-compose.yml`
before running `docker compose up`:

```yaml
# docker-compose.yml  ← find this block under clair-server:
extra_hosts:
  - "localhost:172.19.0.1"   # replace with YOUR gateway IP
```

Then recreate the container:
```bash
docker compose up -d --force-recreate clair-server
```

Verify with Step 4 above.

---

### Quick reference — all gateway commands

```bash
# Gateway of this project's compose network
docker network inspect v490_default \
  --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}'

# Gateway as seen from inside the clair-server container
docker inspect clair-server \
  --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}'

# Confirm /etc/hosts override is in place inside the container
docker exec clair-server sh -c 'cat /etc/hosts | grep localhost'

# All container IPs on the compose network at a glance
docker network inspect v490_default \
  --format '{{range .Containers}}{{.Name}} → {{.IPv4Address}}{{"\n"}}{{end}}'
```

---

- The local registry (`localhost:5000`) is pre-configured as an **insecure registry**
  by Docker Desktop for WSL2 (loopback addresses are trusted by default).
  No TLS setup is needed.

- Clair's port 6060 is mapped `0.0.0.0:6060` — accessible from your Windows browser
  at `http://localhost:6060/openapi/v1` as well.
