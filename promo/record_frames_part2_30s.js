const http = require('http');
const fs = require('fs');
const path = require('path');

const OUTPUT_DIR = path.join(__dirname, 'frames_part2_30s');
if (!fs.existsSync(OUTPUT_DIR)) fs.mkdirSync(OUTPUT_DIR, { recursive: true });

async function getWsUrl() {
  return new Promise((resolve, reject) => {
    http.get('http://127.0.0.1:9222/json/list', (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          const json = JSON.parse(data);
          resolve(json[0].webSocketDebuggerUrl);
        } catch (e) {
          reject(e);
        }
      });
    }).on('error', reject);
  });
}

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function main() {
  console.log('[PART 2 30S 4K RECORDER] Connecting to Chrome DevTools Protocol...');
  const wsUrl = await getWsUrl();
  const ws = new WebSocket(wsUrl);
  let id = 1;
  const callbacks = new Map();

  ws.onmessage = (event) => {
    const msg = JSON.parse(event.data);
    if (msg.id && callbacks.has(msg.id)) {
      callbacks.get(msg.id)(msg.result);
      callbacks.delete(msg.id);
    }
  };

  const send = (method, params = {}) => new Promise((resolve) => {
    const msgId = id++;
    callbacks.set(msgId, resolve);
    ws.send(JSON.stringify({ id: msgId, method, params }));
  });

  const evaluate = async (expr) => {
    return send('Runtime.evaluate', { expression: expr, awaitPromise: true });
  };

  const capture = async (name) => {
    await sleep(700);
    const snap = await send('Page.captureScreenshot', { format: 'png' });
    const buf = Buffer.from(snap.data, 'base64');
    const fp = path.join(OUTPUT_DIR, name);
    fs.writeFileSync(fp, buf);
    console.log(`[PART 2 30S 4K RECORDER] Captured ${name} (${Math.round(buf.length / 1024)} KB)`);
  };

  ws.onopen = async () => {
    await send('Page.enable');
    await send('Runtime.enable');
    
    // 3840 x 2160 true 4K via 1920x1080 @ 2x device scale factor
    await send('Emulation.setDeviceMetricsOverride', {
      width: 1920, height: 1080, deviceScaleFactor: 2, mobile: false
    });

    console.log('[PART 2 30S 4K RECORDER] Frame 01: Title Intro Card...');
    await send('Page.navigate', { url: `file://${path.join(__dirname, 'title_cards_part2.html')}?type=intro` });
    await sleep(1500);
    await capture('01_title_intro.png');

    console.log('[PART 2 30S 4K RECORDER] Loading ATHENA Console on port 3838...');
    await send('Page.navigate', { url: 'http://127.0.0.1:3838/' });
    
    // Wait for console to auto-populate
    for (let waitCount = 0; waitCount < 25; waitCount++) {
      const check = await evaluate("document.getElementById('hudReady')?.innerText || ''");
      if (check.result && check.result.value && check.result.value !== '' && check.result.value !== '—') {
        console.log(`[PART 2 30S 4K RECORDER] Console fully populated in ${waitCount}s`);
        break;
      }
      await sleep(1000);
    }
    await sleep(3000);

    // Initial state: Dark theme, English
    await evaluate("applyTheme('dark'); applyLang('en'); applyZoom(1.0);");
    await sleep(1500);

    // Frame 02: Clinical Decision Support (CDSS) Engine & Multi-Joint Injury Risk Matrix
    console.log('[PART 2 30S 4K RECORDER] Frame 02: Clinical Decision Support (CDSS) & Injury Risk Matrix...');
    await evaluate("tabBtnActivate('dashboard'); if(window.Shiny) Shiny.setInputValue('mainTabs','dashboard',{priority:'event'});");
    await sleep(1500);
    await evaluate("window.scrollTo(0, 360);");
    await sleep(2000);
    await capture('02_ai_recs_injury_risk.png');

    // Frame 03: Live Session Telemetry & Workout HUD
    console.log('[PART 2 30S 4K RECORDER] Frame 03: Live Session Telemetry & Workout HUD...');
    await evaluate("const el = document.getElementById('pcSession'); if (el) el.scrollIntoView({behavior:'instant', block:'center'}); else window.scrollTo(0, 820);");
    await sleep(2000);
    await capture('03_session_hud_telemetry.png');
    await evaluate("window.scrollTo(0, 0);");

    // Frame 04: Workload Intelligence — Gabbett ACWR & Foster Monotony Breakdown
    console.log('[PART 2 30S 4K RECORDER] Frame 04: Gabbett ACWR Sweet Spot & Foster Monotony...');
    await evaluate("tabBtnActivate('athlete'); if(window.Shiny) Shiny.setInputValue('mainTabs','athlete',{priority:'event'});");
    await sleep(3500);
    await evaluate("const el = document.getElementById('pcAcwr'); if (el) el.scrollIntoView({behavior:'instant', block:'center'}); else window.scrollTo(0, 380);");
    await sleep(2000);
    await capture('04_athlete_acwr_monotony.png');

    // Frame 05: Precision Nutrition Periodization & Fueling Breakdown
    console.log('[PART 2 30S 4K RECORDER] Frame 05: Nutrition Periodization & Hydration...');
    await evaluate("const el = document.getElementById('pcNutrition'); if (el) el.scrollIntoView({behavior:'instant', block:'center'}); else window.scrollTo(0, 950);");
    await sleep(2000);
    await capture('05_athlete_nutrition_bone_acl.png');
    await evaluate("window.scrollTo(0, 0);");

    // Frame 06: Squad Roster Grid (Female & Male Elite Athletes)
    console.log('[PART 2 30S 4K RECORDER] Frame 06: Full Squad Roster Grid...');
    await evaluate("tabBtnActivate('roster'); if(window.Shiny) Shiny.setInputValue('mainTabs','roster',{priority:'event'});");
    await sleep(3000);
    await evaluate("window.scrollTo(0, 0);");
    await sleep(1500);
    await capture('06_squad_roster_profiles.png');

    // Frame 07: 4-Athlete Multi-Overlay Comparison Radar
    console.log('[PART 2 30S 4K RECORDER] Frame 07: 4-Athlete Multi-Overlay Comparison Radar...');
    await evaluate("tabBtnActivate('cohort'); if(window.Shiny) Shiny.setInputValue('mainTabs','cohort',{priority:'event'});");
    await sleep(2000);
    await evaluate(`
      const opts = Array.from(document.querySelectorAll("#cmp1 option")).map(o => o.value).filter(v => v);
      if (opts.length >= 4 && window.Shiny) {
        Shiny.setInputValue("cmp1", opts[0], {priority: "event"});
        Shiny.setInputValue("cmp2", opts[1], {priority: "event"});
        Shiny.setInputValue("cmp3", opts[2], {priority: "event"});
        Shiny.setInputValue("cmp4", opts[3], {priority: "event"});
      }
    `);
    await sleep(3500);
    await capture('07_compare_4athletes_radar.png');

    // Frame 08: Clinical Data Operations & Instant Research Exports
    console.log('[PART 2 30S 4K RECORDER] Frame 08: Clinical Data Ops & Research Exports...');
    await evaluate("tabBtnActivate('data'); if(window.Shiny) Shiny.setInputValue('mainTabs','data',{priority:'event'});");
    await sleep(3000);
    await evaluate("window.scrollTo(0, 0);");
    await sleep(1500);
    await capture('08_data_ops_export_suite.png');

    // Frame 09: System Diagnostics & Thermal Guard / ML Pipeline
    console.log('[PART 2 30S 4K RECORDER] Frame 09: System Diagnostics, Thermal Guard & ML Pipeline...');
    await evaluate("tabBtnActivate('system'); if(window.Shiny) Shiny.setInputValue('mainTabs','system',{priority:'event'});");
    await sleep(3000);
    await evaluate("window.scrollTo(0, 0);");
    await sleep(1500);
    await capture('09_system_thermal_guard_ml.png');

    // Frame 10: 10 Global Languages (Vibrant Colorful Separate Boxes)
    console.log('[PART 2 30S 4K RECORDER] Frame 10: 10 Global Languages Title Card...');
    await send('Page.navigate', { url: `file://${path.join(__dirname, 'title_cards_part2.html')}?type=languages` });
    await sleep(1500);
    await capture('10_title_languages.png');

    // Frame 11: In-App Localization Demonstration (Daylight Sunlight Mode)
    console.log('[PART 2 30S 4K RECORDER] Frame 11: In-App Spanish Live Localization in Daylight Mode...');
    await send('Page.navigate', { url: 'http://127.0.0.1:3838/' });
    await sleep(2500);
    await evaluate("applyLang('es'); applyTheme('light'); tabBtnActivate('dashboard'); if(window.Shiny) Shiny.setInputValue('mainTabs','dashboard',{priority:'event'});");
    await sleep(2000);
    await capture('11_inapp_localized_daylight.png');

    // Frame 12: Scientific Evidence-Based Outro Card
    console.log('[PART 2 30S 4K RECORDER] Frame 12: Scientific Evidence-Based Outro Card...');
    await send('Page.navigate', { url: `file://${path.join(__dirname, 'title_cards_part2.html')}?type=outro` });
    await sleep(1500);
    await capture('12_title_outro.png');

    console.log('[PART 2 30S 4K RECORDER] All 12 4K UHD frames captured successfully!');
    process.exit(0);
  };
}

main().catch(err => {
  console.error('[PART 2 30S 4K RECORDER ERROR]', err);
  process.exit(1);
});
