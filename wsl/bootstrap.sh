#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — First-time setup for Clair v4.9.0 on WSL2
#
# Run once on a fresh clone. Checks all dependencies, downloads the binary
# if missing, and starts the stack. Always runs in offline mode — if no
# vuln-mirror.dump is found it runs a full refresh first (requires internet).
#
# Usage:
#   ./bootstrap.sh           # auto: offline if dump exists, refresh if not
#   ./bootstrap.sh refresh   # force a fresh CVE pull even if dump exists
#
# Safe to re-run — every step is idempotent.
# =============================================================================
set -euo pipefail

CLAIR_VERSION="v4.9.0"
CLAIR_BINARY_URL="https://github.com/quay/clair/releases/download/${CLAIR_VERSION}/clairctl-linux-amd64"
CLAIR_API="http://localhost:6060"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE_REFRESH="${1:-}"

TOTAL=5
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail() { echo -e "  ${RED}✗${NC}  $*"; exit 1; }
step() { echo ""; echo "[$1/$TOTAL] $2"; }

cd "$SCRIPT_DIR"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║       Clair v4.9.0 — Bootstrap                       ║"
echo "╚══════════════════════════════════════════════════════╝"
echo " Version : $CLAIR_VERSION"
echo " Dir     : $SCRIPT_DIR"
echo ""

# ═════════════════════════════════════════════════════════════════════════════
# STEP 1 — System dependencies
# ═════════════════════════════════════════════════════════════════════════════
step 1 "Checking system dependencies"

MISSING=()
command -v docker  &>/dev/null && ok "docker $(docker --version | awk '{print $3}' | tr -d ',')" || MISSING+=("docker")
docker compose version &>/dev/null && ok "docker compose" || MISSING+=("docker-compose-plugin")
command -v curl    &>/dev/null && ok "curl" || MISSING+=("curl")

if [ ${#MISSING[@]} -gt 0 ]; then
  fail "Missing: ${MISSING[*]}.  Install: sudo apt-get install -y curl  |  https://docs.docker.com/engine/install/ubuntu/"
fi

docker info &>/dev/null || fail "Docker daemon not running — start Docker Desktop first."
ok "Docker daemon running"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2 — clairctl binary
# ═════════════════════════════════════════════════════════════════════════════
step 2 "Checking clairctl binary"

if [ -x "./clair" ] && ./clair --version 2>&1 | grep -q "$CLAIR_VERSION"; then
  ok "clair binary present ($(./clair --version 2>&1 | head -1))"
elif [ -x "./clairctl-linux-amd64" ]; then
  cp ./clairctl-linux-amd64 ./clair && chmod +x ./clair
  ok "Copied clairctl-linux-amd64 → clair"
else
  warn "Binary not found — downloading from GitHub..."
  curl -fL --progress-bar -o ./clairctl-linux-amd64 "$CLAIR_BINARY_URL" \
    || fail "Download failed. Get it manually: $CLAIR_BINARY_URL"
  chmod +x ./clairctl-linux-amd64
  cp ./clairctl-linux-amd64 ./clair
  ok "Downloaded: $(./clair --version 2>&1 | head -1)"
fi

command -v clair &>/dev/null || { export PATH="$SCRIPT_DIR:$PATH"; warn "Added $SCRIPT_DIR to PATH (add to ~/.bashrc to make permanent)"; }

# ═════════════════════════════════════════════════════════════════════════════
# STEP 3 — Config files
# ═════════════════════════════════════════════════════════════════════════════
step 3 "Checking config files"

MISSING_FILES=()
for f in docker-compose.yml clair-config-offline.yaml clair-config-updater.yaml clairctl.yaml scan.sh mirror.sh switch.sh; do
  [ -f "./$f" ] && ok "$f" || { MISSING_FILES+=("$f"); warn "$f MISSING"; }
done

if [ ${#MISSING_FILES[@]} -gt 0 ]; then
  echo ""
  fail "Missing files — re-clone:\n  git clone https://github.com/vaibhavvsk/clair.git && cd clair/wsl"
fi

chmod +x scan.sh mirror.sh switch.sh bootstrap.sh 2>/dev/null || true

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4 — Ensure vuln-mirror.dump exists (refresh if not)
# ═════════════════════════════════════════════════════════════════════════════
step 4 "Checking vulnerability database"

DUMP_OK=false
if [ -f "./vuln-mirror.dump" ]; then
  DUMP_BYTES=$(stat -c%s ./vuln-mirror.dump)
  DUMP_SIZE=$(ls -lh ./vuln-mirror.dump | awk '{print $5}')
  if [ "$DUMP_BYTES" -gt 104857600 ]; then
    DUMP_OK=true
    ok "vuln-mirror.dump present ($DUMP_SIZE)"
  else
    warn "vuln-mirror.dump exists but too small ($DUMP_SIZE) — likely corrupt, will refresh"
  fi
else
  warn "vuln-mirror.dump not found"
fi

if ! $DUMP_OK || [ "$FORCE_REFRESH" = "refresh" ]; then
  echo ""
  echo "  ┌─────────────────────────────────────────────────────────────┐"
  echo "  │  CVE database needed — running first-time refresh           │"
  echo "  │  Requires internet. Takes ~15–20 min on first run.          │"
  echo "  │                                                              │"
  echo "  │  After this, all future scans work completely offline.       │"
  echo "  └─────────────────────────────────────────────────────────────┘"
  echo ""

  # Start DB + registry before refresh
  docker compose up -d clair-db registry 2>&1 | grep -E "Start|Create|Running|✔" | sed 's/^/  /'

  # Wait for DB to be healthy
  echo -n "  Waiting for clair-db"
  until docker exec clair-db psql -U clair -d clair -c "SELECT 1" >/dev/null 2>&1; do
    sleep 2; printf "."
  done
  echo " ✓"

  # Run the full refresh (updater → dump — no server restart needed yet)
  # Pass --no-restart flag to mirror.sh refresh so it doesn't try to restart
  # a server that isn't running yet
  docker compose --profile updater run --rm clair-updater 2>&1 | \
    grep -E "successful update|ERR|error" | grep -v ctxlock | awk '{print "  " $0}' || true
  ok "CVE updater complete"

  echo ""
  echo "  Snapshotting DB → vuln-mirror.dump..."
  docker exec clair-db pg_dump \
    -U clair -d clair \
    --table=vuln --table=update_operation --table=uo_vuln \
    --table=uo_enrich --table=updater_status \
    --data-only --format=custom -f /tmp/vuln-mirror.dump
  docker cp clair-db:/tmp/vuln-mirror.dump ./vuln-mirror.dump
  docker exec clair-db rm -f /tmp/vuln-mirror.dump
  ok "vuln-mirror.dump saved ($(ls -lh vuln-mirror.dump | awk '{print $5}'))"
  DUMP_OK=true
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 5 — Start the stack
# ═════════════════════════════════════════════════════════════════════════════
step 5 "Starting Clair stack"

# Start DB + registry + scan server
docker compose up -d clair-server registry 2>&1 | grep -E "Start|Create|Running|✔|✗" | sed 's/^/  /'

# If DB just came up fresh from updater run, we need to load the dump
VULN_COUNT=$(docker exec clair-db psql -U clair -d clair -tAc "SELECT COUNT(*) FROM vuln;" 2>/dev/null | tr -d ' ')
if [ "${VULN_COUNT:-0}" -lt 1000000 ] && [ -f "./vuln-mirror.dump" ]; then
  echo "  Loading vuln-mirror.dump into clair-db..."
  docker compose --profile updater run --rm import 2>&1 | \
    grep -E ">>>|imported_vulns|[0-9]" | sed 's/^/  /'
  docker compose restart clair-server 2>&1 | sed 's/^/  /'
fi

echo -n "  Waiting for Clair API"
i=0
until curl -sf "${CLAIR_API}/openapi/v1" >/dev/null 2>&1; do
  sleep 3; printf "."; i=$((i+1))
  [ $i -gt 60 ] && echo " TIMEOUT" && exit 1
done
echo " ✓"

VULN_COUNT=$(docker exec clair-db psql -U clair -d clair -tAc "SELECT COUNT(*) FROM vuln;" 2>/dev/null | tr -d ' ')

echo ""
echo "══════════════════════════════════════════════════════"
ok "Bootstrap complete"
echo "  API          : $CLAIR_API"
echo "  Vuln records : $VULN_COUNT"
echo ""
echo "  Scan an image:"
echo "    ./scan.sh <image>:<tag>"
echo "    ./scan.sh <image>:<tag> json"
echo ""
echo "  Refresh CVE database:"
echo "    ./mirror.sh refresh          # pull + dump + reload server"
echo "    ./mirror.sh schedule         # set up weekly auto-refresh"
echo ""
echo "  Air-gapped machines:"
echo "    scp vuln-mirror.dump user@host:/path/to/clair/wsl/"
echo "    # On that machine:  ./mirror.sh reload"
echo ""
echo "  Stack control:"
echo "    ./switch.sh status"
echo "    ./switch.sh down"
echo "══════════════════════════════════════════════════════"
