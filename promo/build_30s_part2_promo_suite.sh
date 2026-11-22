#!/usr/bin/env bash
# ==============================================================================
# A.T.H.E.N.A. — Edition 2 (Part 2): 30-Second Ultra HD 4K Social Showcase
# Focus: Missed Clinical & Telemetry Capabilities:
#        - Clinical Decision Support Recommendations Shield
#        - Dynamic Multi-Joint Injury Risk Matrix (Hamstring, ACL, Achilles, Cardiac)
#        - Live Session Telemetry & Workout Timer HUD
#        - Gabbett Acute:Chronic Workload Ratio (ACWR Sweet Spot) & Foster Monotony
#        - Precision Athlete Nutrition & Fueling Periodization
#        - Full Squad Roster Grid (Female & Male Elite Athletes)
#        - 4-Athlete Multi-Overlay Comparison Radar
#        - Clinical Data Operations & Instant Research Exports (CSV, JSON, PDF Report)
#        - System Diagnostics, Thermal Guard & ML Pipeline
#        - 10 Global Languages (10 Colorful Separate Badges)
#        - In-App Spanish Live Localization in Daylight Mode
#        - Scientific Evidence-Based · 100% Offline-First (Zero False Promises)
# ==============================================================================

set -euo pipefail

PROMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$PROMO_DIR/.." && pwd)"

OUT_LANDSCAPE_4K="$PROJECT_DIR/athena_promo_part2_4k_landscape_16x9.mp4"
OUT_VERTICAL_4K="$PROJECT_DIR/athena_promo_part2_4k_story_9x16.mp4"
OUT_SQUARE_4K="$PROJECT_DIR/athena_promo_part2_4k_square_1x1.mp4"
OUT_1080P_DEFAULT="$PROJECT_DIR/athena_promo_part2_1080p.mp4"

AUDIO_FILE="$PROMO_DIR/promo_soundtrack_30s.aac"

export ATHENA_DB_PATH="$PROJECT_DIR/athena.db"
export ATHENA_SHINY_PORT="3838"

echo "======================================================================"
echo "   A.T.H.E.N.A. — Edition 2 (Part 2) 30s 4K Video Production Suite"
echo "======================================================================"

# Step 1: Ensure Shiny app is running on port 3838
SHINY_STARTED_BY_US=0
if ! curl -s -I http://127.0.0.1:3838/ >/dev/null 2>&1; then
    echo "[INFO] Launching ATHENA Shiny Console on port 3838..."
    cd "$PROJECT_DIR"
    Rscript -e "shiny::runApp('$PROJECT_DIR/athena_shiny', port=3838, host='127.0.0.1', launch.browser=FALSE)" > /tmp/shiny_part2_30s.log 2>&1 &
    SHINY_PID=$!
    SHINY_STARTED_BY_US=1
    echo "[INFO] Waiting for Shiny console to respond on port 3838..."
    READY=0
    for i in {1..30}; do
        if curl -s -I http://127.0.0.1:3838/ 2>&1 | grep -q "200 OK"; then
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
cleanup() {
    echo "[INFO] Cleaning up background processes..."
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

# Step 2: Ensure audio track exists
if [ ! -f "$AUDIO_FILE" ]; then
    echo "[INFO] Generating 30s electronic pulse soundtrack..."
    ffmpeg -y -f lavfi -i "aevalsrc=sin(174*2*PI*t)*0.07+sin(261*2*PI*t)*0.05*cos(2*PI*t*1.2)+sin(523*2*PI*t)*0.025*cos(2*PI*t*2.4):s=48000:d=31" \
      -af "lowpass=f=1100,tremolo=f=3.5:d=0.45,afade=t=in:ss=0:d=1.5,afade=t=out:st=28:d=2,volume=0.9" \
      -c:a aac -b:a 192k \
      "$AUDIO_FILE"
fi

# Step 3: Record 4K Frames via Headless Chrome
echo "[INFO] Launching Chrome Headless for 4K UHD Capture..."
google-chrome --headless=new --no-sandbox --disable-gpu --remote-debugging-port=9222 "about:blank" >/dev/null 2>&1 &
CHROME_PID=$!
sleep 2

echo "[INFO] Capturing Part 2 30-Second 4K Landscape (3840x2160) frames..."
node --experimental-websocket "$PROMO_DIR/record_frames_part2_30s.js"

echo "[INFO] Capturing Part 2 30-Second 4K Vertical (2160x3840) frames..."
node --experimental-websocket "$PROMO_DIR/record_frames_vertical_part2_30s.js"

kill "$CHROME_PID" 2>/dev/null || true
wait "$CHROME_PID" 2>/dev/null || true
unset CHROME_PID

# Step 4: Encode 4K Landscape 16:9 MP4 (3840x2160, exactly 30s)
echo "[INFO] Encoding Master 4K Landscape (3840x2160) 30s MP4..."
cd "$PROMO_DIR"
ffmpeg -y -f concat -safe 0 -i concat_landscape_part2_30s.txt \
    -i "$AUDIO_FILE" \
    -vf "fps=30,format=yuv420p,scale=3840:2160" \
    -t 30.0 \
    -c:v libx264 -preset medium -crf 17 \
    -c:a aac -b:a 192k \
    -movflags +faststart \
    "$OUT_LANDSCAPE_4K"

echo "[INFO] Generating 1080p Landscape MP4..."
ffmpeg -y -i "$OUT_LANDSCAPE_4K" \
    -vf "scale=1920:1080" \
    -c:v libx264 -preset fast -crf 20 \
    -c:a copy \
    -movflags +faststart \
    "$OUT_1080P_DEFAULT"

# Step 5: Encode 4K Vertical 9:16 MP4 (2160x3840, exactly 30s)
echo "[INFO] Encoding Master 4K Story/Vertical (2160x3840) 30s MP4..."
ffmpeg -y -f concat -safe 0 -i concat_vertical_part2_30s.txt \
    -i "$AUDIO_FILE" \
    -vf "fps=30,format=yuv420p,scale=2160:3840" \
    -t 30.0 \
    -c:v libx264 -preset medium -crf 17 \
    -c:a aac -b:a 192k \
    -movflags +faststart \
    "$OUT_VERTICAL_4K"

# Step 6: Encode 4K Square 1:1 MP4 (2160x2160, exactly 30s)
echo "[INFO] Encoding Master 4K Square (2160x2160) 30s MP4..."
ffmpeg -y -i "$OUT_LANDSCAPE_4K" \
    -vf "crop=2160:2160:840:0" \
    -t 30.0 \
    -c:v libx264 -preset medium -crf 17 \
    -c:a copy \
    -movflags +faststart \
    "$OUT_SQUARE_4K"

# Step 7: Sync to GitHub repo mirror without modifying Edition 1
if [ -d "$PROJECT_DIR-github" ]; then
    echo "[INFO] Syncing Edition 2 promo suite to $PROJECT_DIR-github/..."
    cp "$OUT_LANDSCAPE_4K" "$PROJECT_DIR-github/"
    cp "$OUT_VERTICAL_4K" "$PROJECT_DIR-github/"
    cp "$OUT_SQUARE_4K" "$PROJECT_DIR-github/"
    cp "$OUT_1080P_DEFAULT" "$PROJECT_DIR-github/"
fi

echo "======================================================================"
echo "    Edition 2 (Part 2) 30-Second 4K Video Production Completed!"
echo "======================================================================"
echo "Outputs created:"
ls -lh "$OUT_LANDSCAPE_4K" "$OUT_VERTICAL_4K" "$OUT_SQUARE_4K" "$OUT_1080P_DEFAULT"
