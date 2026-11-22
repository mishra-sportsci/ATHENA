#!/usr/bin/env bash
# ==============================================================================
# ATHENA — Social Media Promotional Video Builder (1080p Full HD)
# Generates a broadcast-quality MP4 showcase of the ATHENA R Shiny console.
# ==============================================================================

set -euo pipefail

PROMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$PROMO_DIR/.." && pwd)"
FRAMES_DIR="$PROMO_DIR/frames"
OUTPUT_MP4="$PROJECT_DIR/athena_promo_1080p.mp4"
CONCAT_FILE="$PROMO_DIR/frames_concat.txt"

echo "======================================================================"
echo "      A.T.H.E.N.A. — High-Definition Promotional Video Generator"
echo "======================================================================"

# Step 1: Ensure Chrome is available
if ! command -v google-chrome >/dev/null 2>&1; then
    echo "ERROR: google-chrome is required."
    exit 1
fi

# Step 2: Ensure Shiny app is running on port 3838
SHINY_STARTED_BY_US=0
if ! curl -s -I http://127.0.0.1:3838/ >/dev/null 2>&1; then
    echo "[INFO] Starting ATHENA Shiny Console on port 3838..."
    Rscript -e "shiny::runApp('$PROJECT_DIR/athena_shiny', port=3838, host='127.0.0.1', launch.browser=FALSE)" >/dev/null 2>&1 &
    SHINY_PID=$!
    SHINY_STARTED_BY_US=1
    sleep 3
else
    echo "[INFO] ATHENA Shiny Console already active on port 3838."
fi

# Cleanup trap
cleanup() {
    echo "[INFO] Cleaning up Chrome processes..."
    if [ -n "${CHROME_PID:-}" ] && kill -0 "$CHROME_PID" 2>/dev/null; then
        kill "$CHROME_PID" 2>/dev/null || true
        wait "$CHROME_PID" 2>/dev/null || true
    fi
    if [ "$SHINY_STARTED_BY_US" -eq 1 ] && [ -n "${SHINY_PID:-}" ] && kill -0 "$SHINY_PID" 2>/dev/null; then
        echo "[INFO] Stopping temporary Shiny instance..."
        kill "$SHINY_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# Step 3: Launch Chrome headless with remote debugging
echo "[INFO] Launching Headless Chrome on CDP port 9222..."
google-chrome --headless=new --no-sandbox --disable-gpu --remote-debugging-port=9222 "about:blank" >/dev/null 2>&1 &
CHROME_PID=$!
sleep 2

# Step 4: Run Node CDP recorder to capture 1080p frames
echo "[INFO] Recording live interactive features from Shiny Console..."
node --experimental-websocket "$PROMO_DIR/record_frames.js"

# Step 5: Build ffmpeg concat file with precise pacing
echo "[INFO] Generating frame timing sequence..."
cat << 'CONCAT_EOF' > "$CONCAT_FILE"
file 'frames/01_title_intro.png'
duration 3.0
file 'frames/02_dashboard_dark.png'
duration 2.5
file 'frames/03_dashboard_light.png'
duration 2.5
file 'frames/04_zoom_in.png'
duration 2.0
file 'frames/05_lang_arabic.png'
duration 2.0
file 'frames/06_lang_french.png'
duration 1.8
file 'frames/07_lang_hindi.png'
duration 1.8
file 'frames/08_lang_chinese.png'
duration 1.8
file 'frames/09_lang_spanish.png'
duration 1.8
file 'frames/10_roster_cards.png'
duration 2.5
file 'frames/11_roster_filter_caution.png'
duration 2.0
file 'frames/12_roster_table.png'
duration 2.5
file 'frames/13_athlete_radar.png'
duration 2.5
file 'frames/14_athlete_bone_acl.png'
duration 2.5
file 'frames/15_athlete_nutrition.png'
duration 2.2
file 'frames/16_reds_lab.png'
duration 2.8
file 'frames/17_cohort_heatmap.png'
duration 2.8
file 'frames/18_title_outro.png'
duration 3.5
file 'frames/18_title_outro.png'
CONCAT_EOF

# Step 6: Encode into broadcast MP4 (H.264, 1920x1080, 30fps)
echo "[INFO] Encoding full HD MP4 with ffmpeg..."
cd "$PROMO_DIR"
ffmpeg -y -f concat -safe 0 -i "$CONCAT_FILE" \
    -vf "fps=30,format=yuv420p,scale=1920:1080" \
    -c:v libx264 -preset slow -crf 18 \
    -movflags +faststart \
    "$OUTPUT_MP4"

echo "======================================================================"
echo "[SUCCESS] Promotional video generated successfully!"
echo "File location: $OUTPUT_MP4"
ls -lh "$OUTPUT_MP4"
echo "======================================================================"
