const http = require('http');
const fs = require('fs');
const path = require('path');

const OUTPUT_DIR = path.join(__dirname, 'frames_vertical');
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
  console.log('[4K VERTICAL RECORDER] Connecting to CDP...');
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
    console.log(`[4K VERTICAL RECORDER] Captured: ${name} (${Math.round(buf.length / 1024)} KB, shiny=${isShinyPage})`);
  };

  ws.onopen = async () => {
    await send('Page.enable');
    await send('Runtime.enable');
    
    // 2160 x 3840 true 4K via 1080x1920 @ 2x device scale factor (Retina UHD Vertical)
    await send('Emulation.setDeviceMetricsOverride', {
      width: 1080, height: 1920, deviceScaleFactor: 2, mobile: true
    });

    console.log('[4K VERTICAL RECORDER] Frame 01: Vertical Intro Title...');
    await send('Page.navigate', { url: `file://${path.join(__dirname, 'title_cards_vertical.html')}?type=intro` });
    await sleep(1500);
    await capture('01_v_intro.png');

    console.log('[4K VERTICAL RECORDER] Frame 02: What is ATHENA Title...');
    await send('Page.navigate', { url: `file://${path.join(__dirname, 'title_cards_vertical.html')}?type=whatis` });
    await sleep(1400);
    await capture('02_v_whatis.png');

    console.log('[4K VERTICAL RECORDER] Loading Shiny Console (Mobile 4K)...');
    await send('Page.navigate', { url: 'http://127.0.0.1:3838/' });
    // Wait for console to fully compute and populate
    for (let waitCount = 0; waitCount < 25; waitCount++) {
      const check = await evaluate("document.getElementById('hudReady')?.innerText || ''");
      if (check.result && check.result.value && check.result.value !== '' && check.result.value !== '—') {
        console.log(`[4K VERTICAL RECORDER] Console populated (readiness: ${check.result.value}) in ${waitCount}s`);
        break;
      }
      await sleep(1000);
    }
    await sleep(3000);

    // Initial state
    await evaluate("applyTheme('dark'); applyLang('en'); applyZoom(1.0);");
    await sleep(1200);
    await capture('03_v_dashboard_dark.png');

    console.log('[4K VERTICAL RECORDER] Frame 04: Mobile Day Light Mode...');
    await evaluate("applyTheme('light');");
    await sleep(1200);
    await capture('04_v_dashboard_light.png');

    console.log('[4K VERTICAL RECORDER] Return to Night Mode & Zoom...');
    await evaluate("applyTheme('dark'); applyZoom(1.1);");
    await sleep(1000);
    await capture('05_v_zoom.png');
    await evaluate("applyZoom(1.0);");
    await sleep(500);

    console.log('[4K VERTICAL RECORDER] Frame 06: Languages Interstitial (10 separate colorful boxes)...');
    await send('Page.navigate', { url: `file://${path.join(__dirname, 'title_cards_vertical.html')}?type=languages` });
    await sleep(1500);
    await capture('06_v_languages.png');

    console.log('[4K VERTICAL RECORDER] Loading Console for Languages Demo...');
    await send('Page.navigate', { url: 'http://127.0.0.1:3838/' });
    await sleep(2500);

    console.log('[4K VERTICAL RECORDER] Frame 07: Spanish...');
    await evaluate("applyLang('es');");
    await sleep(1200);
    await capture('07_v_spanish.png');

    console.log('[4K VERTICAL RECORDER] Frame 08: Hindi...');
    await evaluate("applyLang('hi');");
    await sleep(1200);
    await capture('08_v_hindi.png');

    console.log('[4K VERTICAL RECORDER] Frame 09: Arabic RTL...');
    await evaluate("applyLang('ar');");
    await sleep(1500);
    await capture('09_v_arabic.png');

    console.log('[4K VERTICAL RECORDER] Frame 10: Chinese...');
    await evaluate("applyLang('zh');");
    await sleep(1200);
    await capture('10_v_chinese.png');

    // Return to English
    await evaluate("applyLang('en');");
    await sleep(800);

    console.log('[4K VERTICAL RECORDER] Frame 11: Multi-Athlete Roster...');
    await evaluate("tabBtnActivate('roster'); if(window.Shiny) Shiny.setInputValue('mainTabs','roster',{priority:'event'});");
    await sleep(1800);
    await evaluate("document.getElementById('fAmber').click();");
    await sleep(1400);
    await capture('11_v_roster.png');

    console.log('[4K VERTICAL RECORDER] Frame 12: Athlete Detail Biometric Radar...');
    await evaluate("tabBtnActivate('athlete'); if(window.Shiny) Shiny.setInputValue('mainTabs','athlete',{priority:'event'});");
    await sleep(3500);
    await capture('12_v_athlete_radar.png');

    console.log('[4K VERTICAL RECORDER] Frame 13: Lactate Curve & Performance Trends...');
    await evaluate("window.scrollTo(0, 500);");
    await sleep(2500);
    await capture('13_v_athlete_curves.png');
    await evaluate("window.scrollTo(0, 0);");

    console.log('[4K VERTICAL RECORDER] Frame 14: Female Athlete & RED-S Interstitial...');
    await send('Page.navigate', { url: `file://${path.join(__dirname, 'title_cards_vertical.html')}?type=female` });
    await sleep(1500);
    await capture('14_v_female.png');

    console.log('[4K VERTICAL RECORDER] Loading Console for RED-S Lab...');
    await send('Page.navigate', { url: 'http://127.0.0.1:3838/' });
    await sleep(2500);

    console.log('[4K VERTICAL RECORDER] Frame 15: Mobile IOC RED-S Lab...');
    await evaluate("tabBtnActivate('reds'); if(window.Shiny) Shiny.setInputValue('mainTabs','reds',{priority:'event'});");
    await sleep(3000);
    await capture('15_v_reds.png');

    console.log('[4K VERTICAL RECORDER] Frame 16: Squad Load Matrix Heatmap...');
    await evaluate("tabBtnActivate('cohort'); if(window.Shiny) Shiny.setInputValue('mainTabs','cohort',{priority:'event'});");
    await sleep(3500);
    await capture('16_v_cohort.png');

    console.log('[4K VERTICAL RECORDER] Frame 17: Vertical Outro...');
    await send('Page.navigate', { url: `file://${path.join(__dirname, 'title_cards_vertical.html')}?type=outro` });
    await sleep(1500);
    await capture('17_v_outro.png');

    console.log('[4K VERTICAL RECORDER] All 17 4K vertical frames captured successfully!');
    process.exit(0);
  };
}

main().catch(e => { console.error(e); process.exit(1); });
