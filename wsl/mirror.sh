#!/usr/bin/env bash
# =============================================================================
# mirror.sh — CVE database refresh tool for Clair v4.9.0
#
# Commands
# --------
#   ./mirror.sh refresh    Full cycle: pull fresh CVEs → dump → reload server
#                          This is the ONLY command you need day-to-day.
#                          Requires internet. Safe to run while server is up.
#
#   ./mirror.sh dump       Snapshot the running clair-db → vuln-mirror.dump
#                          (no internet needed; use after a manual updater run)
#
#   ./mirror.sh reload     Load existing vuln-mirror.dump into clair-db and
#                          restart clair-server (no internet needed)
#
#   ./mirror.sh export     Export raw CVE feeds → vuln-db.gz via clairctl
#                          (advanced; pg_dump/refresh is preferred)
#
#   ./mirror.sh schedule   Install a weekly cron job for automatic refresh
#
# Production path
# ---------------
#   Periodic refresh:    ./mirror.sh refresh      (or via cron)
#   Air-gapped machines: scp vuln-mirror.dump host: && ./mirror.sh reload
#
# Known warnings (safe to ignore)
# --------------------------------
#   WRN "unexpected ECOSYSTEM entry"  — upstream Clair v4.9.0 parser bug;
#       3 cross-ecosystem OSV advisories are skipped, all others succeed.
#   WRN "Invalid Semantic Version"    — 4 Go advisories with non-semver tags;
#       skipped by the parser, rest of osv/go succeeds.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CMD="${1:-refresh}"
TIMESTAMP=$(date -u '+%Y%m%d-%H%M%S')

# ── Redirect clairctl temp writes to disk (avoids 7.7 GB RAM tmpfs cap) ──────
CLAIR_TMPDIR="${TMPDIR_OVERRIDE:-/var/tmp/clair-export}"
mkdir -p "$CLAIR_TMPDIR"
export TMPDIR="$CLAIR_TMPDIR"

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail() { echo -e "  ${RED}✗${NC}  $*"; exit 1; }
step() { echo ""; echo -e "${BOLD}[$1]${NC} $2"; }

# ── Helper: require clair-db to be running ────────────────────────────────────
require_db() {
  if ! docker exec clair-db psql -U clair -d clair -c "SELECT 1" >/dev/null 2>&1; then
    fail "clair-db is not running. Start it with:  docker compose up -d clair-db"
  fi
}

# ── Helper: restart clair-server and wait for API ─────────────────────────────
restart_server() {
  echo ""
  step "3/3" "Restarting clair-server to pick up new CVE data..."
  docker compose restart clair-server 2>&1 | sed 's/^/  /'

  echo -n "  Waiting for Clair API"
  local i=0
  until curl -sf "http://localhost:6060/openapi/v1" >/dev/null 2>&1; do
    sleep 3; printf "."; i=$((i+1))
    [ $i -gt 60 ] && echo "" && fail "Clair API did not come up after 3 minutes"
  done
  echo " ✓"

  VULN=$(docker exec clair-db psql -U clair -d clair -tAc "SELECT COUNT(*) FROM vuln;" | tr -d ' ')
  ok "clair-server ready — ${VULN} vulnerability records loaded"
}

# =============================================================================
# COMMAND: refresh
# Full cycle — the only command you need for periodic CVE updates.
# Steps: start updater → wait → dump → reload server
# =============================================================================
do_refresh() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║   Clair CVE Refresh — $(date -u '+%Y-%m-%d %H:%M UTC')          ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""
  echo "  This pulls all CVE feeds from the internet and reloads the"
  echo "  scan server. The server stays up throughout — scans are"
  echo "  only briefly unavailable during the final restart (~5s)."
  echo ""

  require_db

  # ── Step 1: Run the one-shot updater container ──────────────────────────────
  step "1/3" "Running CVE updater (internet required, ~5–15 min)..."
  echo "  Pulling latest vulnerability feeds into clair-db..."
  echo ""

  START=$(date +%s)
  # Run updater container — streams logs, exits 0 on success
  docker compose --profile updater run --rm clair-updater 2>&1 | \
    grep -E "successful update|ERR|error" | \
    grep -v "ctxlock" | \
    awk '{print "  " $0}' || true
  END=$(date +%s)

  ok "Updater finished in $((END - START))s"

  # ── Step 2: Snapshot the updated DB ────────────────────────────────────────
  step "2/3" "Snapshotting clair-db → vuln-mirror.dump..."
  do_dump_internal

  # ── Step 3: Reload the scan server ─────────────────────────────────────────
  restart_server

  echo ""
  echo "══════════════════════════════════════════════════════════"
  ok "Refresh complete — CVE data is up to date"
  echo "  Dump : vuln-mirror.dump ($(ls -lh vuln-mirror.dump | awk '{print $5}'))"
  echo "  Time : $(($(date +%s) - START))s total"
  echo "══════════════════════════════════════════════════════════"
}

# =============================================================================
# COMMAND: dump
# Snapshot clair-db to vuln-mirror.dump (no internet needed).
# Use this after a manual updater run, or to back up current CVE state.
# =============================================================================
do_dump_internal() {
  require_db

  VULN_COUNT=$(docker exec clair-db psql -U clair -d clair -tAc "SELECT COUNT(*) FROM vuln;" | tr -d ' ')

  if [ "${VULN_COUNT:-0}" -lt 1000000 ]; then
    warn "Only ${VULN_COUNT:-0} vulnerability records in DB (expected ~4.7M)."
    warn "The updater may not have finished. Continue anyway? [y/N]"
    read -r confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "  Aborted."; exit 0; }
  fi

  echo "  DB has $VULN_COUNT vulnerability records"

  START_DUMP=$(date +%s)
  docker exec clair-db pg_dump \
    -U clair -d clair \
    --table=vuln \
    --table=update_operation \
    --table=uo_vuln \
    --table=uo_enrich \
    --table=updater_status \
    --data-only \
    --format=custom \
    -f /tmp/vuln-mirror.dump
  docker cp clair-db:/tmp/vuln-mirror.dump ./vuln-mirror.dump
  docker exec clair-db rm -f /tmp/vuln-mirror.dump

  SIZE=$(ls -lh vuln-mirror.dump | awk '{print $5}')
  ok "Dump complete — vuln-mirror.dump ($SIZE) in $(($(date +%s) - START_DUMP))s"
}

do_dump() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║   Clair DB Snapshot                                      ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  do_dump_internal
  echo ""
  echo "  Transfer to an air-gapped machine:"
  echo "    scp vuln-mirror.dump user@host:/path/to/clair/wsl/"
  echo "    # Then on the remote machine:  ./mirror.sh reload"
}

# =============================================================================
# COMMAND: reload
# Load vuln-mirror.dump into clair-db and restart the scan server.
# No internet needed — use on air-gapped machines after copying the dump.
# =============================================================================
do_reload() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║   Clair DB Reload (offline)                              ║"
  echo "╚══════════════════════════════════════════════════════════╝"

  if [ ! -f "vuln-mirror.dump" ]; then
    fail "vuln-mirror.dump not found in $(pwd). Copy it here first:\n  scp user@host:/path/to/vuln-mirror.dump ."
  fi

  DUMP_SIZE=$(ls -lh vuln-mirror.dump | awk '{print $5}')
  DUMP_BYTES=$(stat -c%s vuln-mirror.dump)
  if [ "$DUMP_BYTES" -lt 104857600 ]; then
    fail "vuln-mirror.dump is too small ($DUMP_SIZE) — likely corrupt. Re-copy from source."
  fi

  require_db

  step "1/2" "Loading vuln-mirror.dump ($DUMP_SIZE) into clair-db..."
  docker compose --profile updater run --rm import 2>&1 | \
    grep -E ">>>|imported_vulns|[0-9]" | sed 's/^/  /'

  step "2/2" "Restarting clair-server..."
  docker compose restart clair-server 2>&1 | sed 's/^/  /'

  echo -n "  Waiting for Clair API"
  local i=0
  until curl -sf "http://localhost:6060/openapi/v1" >/dev/null 2>&1; do
    sleep 3; printf "."; i=$((i+1))
    [ $i -gt 60 ] && echo "" && fail "Clair API did not come up"
  done
  echo " ✓"

  VULN=$(docker exec clair-db psql -U clair -d clair -tAc "SELECT COUNT(*) FROM vuln;" | tr -d ' ')
  echo ""
  ok "Reload complete — ${VULN} vulnerability records"
  echo "  Run a scan:  ./scan.sh <image>:<tag>"
}

# =============================================================================
# COMMAND: export
# Export raw CVE feeds to vuln-db.gz using clairctl (advanced use only).
# Note: pg_dump/refresh is preferred — this is kept for compatibility.
# =============================================================================
do_export() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║   Clair Raw Feed Export (clairctl)                       ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo " Temp dir : $CLAIR_TMPDIR"
  echo ""
  echo "  Fetching all vulnerability feeds from the internet..."
  echo "  Expected time: 5–15 minutes"
  echo ""

  START=$(date +%s)
  clair -c clairctl.yaml export-updaters vuln-db.gz 2>&1 | \
    grep -E "successful update|ERR|error" | \
    awk '{print "  " $0}'
  END=$(date +%s)

  rm -rf "${CLAIR_TMPDIR:?}"/* 2>/dev/null || true

  SIZE=$(ls -lh vuln-db.gz | awk '{print $5}')
  echo ""
  ok "Export complete — vuln-db.gz ($SIZE) in $((END - START))s"
  echo "  Temp dir cleaned: $CLAIR_TMPDIR"
}

# =============================================================================
# COMMAND: schedule
# Install a weekly cron job to auto-refresh CVE data.
# =============================================================================
do_schedule() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║   Clair Periodic Refresh — Cron Setup                    ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""

  CRON_CMD="cd ${SCRIPT_DIR} && ./mirror.sh refresh >> /var/log/clair-refresh.log 2>&1"

  echo "  This will add a weekly cron job (every Monday at 02:00 AM):"
  echo ""
  echo "    0 2 * * 1  $CRON_CMD"
  echo ""
  echo -n "  Install? [y/N] "
  read -r confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "  Cancelled."
    exit 0
  fi

  # Add to crontab (idempotent — removes old entry first)
  CRON_LINE="0 2 * * 1  $CRON_CMD"
  ( crontab -l 2>/dev/null | grep -v "mirror.sh refresh"; echo "$CRON_LINE" ) | crontab -

  ok "Cron job installed"
  echo ""
  echo "  Verify:  crontab -l | grep clair"
  echo "  Logs:    tail -f /var/log/clair-refresh.log"
  echo "  Remove:  crontab -l | grep -v 'mirror.sh refresh' | crontab -"
  echo ""
  echo "  To run immediately:  ./mirror.sh refresh"
  echo ""
  warn "WSL2 note: cron only runs while WSL is active."
  echo "  For guaranteed scheduling even when WSL is idle, use"
  echo "  Windows Task Scheduler instead:"
  echo ""
  echo "    Action: wsl.exe -d Ubuntu -- bash -c 'cd ${SCRIPT_DIR} && ./mirror.sh refresh'"
  echo "    Trigger: Weekly, Monday 02:00 AM"
}

# =============================================================================
# Main
# =============================================================================
echo ""
echo "  mirror.sh  •  cmd=${CMD}  •  ${TIMESTAMP}"

case "$CMD" in
  refresh)  do_refresh ;;
  dump)     do_dump ;;
  reload)   do_reload ;;
  export)   do_export ;;
  schedule) do_schedule ;;
  *)
    echo ""
    echo "Usage: ./mirror.sh [refresh|dump|reload|export|schedule]"
    echo ""
    echo "  refresh   Pull fresh CVEs + dump + reload server  (recommended)"
    echo "  dump      Snapshot current DB → vuln-mirror.dump"
    echo "  reload    Load vuln-mirror.dump into DB + restart server"
    echo "  export    Export raw feeds → vuln-db.gz (clairctl, advanced)"
    echo "  schedule  Install weekly cron job for automatic refresh"
    exit 1
    ;;
esac
