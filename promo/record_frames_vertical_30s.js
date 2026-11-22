const http = require('http');
const fs = require('fs');
const path = require('path');

const OUTPUT_DIR = path.join(__dirname, 'frames_vertical_30s');
if (!fs.existsSync(OUTPUT_DIR)) fs.mkdirSync(OUTPUT_DIR, { recursive: true });

async function getWsUrl() {
  return new Promise((resolve, reject) => {
    http.get('http://127.0.0.1:9222/json/list', (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        const json = JSON.parse(data);
        resolve(json[0].webSocketDebuggerUrl);
      });
    }).on('error', reject);
  });
}

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function main() {
  console.log('[30S 4K VERTICAL RECORDER] Connecting to CDP...');
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
    console.log(`[30S 4K VERTICAL RECORDER] Captured: ${name} (${Math.round(buf.length / 1024)} KB)`);
  };

  ws.onopen = async () => {
    await send('Page.enable');
    await send('Runtime.enable');
    
    // 2160 x 3840 true 4K via 1080x1920 @ 2x device scale factor (Retina UHD Vertical)
    await send('Emulation.setDeviceMetricsOverride', {
      width: 1080, height: 1920, deviceScaleFactor: 2, mobile: true
    });

    console.log('[30S 4K VERTICAL RECORDER] Frame 01: Vertical Intro (Female + Male adaptive)...');
    await send('Page.navigate', { url: `file://${path.join(__dirname, 'title_cards_vertical.html')}?type=intro` });
    await sleep(1500);
    await capture('01_v_intro.png');

    console.log('[30S 4K VERTICAL RECORDER] Frame 02: Female Focus & RED-S Title...');
    await send('Page.navigate', { url: `file://${path.join(__dirname, 'title_cards_vertical.html')}?type=female` });
    await sleep(1500);
    await capture('02_v_female.png');

    console.log('[30S 4K VERTICAL RECORDER] Loading ATHENA Console on port 3838...');
    await send('Page.navigate', { url: 'http://127.0.0.1:3838/' });
    for (let waitCount = 0; waitCount < 25; waitCount++) {
      const check = await evaluate("document.getElementById('hudReady')?.innerText || ''");
      if (check.result && check.result.value && check.result.value !== '' && check.result.value !== '—') break;
      await sleep(1000);
    }
    await sleep(3000);

    // Initial state
    await evaluate("applyTheme('dark'); applyLang('en'); applyZoom(1.0);");
    await sleep(1200);
    console.log('[30S 4K VERTICAL RECORDER] Frame 03: Live Mobile HUD & Readiness Ring...');
    await capture('03_v_dashboard_hud.png');

    // Cohort 4-Athlete Compare Radar
    console.log('[30S 4K VERTICAL RECORDER] Frame 04: 4-Athlete Comparison Radar...');
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
    await capture('04_v_cohort_compare_radar.png');

    // Athlete Performance Curves
    console.log('[30S 4K VERTICAL RECORDER] Frame 05: Athlete Curves & Lactate...');
    await evaluate("tabBtnActivate('athlete'); if(window.Shiny) Shiny.setInputValue('mainTabs','athlete',{priority:'event'});");
    await sleep(3000);
    await evaluate("window.scrollTo(0, 480);");
    await sleep(2000);
    await capture('05_v_athlete_perf_lactate.png');

    // Sleep Architecture Hypnogram
    console.log('[30S 4K VERTICAL RECORDER] Frame 06: Sleep Architecture Hypnogram...');
    await evaluate("window.scrollTo(0, 920);");
    await sleep(2000);
    await capture('06_v_athlete_sleep_hypno.png');
    await evaluate("window.scrollTo(0, 0);");

    // IOC RED-S Lab
    console.log('[30S 4K VERTICAL RECORDER] Frame 07: Mobile IOC RED-S Lab...');
    await evaluate("tabBtnActivate('reds'); if(window.Shiny) Shiny.setInputValue('mainTabs','reds',{priority:'event'});");
    await sleep(3000);
    await capture('07_v_reds.png');

    // Squad Load Heatmap
    console.log('[30S 4K VERTICAL RECORDER] Frame 08: Mobile Squad Load Heatmap...');
    await evaluate("tabBtnActivate('cohort'); if(window.Shiny) Shiny.setInputValue('mainTabs','cohort',{priority:'event'});");
    await sleep(3000);
    await evaluate("window.scrollTo(0, 400);");
    await sleep(1500);
    await capture('08_v_cohort_heatmap.png');
    await evaluate("window.scrollTo(0, 0);");

    // Languages card (10 separate colorful badges)
    console.log('[30S 4K VERTICAL RECORDER] Frame 09: 10 Languages Card...');
    await send('Page.navigate', { url: `file://${path.join(__dirname, 'title_cards_vertical.html')}?type=languages` });
    await sleep(1500);
    await capture('09_v_languages.png');

    // Live Arabic RTL
    console.log('[30S 4K VERTICAL RECORDER] Frame 10: Dynamic Arabic RTL Live...');
    await send('Page.navigate', { url: 'http://127.0.0.1:3838/' });
    await sleep(2500);
    await evaluate("applyLang('ar');");
    await sleep(1800);
    await capture('10_v_lang_arabic.png');

    // Daylight Mode
    console.log('[30S 4K VERTICAL RECORDER] Frame 11: Mobile Day Light Mode...');
    await evaluate("applyLang('en'); applyTheme('light');");
    await sleep(1500);
    await capture('11_v_dashboard_light.png');

    // Outro
    console.log('[30S 4K VERTICAL RECORDER] Frame 12: Vertical Outro...');
    await send('Page.navigate', { url: `file://${path.join(__dirname, 'title_cards_vertical.html')}?type=outro` });
    await sleep(1500);
    await capture('12_v_outro.png');

    console.log('[30S 4K VERTICAL RECORDER] All 12 4K vertical frames captured successfully!');
    process.exit(0);
  };
}

main().catch(e => { console.error(e); process.exit(1); });
