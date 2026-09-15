// Isolated browser against PocketDeskBrowserFixture only; never use with a real host.
const { chromium, webkit } = require(process.env.POCKETDESK_PLAYWRIGHT || 'playwright');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

(async () => {
  const directory = process.env.POCKETDESK_BROWSER_RECEIPTS;
  if (!directory) throw new Error('POCKETDESK_BROWSER_RECEIPTS is required');
  const origin = process.env.POCKETDESK_BROWSER_URL || 'http://127.0.0.1:8791';
  if (!/^http:\/\/127\.0\.0\.1:\d+$/.test(origin)) throw new Error('Synthetic tests require exact loopback');
  const mode = process.env.POCKETDESK_FIXTURE_MODE || 'interactive';
  const engine = process.env.POCKETDESK_BROWSER_ENGINE === 'webkit' ? webkit : chromium;
  const executable = engine === webkit ? process.env.POCKETDESK_WEBKIT : process.env.POCKETDESK_CHROMIUM;
  const browser = await engine.launch({ headless: true, ...(executable ? { executablePath: executable } : {}) });
  const receipt = { synthetic: true, engine: engine === webkit ? 'Playwright WebKit' : 'Chromium', mode, checks: [] };
  let testPage;
  const check = (name, value = true) => { assert.ok(value, name); receipt.checks.push(name); console.log(`PASS ${name}`); };
  const hostAction = async name => {
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline) {
      try { if (JSON.parse(fs.readFileSync(path.join(directory,'host-receipt.json'),'utf8')).lastAction === name) return; } catch {}
      await new Promise(resolve => setTimeout(resolve,30));
    }
    throw new Error(`Native fixture did not receive ${name}`);
  };
  try {
    const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
    testPage = page;
    const errors = [], violations = [], calls = [];
    page.on('pageerror', error => errors.push(error.message));
    page.on('request', request => { if (request.url().includes('/browser-api/')) calls.push(request.method()); });
    await page.addInitScript(() => {
      window.__fixtureViolations = [];
      document.addEventListener('securitypolicyviolation', event => window.__fixtureViolations.push(event.violatedDirective));
      const RealPeer = window.RTCPeerConnection;
      window.RTCPeerConnection = class extends RealPeer {
        constructor(...args) {
          super(...args);
          window.__fixturePeer = this;
          this.addEventListener('datachannel', event => {
            window.__fixtureChannel = event.channel;
            event.channel.addEventListener('message', message => {
              try {
                const value = JSON.parse(new TextDecoder().decode(message.data));
                if (value.type === 'status') window.__fixtureStatus = value;
              } catch {}
            });
          });
        }
      };
    });
    await page.goto(origin);
    await page.waitForFunction(() => document.querySelector('#enroll') && document.querySelector('#connect').disabled);
    check('GET is inert', calls.length === 0);
    check('Mobile enrollment is reachable', await page.locator('#offer').isVisible());
    await page.screenshot({ path: path.join(directory, 'mobile-inert.png'), fullPage: true });
    await page.locator('#offer').fill(fs.readFileSync(path.join(directory, 'offer.private'), 'utf8'));
    await page.locator('#enroll').click();
    await page.waitForFunction(() => !document.querySelector('#connect').disabled, null, { timeout: 15000 });
    check('Synthetic native enrollment succeeds');

    const denied = await page.evaluate(async () => {
      const crypto = await import('/src/crypto.js');
      const database = await new Promise(resolve => { const r = indexedDB.open('pocketdesk-browser-v1', 1); r.onsuccess = () => resolve(r.result); });
      const enrollment = await new Promise(resolve => { const r = database.transaction('browser').objectStore('browser').get('enrollment'); r.onsuccess = () => resolve(r.result); });
      database.close();
      const post = (name, body) => fetch(`/browser-api/${enrollment.hostID}/${name}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
      const wrongPeer = await post('challenge', { peerID: crypto.random(), nonce: crypto.random(), mode: enrollment.mode });
      const challenge = await (await post('challenge', { peerID: enrollment.peerID, nonce: crypto.random(), mode: enrollment.mode })).json();
      const ephemeral = await crypto.generateEphemeral();
      const forged = { session: challenge.fields[7], publicKey: ephemeral.publicKey, signature: btoa(String.fromCharCode(...new Uint8Array(64))) };
      const badProof = await post('proof', forged);
      const replay = await post('proof', forged);
      return [wrongPeer.status, badProof.status, replay.status];
    });
    check('Native rejects unknown peer, forged proof and consumed-proof replay', denied.every(code => code === 400));
    await page.locator('#connect').click();
    await page.waitForFunction(() => document.querySelector('#video').videoWidth === 1280 && document.querySelector('#video').currentTime > 0.7, null, { timeout: 25000 });
    check('Native encrypted signaling and H.264 video arrive');
    await page.locator('#reveal').click();
    if (mode === 'interactive') {
      await page.waitForFunction(() => document.querySelector('#interactive-controls').dataset.interactive === 'true');
      check('Decoded native pixel marker enables interactive controls');
      await page.locator('#draft').fill('Browser fixture edit ✓');
      await page.locator('#draft').dispatchEvent('compositionstart');
      check('IME composition cannot submit intermediate text', await page.locator('#send-text').isDisabled());
      await page.locator('#draft').dispatchEvent('compositionend');
      await page.locator('#send-text').click();
      await page.waitForFunction(() => document.querySelector('#draft').value === '');
      const accepted = JSON.parse(fs.readFileSync(path.join(directory, 'host-receipt.json'), 'utf8'));
      check('Unicode draft receives matching native acknowledgement', accepted.accepted === 1 && accepted.lastAction === 'text');
      for (const action of ['click','right','double']) { await page.locator(`[data-action="${action}"]`).click(); await hostAction(action); }
      await page.locator('#key').fill('return'); await page.locator('#modifier').selectOption('shift');
      await page.locator('#send-key').click(); await hostAction('key');
      await page.locator('#trackpad').hover(); await page.mouse.wheel(0,30); await hostAction('scroll');
      check('Explicit clicks, modified key and relative scroll reach native fixture');
    } else {
      check('View-only controls remain disabled', await page.locator('#send-text').isDisabled());
      await page.evaluate(async () => {
        const video = document.querySelector('#video'), canvas = document.createElement('canvas');
        canvas.width = video.videoWidth; canvas.height = video.videoHeight;
        const context = canvas.getContext('2d'); context.drawImage(video, 0, 0);
        const { decodeMarker } = await import('/src/viewer/marker.js');
        const marker = decodeMarker(context.getImageData(0, 0, canvas.width, canvas.height));
        const status = window.__fixtureStatus;
        if (!marker || !status) throw new Error('No native frame/status');
        window.__fixtureChannel.send(new TextEncoder().encode(JSON.stringify({ type: 'input', session: status.session, sequence: '1', revision: status.revision, frameToken: marker.token, action: { action: 'click', x: 0, y: 0, text: '', key: '', modifiers: [], epoch: Number(status.revision) } })));
      });
      await page.waitForFunction(() => true); // Yield the event loop; poll receipt below.
      const deadline = Date.now() + 5000;
      while (!fs.existsSync(path.join(directory, 'host-receipt.json.rejection')) && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 50));
      check('Native rejects crafted view-only input with a valid pixel token', fs.existsSync(path.join(directory, 'host-receipt.json.rejection')));
    }
    await page.screenshot({ path: path.join(directory, 'mobile-connected.png'), fullPage: true });
    const layout = await page.locator('#viewport').boundingBox();
    check('Mobile video remains in the viewport', layout.y >= 0 && layout.y + layout.height <= 844);
    await page.setViewportSize({ width: 1024, height: 850 });
    await page.screenshot({ path: path.join(directory, 'desktop-connected.png'), fullPage: true });
    if (mode === 'interactive') {
      await page.locator('#drag').click(); await hostAction('dragDown');
      await page.locator('#draft').fill('FREEZE'); await page.locator('#send-text').click();
      await page.waitForFunction(() => document.querySelector('#interactive-controls').dataset.interactive === 'false', null, { timeout: 5000 });
      check('Frozen native video disables input', await page.locator('#send-text').isDisabled());
      await hostAction('release'); check('Stale video sends a scoped held-input release');
    }
    await page.locator('#end').click();
    check('End clears decoded video', await page.locator('#video').evaluate(video => video.srcObject === null));
    await page.locator('#connect').click();
    await page.waitForFunction(() => document.querySelector('#video').videoWidth === 1280 && document.querySelector('#video').currentTime > 0.5, null, { timeout: 25000 });
    check('Fresh challenge reconnects without re-enrollment');
    if (mode === 'interactive') {
      await page.waitForFunction(() => document.querySelector('#interactive-controls').dataset.interactive === 'true');
      await page.evaluate(() => {
        const channel = window.__fixtureChannel, original = channel.onmessage;
        channel.onmessage = event => {
          try { if (JSON.parse(new TextDecoder().decode(event.data)).type === 'textResult') return; } catch {}
          original.call(channel,event);
        };
      });
      await page.locator('#draft').fill('Uncertain acknowledgement fixture'); await page.locator('#send-text').click(); await hostAction('text');
      check('Lost acknowledgement retains the draft and blocks duplicate sends', await page.locator('#send-text').isDisabled() && await page.locator('#draft').inputValue() === 'Uncertain acknowledgement fixture');
      const before = JSON.parse(fs.readFileSync(path.join(directory,'host-receipt.json'),'utf8')).accepted;
      await page.locator('#end').click(); await page.locator('#connect').click();
      await page.waitForFunction(() => document.querySelector('#interactive-controls').dataset.interactive === 'true');
      check('Reconnect retains uncertain draft without replay and allows explicit retry', JSON.parse(fs.readFileSync(path.join(directory,'host-receipt.json'),'utf8')).accepted === before && await page.locator('#draft').inputValue() === 'Uncertain acknowledgement fixture' && !await page.locator('#send-text').isDisabled());
    }
    await page.evaluate(() => window.dispatchEvent(new Event('pagehide')));
    check('Page hide tears down the session', await page.locator('#video').evaluate(video => video.srcObject === null));
    violations.push(...await page.evaluate(() => window.__fixtureViolations));
    check('No page errors or security-policy violations', errors.length === 0 && violations.length === 0);
    receipt.result = 'passed';
  } catch (error) {
    receipt.result = 'failed';
    receipt.diagnostic = await testPage?.evaluate(async () => {
      const peer = window.__fixturePeer, video = document.querySelector('#video');
      const stats = peer ? await peer.getStats() : new Map();
      return {
        status: document.querySelector('#status').textContent,
        connection: peer?.connectionState, ice: peer?.iceConnectionState,
        width: video?.videoWidth, height: video?.videoHeight, time: video?.currentTime,
        inbound: [...stats.values()].filter(s => s.type === 'inbound-rtp').map(s => ({kind:s.kind,packets:s.packetsReceived,frames:s.framesDecoded})),
        codecs: [...stats.values()].filter(s => s.type === 'codec').map(s => s.mimeType)
      };
    }).catch(() => ({unavailable:true}));
    console.log('Failure diagnostic',JSON.stringify(receipt.diagnostic));
    throw error;
  } finally {
    fs.writeFileSync(path.join(directory, 'browser-receipt.json'), JSON.stringify(receipt, null, 2));
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
