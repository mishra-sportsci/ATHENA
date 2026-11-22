const http = require('http');
const fs = require('fs');
const path = require('path');

const OUTPUT_DIR = path.join(__dirname, 'frames_30s');
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
  console.log('[30S 4K RECORDER] Connecting to Chrome DevTools Protocol...');
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
    console.log(`[30S 4K RECORDER] Captured ${name} (${Math.round(buf.length / 1024)} KB)`);
  };

  ws.onopen = async () => {
    await send('Page.enable');
    await send('Runtime.enable');
    
    // 3840 x 2160 true 4K via 1920x1080 @ 2x device scale factor (Retina UHD)
    await send('Emulation.setDeviceMetricsOverride', {
      width: 1920, height: 1080, deviceScaleFactor: 2, mobile: false
    });

    console.log('[30S 4K RECORDER] Frame 01: Title Intro (Female focus + Male adaptive)...');
    await send('Page.navigate', { url: `file://${path.join(__dirname, 'title_cards.html')}?type=intro` });
    await sleep(1500);
    await capture('01_title_intro.png');

    console.log('[30S 4K RECORDER] Frame 02: Female Athlete Hormonal Phases & RED-S Interstitial...');
    await send('Page.navigate', { url: `file://${path.join(__dirname, 'title_cards.html')}?type=female` });
    await sleep(1500);
    await capture('02_title_female.png');

    console.log('[30S 4K RECORDER] Loading ATHENA Console on port 3838...');
    await send('Page.navigate', { url: 'http://127.0.0.1:3838/' });
    
    // Wait for console to auto-populate
    for (let waitCount = 0; waitCount < 25; waitCount++) {
      const check = await evaluate("document.getElementById('hudReady')?.innerText || ''");
      if (check.result && check.result.value && check.result.value !== '' && check.result.value !== '—') {
        console.log(`[30S 4K RECORDER] Console fully populated in ${waitCount}s`);
        break;
      }
      await sleep(1000);
    }
    await sleep(3000);

    // Initial state: Dark theme, English
    await evaluate("applyTheme('dark'); applyLang('en'); applyZoom(1.0);");
    await sleep(1200);
    console.log('[30S 4K RECORDER] Frame 03: Live Biometric HUD & Readiness Ring...');
    await capture('03_dashboard_hud.png');

    // Switch to Cohort Tab and activate 4-Athlete Comparison Radar
    console.log('[30S 4K RECORDER] Frame 04: 4-Athlete Comparison Radar Chart...');
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
    await capture('04_cohort_compare_radar.png');

    // Switch to Athlete Tab: Performance Curves & Blood Lactate
    console.log('[30S 4K RECORDER] Frame 05: Performance Multi-Line (Menstrual Shading) & Lactate Curve...');
    await evaluate("tabBtnActivate('athlete'); if(window.Shiny) Shiny.setInputValue('mainTabs','athlete',{priority:'event'});");
    await sleep(3000);
    await evaluate("window.scrollTo(0, 480);");
    await sleep(2000);
    await capture('05_athlete_perf_lactate.png');

    // Sleep Architecture Hypnogram
    console.log('[30S 4K RECORDER] Frame 06: Sleep Architecture Hypnogram & Stage Bars...');
    await evaluate("window.scrollTo(0, 920);");
    await sleep(2000);
    await capture('06_athlete_sleep_hypno.png');
    await evaluate("window.scrollTo(0, 0);");

    // RED-S Lab
    console.log('[30S 4K RECORDER] Frame 07: IOC 2023 RED-S Energy Availability Clinical Lab...');
    await evaluate("tabBtnActivate('reds'); if(window.Shiny) Shiny.setInputValue('mainTabs','reds',{priority:'event'});");
    await sleep(3000);
    await capture('07_reds_lab.png');

    // Squad Load Heatmap
    console.log('[30S 4K RECORDER] Frame 08: Full Squad Load Matrix & Foster Monotony Heatmap...');
    await evaluate("tabBtnActivate('cohort'); if(window.Shiny) Shiny.setInputValue('mainTabs','cohort',{priority:'event'});");
    await sleep(3000);
    await evaluate("window.scrollTo(0, 400);");
    await sleep(1500);
    await capture('08_cohort_heatmap.png');
    await evaluate("window.scrollTo(0, 0);");

    // 10 Global Languages Card
    console.log('[30S 4K RECORDER] Frame 09: 10 Global Languages (10 Vibrant Colorful Boxes)...');
    await send('Page.navigate', { url: `file://${path.join(__dirname, 'title_cards.html')}?type=languages` });
    await sleep(1500);
    await capture('09_title_languages.png');

    // Arabic RTL in-app live
    console.log('[30S 4K RECORDER] Frame 10: Dynamic Arabic RTL In-App Localization...');
    await send('Page.navigate', { url: 'http://127.0.0.1:3838/' });
    await sleep(2500);
    await evaluate("applyLang('ar');");
    await sleep(1800);
    await capture('10_lang_arabic_rtl.png');

    // Daylight Mode
    console.log('[30S 4K RECORDER] Frame 11: Daylight Sunlight Mode...');
    await evaluate("applyLang('en'); applyTheme('light');");
    await sleep(1500);
    await capture('11_dashboard_light.png');

    // Scientific Evidence-Based Outro
    console.log('[30S 4K RECORDER] Frame 12: Scientific Evidence-Based Outro...');
    await send('Page.navigate', { url: `file://${path.join(__dirname, 'title_cards.html')}?type=outro` });
    await sleep(1500);
    await capture('12_title_outro.png');

    console.log('[30S 4K RECORDER] All 12 4K UHD promotional frames captured successfully!');
    process.exit(0);
  };
}

main().catch(err => {
  console.error('[30S 4K RECORDER ERROR]', err);
  process.exit(1);
});
