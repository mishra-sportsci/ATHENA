#!/usr/bin/env bash
# ==============================================================================
# A.T.H.E.N.A. — Fresh Ultra HD 4K Social Media Showcase Suite
# Highlights:
#   • Dynamic 4-Athlete Multi-Overlay Comparison Radar & Squad Heatmap
#   • Live Auto-Population Demonstration When Athlete Selections Change
#   • Evidence-Based Clinical Decision Support System (CDSS) — ZERO FALSE CLAIMS
#   • Menstrual Cycle Triphasic Periodization & IOC 2023 RED-S Energy Availability
#   • 10 Global Languages Universal Localization (Native RTL Arabic & Chinese)
#   • High-Contrast Trackside Daylight Mode vs Cybernetic Night Mode
#   • 100% Offline-First Architecture on Hardened SQLite
# ==============================================================================

set -euo pipefail

PROMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$PROMO_DIR/.." && pwd)"

OUT_LANDSCAPE_4K="$PROJECT_DIR/athena_promo_fresh_4k_landscape_16x9.mp4"
OUT_1080P="$PROJECT_DIR/athena_promo_fresh_1080p_landscape_16x9.mp4"
OUT_VERTICAL_4K="$PROJECT_DIR/athena_promo_fresh_4k_story_9x16.mp4"
OUT_SQUARE_4K="$PROJECT_DIR/athena_promo_fresh_4k_square_1x1.mp4"

AUDIO_FILE="$PROMO_DIR/promo_soundtrack_fresh_33s.aac"

export ATHENA_DB_PATH="$PROJECT_DIR/athena.db"
export ATHENA_SHINY_PORT="3838"

echo "======================================================================"
echo "   A.T.H.E.N.A. — Fresh 4K Multi-Platform Video Suite Production"
echo "======================================================================"

# Step 1: Ensure Shiny app is active on port 3838
SHINY_STARTED_BY_US=0
if ! curl -s -o /dev/null --max-time 2 http://127.0.0.1:3838/ >/dev/null 2>&1; then
    echo "[INFO] Launching ATHENA Shiny Console on port 3838..."
    cd "$PROJECT_DIR"
    Rscript -e "shiny::runApp('$PROJECT_DIR/athena_shiny', port=3838, host='127.0.0.1', launch.browser=FALSE)" > /tmp/shiny_fresh.log 2>&1 &
    SHINY_PID=$!
    SHINY_STARTED_BY_US=1
    echo "[INFO] Waiting for Shiny console to respond on port 3838..."
    READY=0
    for i in {1..25}; do
        if curl -s -o /dev/null -w "%{http_code}" --max-time 2 http://127.0.0.1:3838/ | grep -q "200"; then
            READY=1
            echo "[INFO] Shiny Console is ready (HTTP 200 OK) in ${i}s!"
            break
        fi
        sleep 1
    done
    if [ "$READY" -ne 1 ]; then
        echo "ERROR: Shiny failed to respond on port 3838."
        exit 1
    fi
else
    echo "[INFO] ATHENA Shiny Console already active on port 3838."
fi

# Cleanup trap
CHROME_TMP_DIR=""
cleanup() {
    if [ -n "${CHROME_PID:-}" ] && kill -0 "$CHROME_PID" 2>/dev/null; then
        kill "$CHROME_PID" 2>/dev/null || true
        wait "$CHROME_PID" 2>/dev/null || true
    fi
    if [ -n "${CHROME_TMP_DIR:-}" ] && [ -d "$CHROME_TMP_DIR" ]; then
        rm -rf "$CHROME_TMP_DIR" 2>/dev/null || true
    fi
    if [ "$SHINY_STARTED_BY_US" -eq 1 ] && [ -n "${SHINY_PID:-}" ] && kill -0 "$SHINY_PID" 2>/dev/null; then
        echo "[INFO] Stopping temporary Shiny instance..."
        kill "$SHINY_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# Step 2: Prepare 33s high-fidelity audio track with smooth fade
echo "[INFO] Preparing 33s high-fidelity electronic soundtrack..."
if [ -f "$PROMO_DIR/promo_soundtrack.aac" ]; then
    ffmpeg -y -ss 0 -t 33 -i "$PROMO_DIR/promo_soundtrack.aac" \
      -af "afade=t=in:ss=0:d=1.5,afade=t=out:st=30:d=3,volume=0.95" \
      -c:a aac -b:a 192k "$AUDIO_FILE"
else
    ffmpeg -y -f lavfi -i "aevalsrc=sin(174*2*PI*t)*0.07+sin(261*2*PI*t)*0.05*cos(2*PI*t*1.2)+sin(523*2*PI*t)*0.025*cos(2*PI*t*2.4):s=48000:d=34" \
      -af "lowpass=f=1200,tremolo=f=3.5:d=0.45,afade=t=in:ss=0:d=1.5,afade=t=out:st=30:d=3,volume=0.9" \
      -c:a aac -b:a 192k "$AUDIO_FILE"
fi

# Step 3: Record 4K Frames via Headless Chrome CDP
echo "[INFO] Capturing 4K Landscape (3840x2160) frames..."
fuser -k 9222/tcp 2>/dev/null || true
CHROME_TMP_DIR=$(mktemp -d /tmp/athena_chrome_XXXXXX)
google-chrome --headless=new --no-sandbox --disable-gpu --remote-debugging-port=9222 --user-data-dir="$CHROME_TMP_DIR" "about:blank" >/dev/null 2>&1 &
CHROME_PID=$!
sleep 2.5
node --experimental-websocket "$PROMO_DIR/record_frames_fresh.js"
kill "$CHROME_PID" 2>/dev/null || true
rm -rf "$CHROME_TMP_DIR" 2>/dev/null || true
sleep 1

echo "[INFO] Capturing 4K Vertical (2160x3840) frames..."
fuser -k 9222/tcp 2>/dev/null || true
CHROME_TMP_DIR=$(mktemp -d /tmp/athena_chrome_XXXXXX)
google-chrome --headless=new --no-sandbox --disable-gpu --remote-debugging-port=9222 --user-data-dir="$CHROME_TMP_DIR" "about:blank" >/dev/null 2>&1 &
CHROME_PID=$!
sleep 2.5
node --experimental-websocket "$PROMO_DIR/record_frames_fresh_vertical.js"
kill "$CHROME_PID" 2>/dev/null || true
rm -rf "$CHROME_TMP_DIR" 2>/dev/null || true
unset CHROME_PID

# Step 4: Build Concat Lists
echo "[INFO] Building Landscape Concat List..."
cat << 'CONCAT_LAND' > "$PROMO_DIR/concat_landscape_fresh.txt"
file 'frames_fresh/01_title_intro.png'
duration 2.2
file 'frames_fresh/02_title_female.png'
duration 2.0
file 'frames_fresh/03_dashboard_hud.png'
duration 2.4
file 'frames_fresh/04_title_compare.png'
duration 1.8
file 'frames_fresh/05_cohort_compare_2athletes.png'
duration 2.2
file 'frames_fresh/06_cohort_compare_4athletes.png'
duration 2.8
file 'frames_fresh/07_cohort_squad_heatmap.png'
duration 2.2
file 'frames_fresh/08_athlete_perf_lactate.png'
duration 2.2
file 'frames_fresh/09_athlete_sleep_hypno.png'
duration 2.0
file 'frames_fresh/10_reds_clinical_lab.png'
duration 2.2
file 'frames_fresh/11_title_languages.png'
duration 1.8
file 'frames_fresh/12_lang_arabic_rtl.png'
duration 2.2
file 'frames_fresh/13_lang_chinese.png'
duration 2.2
file 'frames_fresh/14_dashboard_light.png'
duration 2.0
file 'frames_fresh/15_title_outro.png'
duration 2.8
file 'frames_fresh/15_title_outro.png'
CONCAT_LAND

echo "[INFO] Building Vertical Concat List..."
cat << 'CONCAT_VERT' > "$PROMO_DIR/concat_vertical_fresh.txt"
file 'frames_fresh_vertical/01_v_title_intro.png'
duration 2.2
file 'frames_fresh_vertical/02_v_title_female.png'
duration 2.0
file 'frames_fresh_vertical/03_v_dashboard_hud.png'
duration 2.4
file 'frames_fresh_vertical/04_v_title_compare.png'
duration 1.8
file 'frames_fresh_vertical/05_v_cohort_compare_2athletes.png'
duration 2.2
file 'frames_fresh_vertical/06_v_cohort_compare_4athletes.png'
duration 2.8
file 'frames_fresh_vertical/07_v_cohort_squad_heatmap.png'
duration 2.2
file 'frames_fresh_vertical/08_v_athlete_perf_lactate.png'
duration 2.2
file 'frames_fresh_vertical/09_v_athlete_sleep_hypno.png'
duration 2.0
file 'frames_fresh_vertical/10_v_reds_clinical_lab.png'
duration 2.2
file 'frames_fresh_vertical/11_v_title_languages.png'
duration 1.8
file 'frames_fresh_vertical/12_v_lang_arabic_rtl.png'
duration 2.2
file 'frames_fresh_vertical/13_v_lang_chinese.png'
duration 2.2
file 'frames_fresh_vertical/14_v_dashboard_light.png'
duration 2.0
file 'frames_fresh_vertical/15_v_title_outro.png'
duration 2.8
file 'frames_fresh_vertical/15_v_title_outro.png'
CONCAT_VERT

# Step 5: Encode Videos
echo "[INFO] Encoding 4K Landscape 16:9 (3840x2160)..."
ffmpeg -y -f concat -safe 0 -i "$PROMO_DIR/concat_landscape_fresh.txt" -i "$AUDIO_FILE" \
  -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p -r 30 \
  -c:a aac -b:a 192k -shortest "$OUT_LANDSCAPE_4K"

echo "[INFO] Encoding 1080p Full HD Landscape (1920x1080)..."
ffmpeg -y -i "$OUT_LANDSCAPE_4K" -vf "scale=1920:1080:flags=lanczos" \
  -c:v libx264 -preset fast -crf 20 -pix_fmt yuv420p -r 30 \
  -c:a copy "$OUT_1080P"

echo "[INFO] Encoding 4K Vertical 9:16 Story/Reels (2160x3840)..."
ffmpeg -y -f concat -safe 0 -i "$PROMO_DIR/concat_vertical_fresh.txt" -i "$AUDIO_FILE" \
  -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p -r 30 \
  -c:a aac -b:a 192k -shortest "$OUT_VERTICAL_4K"

echo "[INFO] Encoding 4K Square 1:1 Feed/Post (2160x2160)..."
ffmpeg -y -i "$OUT_LANDSCAPE_4K" -vf "crop=2160:2160:840:0" \
  -c:v libx264 -preset fast -crf 19 -pix_fmt yuv420p -r 30 \
  -c:a copy "$OUT_SQUARE_4K"

echo "======================================================================"
echo "    PROMOTIONAL VIDEO SUITE PRODUCTION COMPLETE!"
echo "======================================================================"
ls -lh "$OUT_LANDSCAPE_4K" "$OUT_1080P" "$OUT_VERTICAL_4K" "$OUT_SQUARE_4K"
