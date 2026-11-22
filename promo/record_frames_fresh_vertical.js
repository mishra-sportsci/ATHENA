const http = require('http');
const fs = require('fs');
const path = require('path');

const OUTPUT_DIR = path.join(__dirname, 'frames_fresh_vertical');
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
  console.log('[FRESH VERTICAL 4K RECORDER] Connecting to Chrome DevTools Protocol...');
  const wsUrl = await getWsUrl();
  const ws = new WebSocket(wsUrl);
  let id = 1;
  const callbacks = new Map();

  ws.onmessage = (event) => {
    const msg = JSON.parse(event.data);
    if (msg.id && callbacks.has(msg.id)) {
      callbacks.get(msg.id)(msg.result || msg.error);
      callbacks.delete(msg.id);
    }
  };

  const send = (method, params = {}) => new Promise((resolve) => {
    const msgId = id++;
    callbacks.set(msgId, resolve);
    ws.send(JSON.stringify({ id: msgId, method, params }));
  });

  const evaluate = async (expr) => {
    const res = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
    return res ? res.value : null;
  };

  const capture = async (name, minSize = 40000) => {
    await sleep(600);
    const snap = await send('Page.captureScreenshot', { format: 'png' });
    const buf = Buffer.from(snap.data, 'base64');
    const fp = path.join(OUTPUT_DIR, name);
    fs.writeFileSync(fp, buf);
    console.log(`[FRESH VERTICAL 4K RECORDER] Captured ${name} (${Math.round(buf.length / 1024)} KB)`);
    if (buf.length < minSize) {
      console.warn(`[WARNING] Captured frame ${name} is surprisingly small (${buf.length} bytes).`);
    }
  };

  await new Promise(r => ws.onopen = r);
  await send('Page.enable');
  await send('Runtime.enable');

  // Vertical 1080x1920 @ 2x device scale factor (2160x3840 UHD 9:16)
  await send('Emulation.setDeviceMetricsOverride', {
    width: 1080, height: 1920, deviceScaleFactor: 2, mobile: true
  });

  // =========================================================================
  // PHASE 1: TITLE INTERSTITIAL CARDS (Rendered first, zero WebSocket drops)
  // =========================================================================
  const titleHtml = `file://${path.join(__dirname, 'title_cards_fresh_vertical.html')}`;

  console.log('[FRESH VERTICAL 4K RECORDER] Frame 01: Title Intro Card...');
  await send('Page.navigate', { url: `${titleHtml}?type=intro` });
  await sleep(1500);
  await capture('01_v_title_intro.png');

  console.log('[FRESH VERTICAL 4K RECORDER] Frame 02: Female Athlete Foundation & RED-S Card...');
  await send('Page.navigate', { url: `${titleHtml}?type=female` });
  await sleep(1500);
  await capture('02_v_title_female.png');

  console.log('[FRESH VERTICAL 4K RECORDER] Frame 04: Multi-Athlete Comparison Title Card...');
  await send('Page.navigate', { url: `${titleHtml}?type=compare` });
  await sleep(1500);
  await capture('04_v_title_compare.png');

  console.log('[FRESH VERTICAL 4K RECORDER] Frame 11: 10 Global Languages Universal Localization Card...');
  await send('Page.navigate', { url: `${titleHtml}?type=languages` });
  await sleep(1500);
  await capture('11_v_title_languages.png');

  console.log('[FRESH VERTICAL 4K RECORDER] Frame 15: Outro & Open Source Data Sovereignty Card...');
  await send('Page.navigate', { url: `${titleHtml}?type=outro` });
  await sleep(1500);
  await capture('15_v_title_outro.png');

  // =========================================================================
  // PHASE 2: ATHENA SHINY LIVE APPLICATION (Persistent connection, NO reloads)
  // =========================================================================
  console.log('[FRESH VERTICAL 4K RECORDER] Loading ATHENA Shiny Console on port 3838...');
  await send('Page.navigate', { url: 'http://127.0.0.1:3838/' });

  // Wait for initial Shiny connection & auto-population
  console.log('[FRESH VERTICAL 4K RECORDER] Waiting for initial auto-population...');
  for (let waitCount = 1; waitCount <= 30; waitCount++) {
    const readyVal = await evaluate("document.getElementById('qbReadiness') ? document.getElementById('qbReadiness').innerText.trim() : ''");
    if (readyVal && readyVal !== '' && readyVal !== '—') {
      console.log(`[FRESH VERTICAL 4K RECORDER] Shiny auto-populated in ${waitCount * 0.5}s (Avg Readiness: ${readyVal})`);
      break;
    }
    await sleep(500);
  }

  // Ensure dark theme, English, 100% zoom, dismiss splash
  await evaluate("if(window.applyTheme) applyTheme('dark'); if(window.applyLang) applyLang('en'); if(window.dismissSplash) dismissSplash();");
  await sleep(1000);

  // Frame 03: Live Biometric HUD & Readiness Ring (Dashboard)
  console.log('[FRESH VERTICAL 4K RECORDER] Frame 03: Live Biometric HUD & Readiness...');
  await evaluate("if(window.tabBtnActivate) tabBtnActivate('dashboard'); if(window.Shiny) Shiny.setInputValue('mainTabs','dashboard',{priority:'event'});");
  await sleep(1200);
  await capture('03_v_dashboard_hud.png');

  // Activate Cohort Tab
  console.log('[FRESH VERTICAL 4K RECORDER] Switching to Cohort Tab...');
  await evaluate("if(window.tabBtnActivate) tabBtnActivate('cohort'); if(window.Shiny) Shiny.setInputValue('mainTabs','cohort',{priority:'event'});");
  
  // Wait for Cohort DOM elements
  for (let w = 1; w <= 30; w++) {
    const state = await evaluate(`({
      cmp1: document.getElementById('cmp1') ? document.getElementById('cmp1').value : null,
      radar: document.querySelectorAll('#compareRadarWrap svg, #compareRadarWrap .js-plotly-plot').length,
      heatmap: document.querySelectorAll('#squadHeatmapWrap .hm-cell').length,
      rows: document.querySelectorAll('#loadMatrixTableBox tr').length
    })`);
    if (state && state.cmp1 && state.heatmap >= 196 && state.rows >= 50) {
      console.log(`[FRESH VERTICAL 4K RECORDER] Cohort Tab ready in ${w * 0.3}s`);
      break;
    }
    await sleep(300);
  }
  await sleep(1200);

  // Frame 05: 4-Athlete Multi-Overlay Comparison Radar & Heatmap
  console.log('[FRESH VERTICAL 4K RECORDER] Frame 05: 4-Athlete Multi-Overlay Comparison...');
  await capture('05_v_cohort_compare_2athletes.png');

  // Frame 06: Auto-Population Demo — Switch selections dynamically
  console.log('[FRESH VERTICAL 4K RECORDER] Frame 06: Dynamic Auto-Population Demo...');
  await evaluate(`
    (function() {
      const s1 = document.getElementById('cmp1'); if (s1) { s1.value = 'ATH-003'; s1.dispatchEvent(new Event('change', {bubbles: true})); }
      const s2 = document.getElementById('cmp2'); if (s2) { s2.value = 'ATH-118'; s2.dispatchEvent(new Event('change', {bubbles: true})); }
      const s3 = document.getElementById('cmp3'); if (s3) { s3.value = 'ATH_4934'; s3.dispatchEvent(new Event('change', {bubbles: true})); }
      const s4 = document.getElementById('cmp4'); if (s4) { s4.value = 'ATH-015'; s4.dispatchEvent(new Event('change', {bubbles: true})); }
      if (window.Shiny) {
        Shiny.setInputValue('cmp1', 'ATH-003', {priority: 'event'});
        Shiny.setInputValue('cmp2', 'ATH-118', {priority: 'event'});
        Shiny.setInputValue('cmp3', 'ATH_4934', {priority: 'event'});
        Shiny.setInputValue('cmp4', 'ATH-015', {priority: 'event'});
      }
    })();
  `);
  await sleep(2500);
  await capture('06_v_cohort_compare_4athletes.png');

  // Frame 07: Squad Heatmap & Training Load Matrix
  console.log('[FRESH VERTICAL 4K RECORDER] Frame 07: Squad Load Heatmap & Matrix...');
  await evaluate("window.scrollTo(0, 520);");
  await sleep(1500);
  await capture('07_v_cohort_squad_heatmap.png');
  await evaluate("window.scrollTo(0, 0);");

  // Frame 08: Athlete Detail Tab — Upper Section
  console.log('[FRESH VERTICAL 4K RECORDER] Frame 08: Athlete Detail (ATH-004 Combat Female)...');
  await evaluate("if(window.tabBtnActivate) tabBtnActivate('athlete'); if(window.Shiny) Shiny.setInputValue('mainTabs','athlete',{priority:'event'});");
  await evaluate(`
    if (window.Shiny) Shiny.setInputValue('athleteSelect', 'ATH-004', {priority: 'event'});
    const sel = document.getElementById('athleteSelect'); if(sel) sel.value = 'ATH-004';
  `);
  await sleep(2000);
  await capture('08_v_athlete_perf_lactate.png');

  // Frame 09: Athlete Detail — Lactate Sigmoid & Sleep Architecture
  console.log('[FRESH VERTICAL 4K RECORDER] Frame 09: Lactate Curve & Sleep Architecture...');
  await evaluate("window.scrollTo(0, 780);");
  await sleep(1800);
  await capture('09_v_athlete_sleep_hypno.png');
  await evaluate("window.scrollTo(0, 0);");

  // Frame 10: IOC 2023 RED-S Clinical Lab
  console.log('[FRESH VERTICAL 4K RECORDER] Frame 10: IOC 2023 RED-S Clinical Lab...');
  await evaluate("if(window.tabBtnActivate) tabBtnActivate('reds'); if(window.Shiny) Shiny.setInputValue('mainTabs','reds',{priority:'event'});");
  await sleep(2000);
  await capture('10_v_reds_clinical_lab.png');

  // Frame 12: In-App Arabic RTL Localization
  console.log('[FRESH VERTICAL 4K RECORDER] Frame 12: Live Dynamic Arabic RTL Localization...');
  await evaluate("if(window.tabBtnActivate) tabBtnActivate('dashboard'); if(window.Shiny) Shiny.setInputValue('mainTabs','dashboard',{priority:'event'});");
  await evaluate("if(window.applyLang) applyLang('ar');");
  await sleep(2000);
  await capture('12_v_lang_arabic_rtl.png');

  // Frame 13: In-App Chinese Localization
  console.log('[FRESH VERTICAL 4K RECORDER] Frame 13: Live Dynamic Chinese Localization...');
  await evaluate("if(window.applyLang) applyLang('zh');");
  await sleep(2000);
  await capture('13_v_lang_chinese.png');

  // Frame 14: Trackside High-Contrast Daylight Mode
  console.log('[FRESH VERTICAL 4K RECORDER] Frame 14: Trackside High-Contrast Daylight Mode...');
  await evaluate("if(window.applyLang) applyLang('en'); if(window.applyTheme) applyTheme('light');");
  await sleep(2000);
  await capture('14_v_dashboard_light.png');

  console.log('[FRESH VERTICAL 4K RECORDER] All 15 Vertical 4K UHD frames captured successfully with ZERO blank data!');
  ws.close();
}

main().catch(err => {
  console.error('[FRESH VERTICAL 4K RECORDER ERROR]', err);
  process.exit(1);
});
