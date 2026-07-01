#!/usr/bin/env bash
# =============================================================================
# scan.sh  –  Push a local Docker image to the local registry and scan with Clair v4
# Usage:  ./scan.sh [IMAGE] [OUTPUT_FORMAT]
#   IMAGE         default: prometheus-ubi10:latest
#   OUTPUT_FORMAT default: text   (text | json | xml)
# =============================================================================
set -euo pipefail

IMAGE="${1:-prometheus-ubi10:latest}"
FORMAT="${2:-text}"
CLAIR_API="http://localhost:6060"
REGISTRY="localhost:5000"
EXT="${FORMAT/text/txt}"   # normalise "text" → "txt"; json and xml stay as-is
REPORT_FILE="clair-report-$(echo "$IMAGE" | tr '/: ' '---').${EXT}"
REGISTRY_IMAGE="${REGISTRY}/${IMAGE}"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║         Clair v4 Image Scanner                       ║"
echo "╚══════════════════════════════════════════════════════╝"
echo " Image    : $IMAGE"
echo " Registry : $REGISTRY_IMAGE"
echo " Format   : $FORMAT"
echo " API      : $CLAIR_API"
echo ""

# ── 1. Check Clair API is reachable ─────────────────────────────────────────
echo "[1/4] Checking Clair API..."
if ! curl -sf "${CLAIR_API}/openapi/v1" > /dev/null 2>&1; then
  echo "  ⚠  Clair is not reachable at ${CLAIR_API}."
  echo "     Run:  docker compose up -d"
  echo "     Then wait for the first updater pass to finish (~5 min warm, ~40 min cold)."
  echo "     Check readiness with:  curl http://localhost:6060/openapi/v1"
  exit 1
fi
echo "  ✓  Clair API is up."

# ── 2. Check local Docker image exists ──────────────────────────────────────
echo "[2/4] Checking local Docker image..."
if ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
  echo "  ✗  Image '$IMAGE' not found locally. Build or pull it first."
  exit 1
fi
echo "  ✓  Image found locally."

# ── 3. Push image to local registry ─────────────────────────────────────────
echo "[3/4] Pushing image to local registry (${REGISTRY})..."
docker tag "$IMAGE" "$REGISTRY_IMAGE"
docker push "$REGISTRY_IMAGE" 2>&1 | tail -3
echo "  ✓  Image pushed."

# ── 4. Run the report ────────────────────────────────────────────────────────
echo "[4/4] Requesting vulnerability report from Clair..."
if [ "$FORMAT" = "json" ]; then
  # Pretty-print JSON so the saved file is human-readable
  clair report \
    --host "${CLAIR_API}" \
    --out  "${FORMAT}" \
    "${REGISTRY_IMAGE}" | python3 -m json.tool | tee "${REPORT_FILE}"
else
  clair report \
    --host "${CLAIR_API}" \
    --out  "${FORMAT}" \
    "${REGISTRY_IMAGE}" | tee "${REPORT_FILE}"
fi

echo ""
echo "══════════════════════════════════════════════════════"
echo "  Report saved to: ${REPORT_FILE}"
echo "══════════════════════════════════════════════════════"
