# Clair v4.9.0 — Local Image Scanning on WSL2

Scan Docker images for CVEs locally using [Clair v4](https://github.com/quay/clair).  
No cloud, no external API. Runs entirely offline after the first setup.

---

## How it works

```
┌─────────────────────────────────────────────────────────┐
│  ALWAYS RUNNING                                         │
│                                                         │
│   clair-db       PostgreSQL — stores CVE data           │
│   clair-registry Local OCI registry (port 5000)         │
│   clair-server   Clair scan API (port 6060)             │
│                  updaters DISABLED — runs offline       │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  ON DEMAND  (./mirror.sh refresh)                       │
│                                                         │
│   clair-updater  Pulls CVE feeds from internet          │
│                  Writes to clair-db, then exits         │
│                  No ports — never serves scans          │
└─────────────────────────────────────────────────────────┘
```

`clair-server` always serves from the database — no live internet feed.  
To get fresh CVEs, run `./mirror.sh refresh` (takes ~15 min, once a week is enough).

---

## Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | All services: registry, clair-db, clair-server, clair-updater |
| `clair-config-offline.yaml` | Clair server config — updaters disabled |
| `clair-config-updater.yaml` | Clair updater config — used only during refresh |
| `clairctl.yaml` | Config for `clair export-updaters` (advanced) |
| `scan.sh` | Scan a local Docker image |
| `mirror.sh` | CVE database refresh tool |
| `switch.sh` | Stack control (status / start / restart / down) |
| `bootstrap.sh` | First-time setup — run once on a fresh clone |
| `vuln-mirror.dump` | CVE database snapshot — **not in git** (transfer separately) |
| `clair` | `clairctl` binary — **not in git** (download from GitHub releases) |

---

## Prerequisites

- Docker Desktop with WSL2 integration enabled
- WSL2 (Ubuntu 22.04 or later)
- `curl` — `sudo apt-get install -y curl`
- Internet access for first-time setup (offline after that)

---

## Quick start (fresh machine)

### 1. Clone the repo

```bash
git clone https://github.com/vaibhavvsk/clair.git
cd clair/wsl
```

### 2. Get the clairctl binary

Download from [GitHub releases](https://github.com/quay/clair/releases/tag/v4.9.0):

```bash
curl -fL -o clair https://github.com/quay/clair/releases/download/v4.9.0/clairctl-linux-amd64
chmod +x clair
# Add to PATH permanently
echo 'export PATH="$HOME/tools/clair/v4.9.0:$PATH"' >> ~/.bashrc && source ~/.bashrc
```

### 3. Bootstrap

```bash
./bootstrap.sh
```

This will:
- Check all dependencies
- Start clair-db, clair-registry, clair-server
- If no `vuln-mirror.dump` is found → run a full CVE refresh (~15 min, internet required)
- Load the CVE database and verify the API is up

> **Already have a `vuln-mirror.dump`?** Copy it into this directory first — bootstrap will use it instantly, no internet needed.

---

## Scanning an image

```bash
./scan.sh <image>:<tag>              # text output (default)
./scan.sh <image>:<tag> json         # JSON output
./scan.sh <image>:<tag> xml          # XML output
```

**Example:**

```bash
./scan.sh prometheus-ubi10:latest
```

```
╔══════════════════════════════════════════════════════╗
║         Clair v4 Image Scanner                       ║
╚══════════════════════════════════════════════════════╝
 Image    : prometheus-ubi10:latest
 Registry : localhost:5000/prometheus-ubi10:latest

[1/4] Checking Clair API...          ✓
[2/4] Checking local Docker image... ✓
[3/4] Pushing to local registry...   ✓
[4/4] Requesting vulnerability report...

prometheus-ubi10:latest ok

Report saved to: clair-report-prometheus-ubi10-latest.txt
```

`ok` = no vulnerabilities found.  
The report is also saved to a file in the current directory.

### What `scan.sh` does

1. Tags the image as `localhost:5000/<image>:<tag>`
2. Pushes it to the local registry
3. Calls `clair report --host http://localhost:6060 localhost:5000/<image>:<tag>`

---

## Reading the report

### Text output

```
Package              Version    Vuln ID          Severity  Fixed in
openssl              3.0.2      CVE-2023-0286    High      3.0.2-0ubuntu1.9
```

### JSON output

```bash
./scan.sh myimage:latest json
cat clair-report-myimage-latest.json | python3 -m json.tool | head -60
```

Key fields:

```json
{
  "manifest_hash": "sha256:...",
  "packages": { "42": { "name": "openssl", "version": "3.0.2" } },
  "vulnerabilities": {
    "CVE-2023-0286": {
      "name": "CVE-2023-0286",
      "normalized_severity": "High",
      "fixed_in_version": "3.0.2-0ubuntu1.9",
      "links": "https://access.redhat.com/..."
    }
  },
  "package_vulnerabilities": { "42": ["CVE-2023-0286"] }
}
```

### Count CVEs by severity

```bash
cat clair-report-myimage-latest.json | python3 -c "
import json, sys
data = json.load(sys.stdin)
vulns = data.get('vulnerabilities', {})
print(f'Total: {len(vulns)}')
sev = {}
for v in vulns.values():
    s = v.get('normalized_severity','Unknown')
    sev[s] = sev.get(s, 0) + 1
for s, c in sorted(sev.items()):
    print(f'  {s}: {c}')
"
```

---

## Refreshing the CVE database

Run this periodically (weekly recommended) to keep vulnerability data current:

```bash
./mirror.sh refresh
```

This does the full cycle automatically:
1. Starts `clair-updater` (one-shot container, internet required)
2. Pulls all CVE feeds into `clair-db` (~5–15 min)
3. Snapshots the DB → `vuln-mirror.dump`
4. Restarts `clair-server` to pick up new data (~5 s downtime)

The scan server stays up throughout steps 1–3. Only step 4 causes a brief restart.

### Set up automatic weekly refresh

```bash
./mirror.sh schedule
```

Installs a cron job: **every Monday at 02:00 AM**.

```
Verify:   crontab -l | grep clair
Logs:     tail -f /var/log/clair-refresh.log
Remove:   crontab -l | grep -v 'mirror.sh refresh' | crontab -
```

> **WSL2 note:** cron only runs while WSL is active. For guaranteed scheduling when WSL is idle, use Windows Task Scheduler (see below).

### Windows Task Scheduler (reliable on WSL2)

Create a scheduled task that runs weekly:

- **Action:** `wsl.exe -d Ubuntu -- bash -c 'cd /home/<user>/tools/clair/v4.9.0 && ./mirror.sh refresh >> /var/log/clair-refresh.log 2>&1'`
- **Trigger:** Weekly, Monday, 02:00 AM

---

## Air-gapped / offline machines

On a machine that **never has internet access**, transfer the dump from a connected machine:

**On the internet-connected machine:**
```bash
./mirror.sh refresh        # pull fresh CVEs and snapshot
scp vuln-mirror.dump user@offline-host:/path/to/clair/wsl/
```

**On the offline machine:**
```bash
# Copy the repo files (no internet needed — binary + dump only)
./mirror.sh reload         # load dump into DB + restart server
./scan.sh myimage:latest   # scan immediately
```

`./mirror.sh reload` requires no internet — it only reads `vuln-mirror.dump` from disk.

---

## Stack control

```bash
./switch.sh status     # show containers + vuln record count
./switch.sh start      # start all containers
./switch.sh restart    # restart clair-server only
./switch.sh down       # stop everything + remove volumes
```

```bash
./bootstrap.sh         # idempotent — safe to re-run any time
./bootstrap.sh refresh # force a fresh CVE pull even if dump exists
```

---

## mirror.sh reference

```bash
./mirror.sh refresh    # full cycle: pull CVEs → dump → reload (recommended)
./mirror.sh dump       # snapshot DB → vuln-mirror.dump (no internet)
./mirror.sh reload     # load dump → DB + restart server (no internet)
./mirror.sh schedule   # install weekly cron job
./mirror.sh export     # raw clairctl export → vuln-db.gz (advanced)
```

---

## Troubleshooting

### Clair API not responding after `./switch.sh start`

```bash
docker logs clair-server --tail 30 2>&1 | grep -v ctxlock
```

Common causes:
- **`network is unreachable`** — run `./switch.sh down && ./switch.sh start` to recreate the Docker network
- **`no space left on device`** — during `./mirror.sh export`, disk is full; `./mirror.sh refresh` uses the updater container which writes to the DB directly (no `/tmp` pressure)

### `ctxlock … /tmp/.s.PGSQL.5432` warnings in logs

Harmless. The `PGHOST`/`PGUSER`/`PGPASSWORD`/`PGDATABASE`/`PGSSLMODE` env vars in `docker-compose.yml` suppress most of them.

### `unexpected return status: 500` from `clair report`

The DB has no vulnerability data yet. Check:

```bash
docker exec clair-db psql -U clair -d clair -tAc "SELECT COUNT(*) FROM vuln;"
```

If the count is 0 or very low, run `./mirror.sh reload` (if you have a dump) or `./mirror.sh refresh` (if you have internet).

### `unexpected ECOSYSTEM entry` / `Invalid Semantic Version` in mirror.sh output

These are `WRN` (warning) lines — not errors. They are a known upstream Clair v4.9.0 parser limitation affecting 3–4 OSV advisories out of millions. All other vulnerabilities are captured correctly.

### Port 5000 already in use

```bash
# Find what's using it
sudo lsof -i :5000
# Or change the registry port in docker-compose.yml:
#   ports: ["5001:5000"]
# Then update REGISTRY in scan.sh to localhost:5001
```

### `172.18.0.1` — the Docker bridge gateway IP

The `extra_hosts: ["localhost:172.18.0.1"]` in `docker-compose.yml` maps `localhost` inside the `clair-server` container to the Docker bridge gateway (the host from the container's perspective).

If your setup uses a different IP:

```bash
# Find the gateway of the compose network
docker network inspect v490_default \
  --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}'
```

Update `docker-compose.yml` `extra_hosts` to match.

---

## Notes for colleagues cloning this repo

1. **The `clair` binary and `vuln-mirror.dump` are not in git** (binary is 26 MB, dump is ~800 MB). Get them:
   - Binary: `curl -fL -o clair https://github.com/quay/clair/releases/download/v4.9.0/clairctl-linux-amd64 && chmod +x clair`
   - Dump: copy from a colleague who has already run `./mirror.sh refresh`, or run it yourself (needs internet, ~15 min)

2. **Run `./bootstrap.sh`** — it handles everything automatically.

3. **Scanning works 100% offline** once you have the dump. No internet required after setup.
