const http = require('http');
const fs = require('fs');
const path = require('path');

const OUTPUT_DIR = path.join(__dirname, 'frames');
if (!fs.existsSync(OUTPUT_DIR)) fs.mkdirSync(OUTPUT_DIR, { recursive: true });

async function getWsUrl() {
  return new Promise((resolve, reject) => {
    http.get('http://127.0.0.1:9222/json/list', (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        const json = JSON.parse(data);
        const page = json.find(t => t.type === 'page') || json[0];
        resolve(page.webSocketDebuggerUrl);
      });
    }).on('error', reject);
  });
}

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function main() {
  console.log('[4K RECORDER] Connecting to Chrome DevTools Protocol...');
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
    
    const urlEval = await evaluate("window.location.href");
    const isShinyPage = (urlEval?.result?.value || '').includes(':3838');
    let isLive = true;
    if (isShinyPage) {
      const checkLive = await evaluate("Boolean(document.getElementById('hudReady') || document.querySelector('.athena-shell'))");
      isLive = checkLive?.result?.value;
      if (!isLive) throw new Error(`CRITICAL ERROR: Shiny disconnected on frame ${name}!`);
    }
    console.log(`[4K RECORDER] Captured ${name} (${Math.round(buf.length / 1024)} KB, shiny=${isShinyPage})`);
  };

  ws.onopen = async () => {
    await send('Page.enable');
    await send('Runtime.enable');
    
    // 3840 x 2160 true 4K via 1920x1080 @ 2x device scale factor (Retina UHD)
    await send('Emulation.setDeviceMetricsOverride', {
      width: 1920, height: 1080, deviceScaleFactor: 2, mobile: false
    });

    console.log('[4K RECORDER] Frame 01: Title Intro...');
    await send('Page.navigate', { url: `file://${path.join(__dirname, 'title_cards.html')}?type=intro` });
    await sleep(1500);
    await capture('01_title_intro.png');

    console.log('[4K RECORDER] Frame 02: What is ATHENA...');
    await send('Page.navigate', { url: `file://${path.join(__dirname, 'title_cards.html')}?type=whatis` });
    await sleep(1400);
    await capture('02_title_whatis.png');

    console.log('[4K RECORDER] Loading ATHENA Live Console...');
    await send('Page.navigate', { url: 'http://127.0.0.1:3838/' });
    
    // Wait for console telemetry and all charts to auto-populate
    for (let waitCount = 0; waitCount < 25; waitCount++) {
      const check = await evaluate("document.getElementById('hudReady')?.innerText || ''");
      if (check.result && check.result.value && check.result.value !== '' && check.result.value !== '—') {
        console.log(`[4K RECORDER] Console fully populated (readiness: ${check.result.value}) in ${waitCount}s`);
        break;
      }
      await sleep(1000);
    }
    // Additional stabilization for chart auto-population
    await sleep(3000);

    // Initial baseline: English, Cyberpunk Dark theme, 100% zoom
    await evaluate("applyTheme('dark'); applyLang('en'); applyZoom(1.0);");
    await sleep(1200);
    await capture('03_dashboard_dark.png');

    console.log('[4K RECORDER] Frame 04: Daylight Mode...');
    await evaluate("applyTheme('light');");
    await sleep(1200);
    await capture('04_dashboard_light.png');

    console.log('[4K RECORDER] Frame 05: Dynamic UI Zoom (120%)...');
    await evaluate("applyZoom(1.2);");
    await sleep(1000);
    await capture('05_zoom_in.png');
    await evaluate("applyZoom(1.0); applyTheme('dark');");
    await sleep(500);

    console.log('[4K RECORDER] Frame 06: Multilingual Interstitial (10 colorful boxes)...');
    await send('Page.navigate', { url: `file://${path.join(__dirname, 'title_cards.html')}?type=languages` });
    await sleep(1500);
    await capture('06_title_languages.png');

    console.log('[4K RECORDER] Return to Console for Global Languages Demonstration...');
    await send('Page.navigate', { url: 'http://127.0.0.1:3838/' });
    await sleep(2500);

    // Arabic with native Right-To-Left (RTL) Layout
    console.log('[4K RECORDER] Frame 07: Arabic RTL Language...');
    await evaluate("applyLang('ar');");
    await sleep(1500);
    await capture('07_lang_arabic.png');

    // Hindi
    console.log('[4K RECORDER] Frame 08: Hindi Language...');
    await evaluate("applyLang('hi');");
    await sleep(1200);
    await capture('08_lang_hindi.png');

    // Spanish
    console.log('[4K RECORDER] Frame 09: Spanish Language...');
    await evaluate("applyLang('es');");
    await sleep(1200);
    await capture('09_lang_spanish.png');

    // French
    console.log('[4K RECORDER] Frame 10: French Language...');
    await evaluate("applyLang('fr');");
    await sleep(1200);
    await capture('10_lang_french.png');

    // Chinese
    console.log('[4K RECORDER] Frame 11: Chinese Language...');
    await evaluate("applyLang('zh');");
    await sleep(1200);
    await capture('11_lang_chinese.png');

    // Return to English for deep feature inspection
    await evaluate("applyLang('en');");
    await sleep(800);

    console.log('[4K RECORDER] Frame 12: Injury Prevention Interstitial...');
    await send('Page.navigate', { url: `file://${path.join(__dirname, 'title_cards.html')}?type=injury` });
    await sleep(1500);
    await capture('12_title_injury.png');

    console.log('[4K RECORDER] Loading Console for Squad Roster & Risk Filtering...');
    await send('Page.navigate', { url: 'http://127.0.0.1:3838/' });
    await sleep(2500);

    console.log('[4K RECORDER] Frame 13: Multi-Athlete Roster...');
    await evaluate("tabBtnActivate('roster'); if(window.Shiny) Shiny.setInputValue('mainTabs','roster',{priority:'event'});");
    await sleep(2000);
    await capture('13_roster_cards.png');

    console.log('[4K RECORDER] Frame 14: Filtering High-Fatigue Caution/Amber Athletes...');
    await evaluate("document.getElementById('fAmber').click();");
    await sleep(1500);
    await capture('14_roster_filter_caution.png');

    console.log('[4K RECORDER] Frame 15: Sortable Clinical Tabular View...');
    await evaluate("document.getElementById('fAll').click(); document.getElementById('vTable').click();");
    await sleep(1800);
    await capture('15_roster_table.png');

    console.log('[4K RECORDER] Frame 16: 8-Axis Biomechanical & Readiness Radar...');
    await evaluate("tabBtnActivate('athlete'); if(window.Shiny) Shiny.setInputValue('mainTabs','athlete',{priority:'event'});");
    // Ensure all SVGs on athlete tab finish rendering
    await sleep(3500);
    await capture('16_athlete_radar.png');

    console.log('[4K RECORDER] Frame 17: Performance Curves & Blood Lactate Threshold...');
    await evaluate("window.scrollTo(0, 480);");
    await sleep(2500);
    await capture('17_athlete_perf_lactate.png');

    console.log('[4K RECORDER] Frame 18: Sleep Architecture Hypnogram & DXA Bone Health...');
    await evaluate("window.scrollTo(0, 920);");
    await sleep(2500);
    await capture('18_athlete_sleep_hypno.png');
    await evaluate("window.scrollTo(0, 0);");

    console.log('[4K RECORDER] Frame 19: Female Athlete & RED-S Interstitial...');
    await send('Page.navigate', { url: `file://${path.join(__dirname, 'title_cards.html')}?type=female` });
    await sleep(1500);
    await capture('19_title_female.png');

    console.log('[4K RECORDER] Loading Console for IOC RED-S Lab...');
    await send('Page.navigate', { url: 'http://127.0.0.1:3838/' });
    await sleep(2500);

    console.log('[4K RECORDER] Frame 20: IOC 2023 RED-S Clinical Energy Availability Lab...');
    await evaluate("tabBtnActivate('reds'); if(window.Shiny) Shiny.setInputValue('mainTabs','reds',{priority:'event'});");
    await sleep(3000);
    await capture('20_reds_lab.png');

    console.log('[4K RECORDER] Frame 21: Full Squad Load Matrix & Foster Monotony Heatmap...');
    await evaluate("tabBtnActivate('cohort'); if(window.Shiny) Shiny.setInputValue('mainTabs','cohort',{priority:'event'});");
    await sleep(3500);
    await capture('21_cohort_heatmap.png');

    console.log('[4K RECORDER] Frame 22: Evidence-Based Scientific Outro...');
    await send('Page.navigate', { url: `file://${path.join(__dirname, 'title_cards.html')}?type=outro` });
    await sleep(1500);
    await capture('22_title_outro.png');

    console.log('[4K RECORDER] All 22 4K UHD promotional frames captured successfully!');
    process.exit(0);
  };
}

main().catch(err => {
  console.error('[4K RECORDER ERROR]', err);
  process.exit(1);
});
