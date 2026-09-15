// Local, isolated browser race tests. Fake approval uses test-only keys.
const { chromium, webkit } = require(process.env.POCKETDESK_PLAYWRIGHT || 'playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
(async () => {
  const origin = process.env.POCKETDESK_BROWSER_URL || 'http://127.0.0.1:8788';
  if (!/^http:\/\/127\.0\.0\.1:\d+$/.test(origin)) throw new Error('Loopback only');
  const engine = process.env.POCKETDESK_BROWSER_ENGINE === 'webkit' ? webkit : chromium;
  const executable = engine === webkit ? process.env.POCKETDESK_WEBKIT : process.env.POCKETDESK_CHROMIUM;
  const browser = await engine.launch({ headless:true, ...(executable ? {executablePath:executable} : {}) });
  try {
    const page = await browser.newPage(), errors=[];
    page.on('pageerror',error=>errors.push(error.message));
    if (engine === chromium) {
      await page.goto(origin+'/probe/');
      await page.locator('#start').click(); await page.locator('#stop').click();
      assert.equal(await page.locator('#receiver').evaluate(v=>v.srcObject===null),true);
      await page.locator('#start').click();
      await page.waitForFunction(()=>document.querySelector('#receiver').videoWidth>0 && document.querySelector('#receiver').currentTime>0.3);
      assert.match(await page.locator('#status').innerText(),/decoded/);
      await page.locator('#stop').click();
      assert.equal(await page.locator('#receiver').evaluate(v=>v.srcObject===null),true);
      console.log('PASS Synthetic probe cancellation, decoded video and cleanup');
    }
    await page.goto(origin); await page.waitForFunction(()=>!document.querySelector('#enroll').disabled);
    const offer = await page.evaluate(async () => {
      const crypto = await import('/src/crypto.js');
      window.testIdentity = await crypto.generateIdentity();
      window.testOffer = {version:1,url:location.origin,hostID:'1'.repeat(64),secret:'2'.repeat(64),hostKey:window.testIdentity.publicKey,expires:String(Date.now()+120000)};
      return 'pocketdesk-browser:'+btoa(JSON.stringify(window.testOffer));
    });
    let releaseApproval, approvalStarted;
    let arrival = new Promise(resolve=>approvalStarted=resolve), delay=true;
    await page.route('**/browser-api/*/enroll',async route=>{
      const body=route.request().postDataJSON();
      assert.deepEqual(Object.keys(body).sort(),['nonce','payload']);
      const response=await page.evaluate(async body=>{
        const cryptoModule=await import('/src/crypto.js'), offer=window.testOffer;
        const key=await crypto.subtle.importKey('raw',new Uint8Array(32).fill(0x22),'AES-GCM',false,['decrypt']);
        const decode=s=>Uint8Array.from(atob(s),c=>c.charCodeAt(0));
        const decoded=await crypto.subtle.decrypt({name:'AES-GCM',iv:decode(body.nonce),additionalData:cryptoModule.canonical(['enroll',offer.hostID,offer.url])},key,decode(body.payload));
        const request=JSON.parse(new TextDecoder().decode(decoded));
        const fields=['enrolled',offer.hostID,request.peerID,request.publicKey,offer.url,'interactive','synthetic'];
        return {receipt:fields,signature:await cryptoModule.sign(fields,window.testIdentity.privateKey)};
      },body);
      if (delay) { const wait=new Promise(resolve=>releaseApproval=resolve); approvalStarted(); await wait; }
      await route.fulfill({json:response}).catch(()=>{});
    });
    await page.locator('#offer').fill(offer); await page.locator('#enroll').click(); await arrival;
    await page.locator('#forget').click(); releaseApproval();
    await page.waitForFunction(()=>document.querySelector('#status').textContent.includes('cleared'));
    assert.equal(await page.locator('#connect').isDisabled(),true);
    const count=await page.evaluate(async()=>{
      const db=await new Promise(resolve=>{const r=indexedDB.open('pocketdesk-browser-v1');r.onsuccess=()=>resolve(r.result)});
      return await new Promise(resolve=>{const r=db.transaction('browser').objectStore('browser').count();r.onsuccess=()=>{db.close();resolve(r.result)}});
    });
    assert.equal(count,0); console.log('PASS Forget during encrypted enrollment leaves no restored trust');
    delay=false; await page.locator('#offer').fill(offer); await page.locator('#enroll').click();
    await page.waitForFunction(()=>!document.querySelector('#connect').disabled);
    let releaseChallenge, challengeArrived;
    const challengeArrival=new Promise(resolve=>challengeArrived=resolve);
    let proofs=0,sockets=0;
    page.on('websocket',()=>sockets++);
    page.on('request',r=>{if(r.url().endsWith('/proof'))proofs++});
    await page.route('**/browser-api/*/challenge',async route=>{
      const wait=new Promise(resolve=>releaseChallenge=resolve); challengeArrived(); await wait;
      await route.fulfill({json:{fields:[],signature:''}}).catch(()=>{});
    });
    await page.locator('#connect').click(); await challengeArrival;
    assert.equal(await page.locator('#end').isDisabled(),false);
    await page.locator('#end').click(); releaseChallenge();
    await page.waitForFunction(()=>document.querySelector('#status').textContent.includes('Session ended'));
    await page.reload(); await page.waitForFunction(()=>!document.querySelector('#connect').disabled);
    assert.equal(proofs,0); assert.equal(sockets,0);
    assert.equal(await page.locator('#video').evaluate(v=>v.srcObject===null),true);
    console.log('PASS End during challenge aborts admission without proof or websocket resurrection');
    await page.locator('#forget').click(); await page.waitForFunction(()=>document.querySelector('#status').textContent.includes('cleared'));
    await page.reload(); await page.waitForFunction(()=>!document.querySelector('#enroll').disabled);
    assert.equal(await page.locator('#connect').isDisabled(),true);
    assert.deepEqual(errors,[]); console.log('PASS Reload preserves inert forgotten state; no page errors');
  } finally { await browser.close(); }
})().catch(error=>{console.error(error);process.exitCode=1});
