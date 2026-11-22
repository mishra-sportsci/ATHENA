#!/usr/bin/env bash
# ==============================================================================
# ATHENA R Shiny - Elite Sports Science & Clinical Telemetry Console Launcher
# Optimized for Debian 13 (Trixie) KDE Plasma
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHINY_DIR="$SCRIPT_DIR/athena_shiny"
DB_PATH="$SCRIPT_DIR/athena.db"
PORT="${ATHENA_SHINY_PORT:-3838}"
HOST="127.0.0.1"

echo "======================================================================"
echo "          A.T.H.E.N.A. — Elite R Shiny Analytics Console"
echo "  Adaptive Telemetry, Health & Evidence-Based Nutrition Analytics"
echo "======================================================================"

# If already responding on port, simply open the browser console tab
if curl -s -f -m 1 "http://${HOST}:${PORT}/" >/dev/null 2>&1; then
    echo "[ATHENA R Shiny] Active instance detected on port ${PORT}. Opening console..."
    xdg-open "http://${HOST}:${PORT}/" &
    exit 0
fi

# Verify R is available
if ! command -v Rscript >/dev/null 2>&1; then
    echo "ERROR: Rscript is not installed or not in PATH."
    exit 1
fi

R_VERSION=$(Rscript -e 'cat(R.version.string)')
echo "[INFO] Using: $R_VERSION"
echo "[INFO] App directory: $SHINY_DIR"

# Set environment
export ATHENA_DB_PATH="$DB_PATH"
export ATHENA_SHINY_PORT="$PORT"
export ATHENA_API_URL="${ATHENA_API_URL:-http://127.0.0.1:8000}"

# Graceful cleanup trap
cleanup() {
    echo ""
    echo "[ATHENA SHINY] Shutting down console gracefully..."
    fuser -k "${PORT}/tcp" 2>/dev/null || true
    echo "[ATHENA SHINY] Console closed. Zero background resources consumed."
}
trap cleanup EXIT INT TERM

# Clear stale/hung process on port 3838
if command -v fuser >/dev/null 2>&1; then
    if fuser "${PORT}/tcp" >/dev/null 2>&1; then
        echo "[WARN] Port $PORT was in use. Clearing previous instance..."
        fuser -k "${PORT}/tcp" 2>/dev/null || true
        sleep 0.5
    fi
fi

cd "$SCRIPT_DIR"

echo "[INFO] Launching ATHENA R Shiny at http://${HOST}:${PORT}/"
exec Rscript -e "shiny::runApp('${SHINY_DIR}', port=${PORT}, host='${HOST}', launch.browser=TRUE)"
