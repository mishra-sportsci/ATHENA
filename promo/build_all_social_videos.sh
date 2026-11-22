#!/usr/bin/env bash
# ==============================================================================
# ATHENA — Multi-Format Social Media Video Builder
# 1. Landscape 16:9 (1920x1080) -> LinkedIn, YouTube, X/Twitter
# 2. Vertical 9:16 (1080x1920)  -> Instagram Story / Reels, WhatsApp Status, TikTok
# 3. Square 1:1 (1080x1080)     -> Instagram Feed, LinkedIn Mobile, Facebook
# ==============================================================================

set -euo pipefail

PROMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$PROMO_DIR/.." && pwd)"

OUT_LANDSCAPE="$PROJECT_DIR/athena_promo_landscape_16x9.mp4"
OUT_VERTICAL="$PROJECT_DIR/athena_promo_story_9x16.mp4"
OUT_SQUARE="$PROJECT_DIR/athena_promo_square_1x1.mp4"

AUDIO_FILE="$PROMO_DIR/promo_soundtrack.aac"

echo "======================================================================"
echo "    A.T.H.E.N.A. — Master Multi-Platform Promotional Video Suite"
echo "======================================================================"

# Step 1: Ensure Chrome is available
if ! command -v google-chrome >/dev/null 2>&1; then
    echo "ERROR: google-chrome is required."
    exit 1
fi

# Step 2: Ensure Shiny app is running on port 3838
SHINY_STARTED_BY_US=0
if ! curl -s -I http://127.0.0.1:3838/ >/dev/null 2>&1; then
    echo "[INFO] Launching ATHENA Shiny Console on port 3838..."
    Rscript -e "shiny::runApp('$PROJECT_DIR/athena_shiny', port=3838, host='127.0.0.1', launch.browser=FALSE)" > /tmp/shiny_promo.log 2>&1 &
    SHINY_PID=$!
    SHINY_STARTED_BY_US=1
    echo "[INFO] Waiting for Shiny console to respond on port 3838..."
    READY=0
    for i in {1..20}; do
        if curl -s -I http://127.0.0.1:3838/ 2>&1 | grep -q "200 OK"; then
            READY=1
            echo "[INFO] Shiny Console is ready (HTTP 200 OK) in ${i}s!"
            break
        fi
        sleep 1
    done
    if [ "$READY" -ne 1 ]; then
        echo "ERROR: Shiny failed to respond on port 3838. Log:"
        cat /tmp/shiny_promo.log
        exit 1
    fi
else
    echo "[INFO] ATHENA Shiny Console already active on port 3838."
fi

# Cleanup trap
cleanup() {
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

# Step 3: Synthesize high-tech ambient electronic soundtrack (no copyright strikes)
echo "[INFO] Generating 60s ambient high-tech electronic pulse soundtrack..."
ffmpeg -y -f lavfi -i "aevalsrc=sin(174*2*PI*t)*0.07+sin(261*2*PI*t)*0.05*cos(2*PI*t*1.2)+sin(523*2*PI*t)*0.025*cos(2*PI*t*2.4):s=48000:d=60" \
  -af "lowpass=f=1100,tremolo=f=3.5:d=0.45,afade=t=in:ss=0:d=2,afade=t=out:st=57:d=3,volume=0.9" \
  -c:a aac -b:a 128k \
  "$AUDIO_FILE"

# Step 4: Record Landscape Frames (1920x1080)
echo "[INFO] Launching Chrome Headless for Landscape 16:9 capture..."
google-chrome --headless=new --no-sandbox --disable-gpu --remote-debugging-port=9222 "about:blank" >/dev/null 2>&1 &
CHROME_PID=$!
sleep 2

echo "[INFO] Capturing 16:9 Landscape frames..."
node --experimental-websocket "$PROMO_DIR/record_frames.js"

echo "[INFO] Capturing 9:16 Vertical frames..."
node --experimental-websocket "$PROMO_DIR/record_frames_vertical.js"

kill "$CHROME_PID" 2>/dev/null || true
wait "$CHROME_PID" 2>/dev/null || true
unset CHROME_PID

# Step 5: Encode Landscape 16:9 MP4 (46s)
echo "[INFO] Encoding Landscape Master 16:9 MP4 (1920x1080)..."
cat << 'CONCAT_LAND' > "$PROMO_DIR/concat_landscape.txt"
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
CONCAT_LAND

cd "$PROMO_DIR"
ffmpeg -y -f concat -safe 0 -i concat_landscape.txt \
    -i "$AUDIO_FILE" \
    -vf "fps=30,format=yuv420p,scale=1920:1080" \
    -c:v libx264 -preset slow -crf 18 \
    -c:a aac -b:a 128k -shortest \
    -movflags +faststart \
    "$OUT_LANDSCAPE"

# Also update the original athena_promo_1080p.mp4 with audio
cp "$OUT_LANDSCAPE" "$PROJECT_DIR/athena_promo_1080p.mp4"

# Step 6: Encode Vertical 9:16 MP4 (Instagram Story / WhatsApp Status)
echo "[INFO] Encoding Vertical 9:16 MP4 (1080x1920) for Stories & Status..."
cat << 'CONCAT_VERT' > "$PROMO_DIR/concat_vertical.txt"
file 'frames_vertical/01_v_intro.png'
duration 3.0
file 'frames_vertical/02_v_dashboard_dark.png'
duration 2.5
file 'frames_vertical/03_v_dashboard_light.png'
duration 2.5
file 'frames_vertical/04_v_zoom.png'
duration 2.0
file 'frames_vertical/05_v_spanish.png'
duration 2.0
file 'frames_vertical/06_v_french.png'
duration 1.8
file 'frames_vertical/07_v_hindi.png'
duration 1.8
file 'frames_vertical/08_v_chinese.png'
duration 1.8
file 'frames_vertical/09_v_roster.png'
duration 2.5
file 'frames_vertical/10_v_athlete_radar.png'
duration 2.8
file 'frames_vertical/11_v_reds.png'
duration 2.8
file 'frames_vertical/12_v_outro.png'
duration 3.5
file 'frames_vertical/12_v_outro.png'
CONCAT_VERT

ffmpeg -y -f concat -safe 0 -i concat_vertical.txt \
    -i "$AUDIO_FILE" \
    -vf "fps=30,format=yuv420p,scale=1080:1920" \
    -c:v libx264 -preset slow -crf 18 \
    -c:a aac -b:a 128k -shortest \
    -movflags +faststart \
    "$OUT_VERTICAL"

# Step 7: Encode Square 1:1 MP4 (Instagram Feed, LinkedIn Mobile, Facebook)
echo "[INFO] Encoding Square 1:1 MP4 (1080x1080) for In-Feed Posting..."
ffmpeg -y -f concat -safe 0 -i concat_landscape.txt \
    -i "$AUDIO_FILE" \
    -vf "fps=30,format=yuv420p,scale=1920:1080,crop=1080:1080:420:0" \
    -c:v libx264 -preset slow -crf 18 \
    -c:a aac -b:a 128k -shortest \
    -movflags +faststart \
    "$OUT_SQUARE"

echo "======================================================================"
echo "[SUCCESS] ALL 3 Master Social Media Videos Generated Successfully!"
echo "1. Landscape (16:9 - 1920x1080) -> $OUT_LANDSCAPE"
echo "2. Vertical Story (9:16 - 1080x1920) -> $OUT_VERTICAL"
echo "3. Square Feed (1:1 - 1080x1080)   -> $OUT_SQUARE"
echo "======================================================================"
ls -lh "$OUT_LANDSCAPE" "$OUT_VERTICAL" "$OUT_SQUARE"
