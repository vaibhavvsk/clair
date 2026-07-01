#!/usr/bin/env bash
# =============================================================================
# switch.sh — Clair stack control
#
# Usage:
#   ./switch.sh status    Show running containers + vuln record count
#   ./switch.sh down      Stop everything and remove volumes
#   ./switch.sh start     Start clair-server + registry + clair-db
#   ./switch.sh restart   Restart just clair-server (e.g. after a DB reload)
# =============================================================================
set -euo pipefail

CMD="${1:-status}"
CLAIR_API="http://localhost:6060"

clair_ready() {
  curl -sf "${CLAIR_API}/openapi/v1" >/dev/null 2>&1
}

# ── Status ────────────────────────────────────────────────────────────────────
if [ "$CMD" = "status" ]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║   Clair Stack Status                                  ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo ""
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" \
    | grep -E "NAME|clair|registry" || true
  echo ""
  if clair_ready; then
    VULN=$(docker exec clair-db psql -U clair -d clair -tAc "SELECT COUNT(*) FROM vuln;" 2>/dev/null | tr -d ' ')
    echo "  API          : ${CLAIR_API} ✓"
    echo "  Vuln records : ${VULN}"
    DUMP=""
    [ -f "$(dirname "$0")/vuln-mirror.dump" ] && \
      DUMP=$(ls -lh "$(dirname "$0")/vuln-mirror.dump" | awk '{print $5 " (modified " $6 " " $7 ")"}')
    [ -n "$DUMP" ] && echo "  Dump file    : vuln-mirror.dump  $DUMP"
  else
    echo "  API          : not responding"
  fi
  echo ""
  exit 0
fi

# ── Start ─────────────────────────────────────────────────────────────────────
if [ "$CMD" = "start" ]; then
  echo ""
  echo "Starting Clair stack (registry + clair-db + clair-server)..."
  docker compose up -d clair-server registry 2>&1 | grep -E "Start|Create|Running|✔|✗" | sed 's/^/  /'

  echo -n "  Waiting for Clair API"
  i=0
  until clair_ready; do
    sleep 3; printf "."; i=$((i+1))
    [ $i -gt 60 ] && echo " TIMEOUT" && exit 1
  done
  echo " ✓"

  VULN=$(docker exec clair-db psql -U clair -d clair -tAc "SELECT COUNT(*) FROM vuln;" 2>/dev/null | tr -d ' ')
  echo "  Vuln records : ${VULN}"
  echo "  API          : ${CLAIR_API}"
  exit 0
fi

# ── Restart ───────────────────────────────────────────────────────────────────
if [ "$CMD" = "restart" ]; then
  echo ""
  echo "Restarting clair-server..."
  docker compose restart clair-server 2>&1 | sed 's/^/  /'

  echo -n "  Waiting for Clair API"
  i=0
  until clair_ready; do
    sleep 3; printf "."; i=$((i+1))
    [ $i -gt 60 ] && echo " TIMEOUT" && exit 1
  done
  echo " ✓"

  VULN=$(docker exec clair-db psql -U clair -d clair -tAc "SELECT COUNT(*) FROM vuln;" 2>/dev/null | tr -d ' ')
  echo "  Vuln records : ${VULN}"
  exit 0
fi

# ── Down ──────────────────────────────────────────────────────────────────────
if [ "$CMD" = "down" ]; then
  echo ""
  echo "Stopping all Clair containers and removing volumes..."
  docker compose --profile updater down -v 2>&1 | grep -v "^$"
  echo "✓ Done"
  exit 0
fi

echo "Usage: ./switch.sh [status|start|restart|down]"
exit 1
