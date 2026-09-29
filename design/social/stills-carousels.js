(function () {
'use strict';
var SK = window.SK, B = SK.B, W = SK.W, H = SK.H, add = SK.add, field = SK.field, box = SK.box, raw = SK.raw, T = SK.T;

function frame(n, total, series, o) {
  o = o || {};
  raw('<div class="hd">' + SK.brand(34) + '<span class="slide-no"><b>' + String(n).padStart(2, '0') + '</b> / ' + String(total).padStart(2, '0') + '</span></div>');
  var dots = '';
  for (var i = 1; i <= total; i++) dots += '<i style="display:inline-block;width:12px;height:12px;border-radius:50%;margin-right:10px;background:' + (i === n ? '#EDE8DF' : '#4A4742') + '"></i>';
  raw('<div class="ft"><span class="cap">' + series + '</span><span style="display:flex;align-items:center;gap:22px">' + (o.swipe ? '<span class="cap" style="color:var(--bone)">Swipe</span>' + FS.arrowSVG(24, '#EDE8DF') : '<span>' + dots + '</span>') + '</span></div>');
}
function num(n) { return '<div class="doto" style="font-size:64px;color:var(--ash);line-height:1">' + String(n).padStart(2, '0') + '</div>'; }
function miniDesk(w, hh, o) {
  o = o || {};
  var s = '<div style="position:absolute;inset:0;background:radial-gradient(ellipse at 70% 20%,rgba(255,91,31,.18),transparent 55%),#0E0D0C;overflow:hidden">';
  s += '<div style="position:absolute;left:0;right:0;top:0;height:' + (hh * .06) + 'px;background:rgba(40,40,40,.8)"></div>';
  s += '<div style="position:absolute;left:' + (w * .06) + 'px;top:' + (hh * .13) + 'px;width:' + (w * .55) + 'px;height:' + (hh * .62) + 'px;border-radius:' + (w * .02) + 'px;background:#1C1C20;box-shadow:0 0 0 1.5px rgba(255,255,255,.1)">';
  for (var i = 0; i < 7; i++) s += '<div style="margin:' + (hh * .035) + 'px ' + (w * .03) + 'px 0;height:' + (hh * .022) + 'px;width:' + (40 + (i * 37) % 55) + '%;border-radius:4px;background:' + (i % 3 === 0 ? 'rgba(255,122,178,.55)' : 'rgba(230,230,240,.35)') + '"></div>';
  s += '</div>';
  s += '<div style="position:absolute;left:' + (w * .5) + 'px;top:' + (hh * .22) + 'px;width:' + (w * .44) + 'px;height:' + (hh * .56) + 'px;border-radius:' + (w * .02) + 'px;background:#F4F2EE;box-shadow:0 10px 30px rgba(0,0,0,.5)">';
  s += '<div style="margin:' + (hh * .05) + 'px ' + (w * .03) + 'px 0;height:' + (hh * .04) + 'px;width:60%;border-radius:4px;background:#111"></div>';
  for (var j = 0; j < 3; j++) s += '<div style="margin:' + (hh * .03) + 'px ' + (w * .03) + 'px 0;height:' + (hh * .02) + 'px;width:' + (70 - j * 15) + '%;border-radius:4px;background:#C9C6C0"></div>';
  s += '<div style="margin:' + (hh * .05) + 'px ' + (w * .03) + 'px 0;width:' + (w * .14) + 'px;height:' + (hh * .07) + 'px;border-radius:' + (w * .012) + 'px;background:#111"></div></div>';
  s += '<div style="position:absolute;left:50%;bottom:' + (hh * .03) + 'px;transform:translateX(-50%);display:flex;gap:' + (w * .012) + 'px;padding:' + (w * .01) + 'px;border-radius:' + (w * .02) + 'px;background:rgba(60,60,60,.6)">';
  ['#5AC8FA', '#FFD35C', '#6EE7A8', '#FF8A7A', '#2A2A33', '#F2F2F7'].forEach(function (c) { s += '<i style="display:block;width:' + (w * .045) + 'px;height:' + (w * .045) + 'px;border-radius:' + (w * .012) + 'px;background:' + c + '"></i>'; });
  return s + '</div></div>';
}
function couchSVG(x, y, sc, color) {
  var p = [[0, 40], [0, 110], [260, 110], [260, 40], [230, 40], [230, 70], [30, 70], [30, 40], [0, 40]];
  var back = [[30, 70], [30, 0], [230, 0], [230, 70]];
  var legs = SK.dottedPath([[20, 110], [20, 132]], 10, 4 / sc, color) + SK.dottedPath([[240, 110], [240, 132]], 10, 4 / sc, color);
  return '<g transform="translate(' + x + ',' + y + ') scale(' + sc + ')">' + SK.dottedPath(p, 14, 5 / sc, color) + SK.dottedPath(back, 14, 5 / sc, color) + legs + '</g>';
}

/* ======================= C1 · iPhone as your Mac's trackpad (7) ======================= */
var C1 = 'What if your iPhone were your Mac’s trackpad';
B['c1-01'] = function () {
  SK.reach({ cell: 11, cx: 640, cy: 900, hs: 1.3, ha: -.5, cs: .8, glow: 44, rings: [[130, .8, 14]], plates: [[0, 130, W, 640, 40], [0, 1210, W, 140, 20]] });
  frame(1, 7, 'Swipe for the answer', { swipe: true });
  box(64, 170, 952, null, '<h1 class="h1" style="font-size:112px"><span class="ln">What if your</span><span class="ln">iPhone were</span><span class="ln">your Mac<span class="pd">’</span>s</span><span class="ln"><span class="it" style="font-size:1.14em">trackpad?</span></span></h1>');
};
B['c1-02'] = function () {
  frame(2, 7, C1);
  box(64, 170, 952, null, num(1) + '<h2 class="h1" style="font-size:100px;margin-top:22px"><span class="ln">Slide anywhere<span class="pd">.</span></span><span class="ln">The pointer <span class="it">moves.</span></span></h2>');
  SK.phone(96, 610, 360, 600, '');
  var mac = box(540, 690, 460, 300, '<div class="bar"><i></i><i></i><i></i></div>', 'mac');
  var path1 = [[170, 1080], [230, 980], [320, 930], [390, 820]];
  var path2 = [[620, 930], [700, 880], [800, 850], [880, 790]];
  SK.svgLayer(SK.dottedPath(path1, 22, 9, '#EDE8DF', .85) + SK.dottedPath(path2, 18, 5, '#8C877F', .9), 6);
  field({ cell: 10, dust: 0, seed: 2, t: T, bg: false, z: 5, scene: function (c) { c.fillStyle = FS.Lc(.75); c.beginPath(); c.arc(395, 812, 34, 0, 6.3); c.fill(); } });
  SK.pointer(882, 786, 96, { tip: false, sw: 5.5 });
  raw('<p class="cap abs z5" style="left:96px;top:1224px;width:360px;text-align:center;font-size:20px">Your thumb</p><p class="cap abs z5" style="left:540px;top:1004px;width:460px;text-align:center;font-size:20px">Your Mac</p>');
};
B['c1-03'] = function () {
  var tx = 690, ty = 640;
  field({ cell: 10, dust: .04, seed: 31, t: T, plates: [[0, 0, W, 440, 30], [0, 1030, W, 320, 30]], ripples: [SK.ring(tx, ty, 100, 1.1, 14), SK.ring(tx, ty, 200, .7, 13)],
    scene: function (c) { FS.glow(c, tx, ty, 50, 1); c.fillStyle = FS.Lc(.7); c.beginPath(); c.arc(250, 900, 38, 0, 6.3); c.fill(); } });
  frame(3, 7, C1);
  box(64, 170, 952, null, num(2) + '<h2 class="h1" style="font-size:100px;margin-top:22px"><span class="ln">Tap anywhere<span class="pd">.</span></span><span class="ln">It <span class="it">clicks.</span></span></h2>');
  SK.pointer(tx, ty, 220, { tip: true, tipR: 7, sw: 5 });
  raw('<p class="cap abs z5" style="left:160px;top:960px;font-size:20px">Tap here</p><p class="cap abs z5" style="left:' + (tx + 40) + 'px;top:' + (ty + 250) + 'px;font-size:20px;color:var(--ember)">It clicks there</p>');
  box(64, 1070, 952, null, '<p class="sub" style="font-size:38px">The pointer is already where you want it. Tap anywhere on the glass and <b>your phone clicks back.</b></p>');
};
B['c1-04'] = function () {
  frame(4, 7, C1);
  box(64, 170, 952, null, num(3) + '<h2 class="h1" style="font-size:100px;margin-top:22px"><span class="ln">The pointer is</span><span class="ln">big<span class="pd">.</span> And <span class="it">sharp.</span></span></h2>');
  var y0 = 640;
  box(96, y0, 380, 440, '', 'card');
  box(540, y0, 444, 440, '', 'card');
  SK.pointer(270, y0 + 190, 34, { tip: false, sw: 6, shadow: false });
  SK.pointer(660, y0 + 60, 300, { tip: true, tipR: 7, sw: 5 });
  raw('<p class="cap abs z5" style="left:96px;top:' + (y0 + 470) + 'px;width:380px;text-align:center;font-size:20px">A Mac pointer, shrunk</p><p class="cap abs z5" style="left:540px;top:' + (y0 + 470) + 'px;width:444px;text-align:center;font-size:20px">The Farside pointer</p>');
};
B['c1-05'] = function () {
  frame(5, 7, C1);
  box(64, 170, 952, null, num(4) + '<h2 class="h1" style="font-size:100px;margin-top:22px"><span class="ln">Zoom in<span class="pd">.</span></span><span class="ln">The view <span class="it">follows.</span></span></h2>');
  var ph = SK.phone(290, 600, 500, 620, '');
  ph.insertAdjacentHTML('beforeend', '<div style="position:absolute;left:18px;right:18px;top:70px;bottom:18px;border-radius:12px 12px 48px 48px;overflow:hidden;background:#1C1C1C"><div style="position:absolute;left:30px;top:60px;width:330px;height:26px;border-radius:13px;background:rgba(237,232,223,.2)"></div><div style="position:absolute;left:30px;top:110px;width:250px;height:26px;border-radius:13px;background:rgba(237,232,223,.2)"></div><div style="position:absolute;left:120px;top:300px;width:280px;height:104px;border-radius:24px;background:#EDE8DF;color:#0A0A0A;display:grid;place-items:center;font:600 46px var(--ui)">Save</div></div>');
  SK.svgLayer(SK.emberRing(650, 960, [28, 46], 5, 14, .95), 6);
  SK.pointer(646, 956, 170, { tip: true, tipR: 7, sw: 5 });
};
B['c1-06'] = function () {
  frame(6, 7, C1);
  box(64, 170, 952, null, num(5) + '<h2 class="h1" style="font-size:96px;margin-top:22px"><span class="ln">Your Mac stays</span><span class="ln">put<span class="pd">.</span> You stay on</span><span class="ln">the <span class="it">couch.</span></span></h2>');
  SK.svgLayer(couchSVG(96, 820, 1.2, '#EDE8DF') + SK.dottedPath([[440, 900], [700, 900]], 22, 5, '#8C877F') + '<circle cx="570" cy="900" r="12" fill="#FF5B1F"/><circle cx="570" cy="900" r="32" fill="none" stroke="#FF5B1F" stroke-width="3" stroke-dasharray="2 9" stroke-linecap="round"/>', 4);
  box(730, 800, 250, 170, '', '', { borderRadius: '14px', boxShadow: 'inset 0 0 0 5px #EDE8DF' });
  box(700, 980, 310, 14, '', '', { borderRadius: '7px', background: '#EDE8DF' });
  raw('<p class="cap abs z5" style="left:96px;top:1010px;width:312px;text-align:center;font-size:20px">You</p><p class="cap abs z5" style="left:700px;top:1030px;width:310px;text-align:center;font-size:20px">Your Mac</p>');
  box(64, 1100, 952, null, '<p class="sub" style="font-size:36px">Free when your iPhone and Mac share a Wi-Fi. <b>Farther than that: the Anywhere plan is coming.</b></p>');
};
B['c1-07'] = function () {
  frame(7, 7, C1);
  var mk = box(0, 170, W, 380, '', '', { display: 'grid', placeItems: 'center' });
  mk.innerHTML = FS.markSVG(330, { tipR: .66, glow: 3.6, id: 3 });
  box(64, 600, 952, null, '<h2 class="h1 center" style="font-size:132px">farside</h2><p class="lede center" style="margin-top:20px;font-size:50px">Control your Mac from <span class="it">iPhone.</span></p>');
  box(64, 900, 952, null, '<div style="display:flex;flex-wrap:wrap;justify-content:center;gap:16px"><span class="tag" style="font-size:20px">Free on the same Wi-Fi</span><span class="tag" style="font-size:20px">No account</span><span class="tag" style="font-size:20px">Anywhere plan · coming</span></div><div style="display:flex;justify-content:center;margin-top:52px"><span class="pill" style="font-size:36px">Join the beta list <i>' + FS.arrowSVG(28, '#EDE8DF') + '</i></span></div><p class="mono-l center" style="margin-top:30px;font-size:22px">Link in bio</p>');
};

/* ======================= C2 · 5 things from the couch (7) ======================= */
var C2 = '5 things you can do from the couch';
function thing(n, title, sub) {
  frame(n + 1, 7, C2);
  box(64, 170, 952, null, num(n) + '<h2 class="h2" style="font-size:78px;margin-top:22px">' + title + '</h2>' + (sub ? '<p class="sub" style="margin-top:22px;font-size:36px">' + sub + '</p>' : ''));
}
B['c2-01'] = function () {
  SK.svgLayer(couchSVG(160, 900, 2.9, '#EDE8DF'), 2);
  field({ cell: 11, dust: .05, seed: 8, t: T, z: 1, plates: [[0, 0, W, 860, 30]] });
  frame(1, 7, 'Swipe', { swipe: true });
  box(64, 150, 952, null, '<div class="doto" style="font-size:330px;line-height:.9">5</div><h1 class="h1" style="font-size:104px;margin-top:10px"><span class="ln">things you can</span><span class="ln">do from the</span><span class="ln"><span class="it" style="font-size:1.14em">couch.</span></span></h1>');
  box(64, 790, 952, null, '<p class="mono-l" style="font-size:22px">Without getting up · <b>that is the whole list</b></p>');
};
B['c2-02'] = function () {
  thing(1, 'Click the button your Mac has been waiting on');
  box(110, 640, 860, null, '<div style="padding:50px 48px 42px"><b style="font-size:40px">Are you sure you’re sure?</b><p style="margin:16px 0 38px;font-size:29px">This dialog has been open since 2019.</p><div class="bt"><span style="height:76px;font-size:29px">No</span><span class="yes" style="height:76px;font-size:29px">Yes, I’m sure</span></div></div>', 'dlg');
  SK.svgLayer(SK.emberRing(890, 880, [28, 46], 5, 14, 1), 6);
  SK.pointer(886, 876, 124, { tip: true, tipR: 7, sw: 5.5 });
  box(110, 1100, 860, null, '<p class="ser" style="font-size:64px">Thank you. It needed that.</p>');
};
B['c2-03'] = function () {
  thing(2, 'Dictate the reply<span class="pd">.</span> It types on your Mac<span class="pd">.</span>');
  box(64, 640, 952, 160, '<div style="height:100%;display:grid;grid-template-columns:auto 1fr auto;align-items:center;gap:30px;padding:0 34px">' + SK.dotWave(13, 104, 14, 5) + '<div><div style="font:500 20px/1 var(--mono);letter-spacing:.14em;text-transform:uppercase;display:flex;align-items:center;gap:12px"><i class="live" style="font-size:20px"></i>Listening</div><div style="font:400 30px/1.3 var(--ui);color:var(--ash);margin-top:12px">Speak, then Done</div></div><span style="height:72px;padding:0 30px;border-radius:999px;background:var(--bone);color:#0A0A0A;font:600 30px/72px var(--ui)">Done</span></div>', 'card');
  SK.svgLayer(SK.dottedPath([[540, 812], [540, 880]], 18, 4.5, '#EDE8DF', .75));
  var w = SK.winEl(64, 900, 952, 280, 'Messages');
  w.insertAdjacentHTML('beforeend', '<div style="padding:40px 40px;display:grid;gap:22px"><div style="justify-self:start;max-width:70%;padding:18px 24px;border-radius:26px;background:#2A2A2A;font:400 32px/1.3 var(--ui)">Dinner at 7?</div><div style="justify-self:end;max-width:78%;padding:18px 24px;border-radius:26px;background:#EDE8DF;color:#0A0A0A;font:400 32px/1.3 var(--ui)">Sounds good, see you at 7<span class="caret" style="background:#0A0A0A;margin-left:4px"></span></div></div>');
};
B['c2-04'] = function () {
  thing(3, 'Copy on the Mac<span class="pd">.</span> Paste on your phone<span class="pd">.</span>');
  var w = SK.winEl(64, 640, 560, 330, 'Notes');
  w.insertAdjacentHTML('beforeend', '<div style="padding:34px 34px;display:grid;gap:18px"><div style="font:400 30px/1.3 var(--ui)">Wi-Fi password for guests:</div><div style="font:500 32px/1.3 var(--mono);background:rgba(237,232,223,.9);color:#0A0A0A;padding:8px 14px;border-radius:8px;justify-self:start">correct-horse-battery</div><div style="margin-top:8px;font:500 18px/1 var(--mono);letter-spacing:.14em;text-transform:uppercase;color:var(--ash)">⌘C · copied</div></div>');
  SK.phone(690, 600, 320, 560, '<div style="position:absolute;left:28px;right:28px;top:120px;display:grid;gap:18px"><div style="height:18px;border-radius:9px;background:rgba(237,232,223,.18)"></div><div style="height:18px;width:70%;border-radius:9px;background:rgba(237,232,223,.18)"></div></div><div style="position:absolute;left:28px;right:28px;bottom:120px;padding:18px;border-radius:18px;box-shadow:inset 0 0 0 2px var(--line2);font:500 22px/1.3 var(--mono)">correct-horse-battery</div><div style="position:absolute;left:28px;right:28px;bottom:36px;height:66px;border-radius:999px;background:var(--bone);color:#0A0A0A;display:grid;place-items:center;font:600 28px var(--ui)">Paste</div>');
  SK.svgLayer(SK.dottedPath([[630, 800], [680, 800]], 14, 5) + '<path d="M668 788l14 12-14 12" fill="none" stroke="#EDE8DF" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/>');
  box(64, 1210, 952, null, '<p class="mono-l" style="font-size:22px">Clipboard works <b>both ways</b></p>');
};
B['c2-05'] = function () {
  thing(4, 'Answer your AI agent', 'When your coding agent stops to ask, your phone taps you. <b>Agent needs you · beta.</b>');
  var nx = 140, ny = 720;
  SK.svgLayer(SK.emberRing(nx + 64, ny + 64, [70, 108, 146], 6, 22, .9), 3);
  box(nx, ny, 800, null, '<div class="ic">' + FS.markSVG(40, { rows: FS.ARROW_S }) + '</div><div><small>farside · now</small><b>Your agent needs you</b><span>It wants to run tests. Tap to answer.</span></div>', 'notif');
  box(nx, ny + 196, 800, null, '<div style="display:flex;gap:16px"><span style="flex:1;height:82px;border-radius:20px;background:rgba(237,232,223,.1);box-shadow:inset 0 0 0 2px var(--line2);display:grid;place-items:center;font:600 32px var(--ui)">Deny</span><span style="flex:1;height:82px;border-radius:20px;background:var(--bone);color:#0A0A0A;display:grid;place-items:center;font:600 32px var(--ui)">Allow</span></div>');
  raw('<span class="tag abs z5" style="left:' + (nx + 660) + 'px;top:' + (ny - 70) + 'px;font-size:20px">Beta</span>');
};
B['c2-06'] = function () {
  thing(5, 'Read the tiny text<span class="pd">.</span> The view follows<span class="pd">.</span>');
  var ph = SK.phone(200, 600, 680, 620, '');
  ph.insertAdjacentHTML('beforeend', '<div style="position:absolute;left:18px;right:18px;top:70px;bottom:18px;border-radius:12px 12px 48px 48px;overflow:hidden;background:#F4F2EE;color:#111;padding:44px 40px;font:400 40px/1.45 var(--ui)"><div style="font:600 30px/1 var(--mono);letter-spacing:.1em;color:#777;text-transform:uppercase">Terms, page 47</div><p style="margin-top:22px">By clicking Accept you agree that the tiny text was, in fact, readable<span style="background:#111;color:#F4F2EE;padding:0 6px;margin-left:4px">Accept</span></p></div>');
  SK.svgLayer(SK.emberRing(760, 1016, [26, 42], 5, 13, .95), 6);
  SK.pointer(756, 1012, 150, { tip: true, tipR: 7, sw: 5 });
};
B['c2-07'] = function () {
  frame(7, 7, C2);
  SK.svgLayer(couchSVG(250, 330, 2.2, '#8C877F'), 2);
  box(64, 690, 952, null, '<h2 class="h1" style="font-size:108px"><span class="ln">Free on the</span><span class="ln">same Wi<span class="pd">-</span>Fi<span class="pd">.</span></span></h2><p class="ser" style="font-size:78px;margin-top:10px">The couch approves.</p>');
  box(64, 1080, 952, null, '<div style="display:flex;align-items:center;justify-content:space-between"><p class="sub" style="font-size:32px">Anywhere plan · coming</p><span class="pill" style="font-size:34px">Beta list in bio <i>' + FS.arrowSVG(26, '#EDE8DF') + '</i></span></div>');
};

/* ======================= C3 · How Farside works in 3 taps (6) ======================= */
var C3 = 'How Farside works in 3 taps';
function tapDots(x, y, active) {
  var s = '';
  for (var i = 0; i < 3; i++) {
    var cx = x + i * 150, on = i < active, cur = i === active - 1;
    s += '<circle cx="' + cx + '" cy="' + y + '" r="' + (cur ? 26 : 20) + '" fill="' + (on ? (cur && active === 3 ? '#FF5B1F' : '#EDE8DF') : 'none') + '" stroke="' + (on ? 'none' : '#4A4742') + '" stroke-width="4"/>';
    if (i < 2) s += SK.dottedPath([[cx + 40, y], [cx + 110, y]], 16, 4, on && i < active - 1 ? '#EDE8DF' : '#4A4742');
  }
  return s;
}
B['c3-01'] = function () {
  frame(1, 6, 'Swipe', { swipe: true });
  box(64, 190, 952, null, '<h1 class="h1" style="font-size:128px"><span class="ln">How Farside</span><span class="ln">works in</span><span class="ln">3 <span class="it" style="font-size:1.12em">taps.</span></span></h1>');
  SK.svgLayer(tapDots(240, 900, 3) + SK.emberRing(540, 900, [52, 84], 5, 15, .9));
  raw('<p class="cap abs z5" style="left:170px;top:1004px;width:140px;text-align:center;font-size:20px">Scan</p><p class="cap abs z5" style="left:320px;top:1004px;width:140px;text-align:center;font-size:20px">Approve</p><p class="cap abs z5" style="left:470px;top:1004px;width:140px;text-align:center;font-size:20px;color:var(--bone)">Connect</p>');
  box(64, 1110, 952, null, '<p class="sub" style="font-size:36px">No account. No router settings. <b>About as long as finding your charger.</b></p>');
};
B['c3-02'] = function () {
  frame(2, 6, C3);
  box(64, 170, 952, null, '<div class="mono-l" style="font-size:24px"><b>Tap 1</b></div><h2 class="h1" style="font-size:104px;margin-top:18px"><span class="ln">Scan the code</span><span class="ln">on your <span class="it">Mac.</span></span></h2>');
  var m = box(96, 560, 620, 420, '<div class="bar"><i></i><i></i><i></i><span style="margin-left:auto;font:500 16px/1 var(--mono);letter-spacing:.12em;text-transform:uppercase;color:var(--ash)">Farside · Pair a phone</span></div>', 'mac');
  m.insertAdjacentHTML('beforeend', '<div style="position:absolute;left:0;right:0;top:40px;bottom:0;display:grid;place-items:center">' + FS.codeSVG(290, 11) + '</div>');
  var ph = SK.phone(640, 700, 340, 520, '');
  ph.insertAdjacentHTML('beforeend', '<div style="position:absolute;left:18px;right:18px;top:70px;bottom:18px;border-radius:12px 12px 44px 44px;overflow:hidden;background:#101010"><div style="position:absolute;left:50%;top:50%;width:200px;height:200px;margin:-100px 0 0 -100px">' + ['0 0', '100% 0', '0 100%', '100% 100%'].map(function (p, i) { var bx = i % 2 ? 'right:0' : 'left:0', by = i > 1 ? 'bottom:0' : 'top:0'; return '<i style="position:absolute;' + bx + ';' + by + ';width:44px;height:44px;border-' + (i > 1 ? 'bottom' : 'top') + ':6px solid #EDE8DF;border-' + (i % 2 ? 'right' : 'left') + ':6px solid #EDE8DF;border-radius:6px"></i>'; }).join('') + '</div><div style="position:absolute;left:0;right:0;bottom:40px;text-align:center;font:500 18px/1 var(--mono);letter-spacing:.14em;text-transform:uppercase;color:var(--ash)">Point at the code</div></div>');
  box(96, 1000, 500, null, '<p class="mono-l" style="font-size:21px">The Farside helper<br>on your Mac shows the code<br><b>It lives in the menu bar</b></p>');
};
B['c3-03'] = function () {
  frame(3, 6, C3);
  box(64, 170, 952, null, '<div class="mono-l" style="font-size:24px"><b>Tap 2</b></div><h2 class="h1" style="font-size:104px;margin-top:18px"><span class="ln">Approve it on</span><span class="ln">the <span class="it">Mac.</span></span></h2>');
  box(140, 590, 800, null, '<div style="padding:48px 46px 42px"><div style="width:84px;height:84px;margin:0 auto 22px;border-radius:20px;background:#050505;display:grid;place-items:center">' + FS.markSVG(50, { rows: FS.ARROW_S }) + '</div><b style="font-size:38px">Allow “Sam’s iPhone” to connect?</b><p style="margin:14px 0 36px;font-size:28px">It will see and control this Mac while connected.</p><div class="bt"><span style="height:76px;font-size:29px">Don’t Allow</span><span class="yes" style="height:76px;font-size:29px">Allow</span></div></div>', 'dlg');
  SK.svgLayer(SK.emberRing(808, 934, [26, 44], 5, 14, 1), 6);
  SK.pointer(804, 930, 110, { tip: true, tipR: 7, sw: 5.5 });
  box(64, 1150, 952, null, '<p class="ser" style="font-size:54px">Technically a click. We’re counting it.</p>');
};
B['c3-04'] = function () {
  frame(4, 6, C3);
  box(64, 170, 952, null, '<div class="mono-l" style="font-size:24px"><b>Tap 3</b></div><h2 class="h1" style="font-size:104px;margin-top:18px"><span class="ln">Connect<span class="pd">.</span></span></h2>');
  SK.macCard(96, 460, 888, { status: 'Awake · home Wi-Fi', metaL: 'Paired · just now', metaR: 'Ready when you are' });
  box(96, 900, 888, 150, '<div style="height:100%;display:flex;align-items:center;justify-content:space-between;padding:0 16px 0 52px;border-radius:999px;background:var(--bone);color:#0A0A0A;box-shadow:0 0 70px rgba(237,232,223,.16)"><span><b style="display:block;font:600 52px/1.1 var(--ui);letter-spacing:-.02em">Connect</b><small style="display:block;font:500 20px/1.2 var(--mono);letter-spacing:.14em;text-transform:uppercase;color:#6A6660;margin-top:6px">Closes the gap</small></span><i style="width:118px;height:118px;border-radius:50%;background:#FF5B1F;display:grid;place-items:center">' + FS.arrowSVG(40, '#050505') + '</i></div>');
  SK.svgLayer(SK.emberRing(915, 975, [80, 104], 5, 16, .9), 4);
  box(64, 1110, 952, null, '<p class="sub" style="font-size:36px">One big button. <b>The whole screen becomes a trackpad.</b></p>');
};
B['c3-05'] = function () {
  frame(5, 6, C3);
  box(64, 170, 952, null, '<h2 class="h1" style="font-size:112px"><span class="ln">That<span class="pd">’</span>s it<span class="pd">.</span></span></h2><p class="ser" style="font-size:62px;margin-top:10px">Your Mac, on your iPhone.</p>');
  var ph = SK.phone(90, 480, 900, 640, '');
  ph.style.borderRadius = '72px';
  ph.insertAdjacentHTML('beforeend', '<div style="position:absolute;left:22px;right:22px;top:22px;bottom:22px;border-radius:52px;overflow:hidden">' + miniDesk(856, 596) + '</div>');
  SK.svgLayer(SK.emberRing(640, 790, [24, 40], 5, 13, 1), 6);
  SK.pointer(636, 786, 110, { tip: true, tipR: 7, sw: 5 });
  box(64, 1150, 952, null, '<p class="mono-l" style="font-size:22px">Slide to point · tap to click · <b>free on the same Wi-Fi</b></p>');
};
B['c3-06'] = function () {
  frame(6, 6, C3);
  var mk = box(0, 180, W, 360, '', '', { display: 'grid', placeItems: 'center' });
  mk.innerHTML = FS.markSVG(300, { tipR: .66, glow: 3.6, id: 5 });
  box(64, 590, 952, null, '<h2 class="h1 center" style="font-size:112px"><span class="ln">Scan<span class="pd">.</span> Approve<span class="pd">.</span></span><span class="ln"><span class="it">Connected.</span></span></h2>');
  box(64, 930, 952, null, '<div style="display:flex;flex-wrap:wrap;justify-content:center;gap:16px"><span class="tag" style="font-size:20px">No account</span><span class="tag" style="font-size:20px">Free on the same Wi-Fi</span><span class="tag" style="font-size:20px">Anywhere plan · coming</span></div><div style="display:flex;justify-content:center;margin-top:52px"><span class="pill" style="font-size:36px">Join the beta list <i>' + FS.arrowSVG(28, '#EDE8DF') + '</i></span></div><p class="mono-l center" style="margin-top:30px;font-size:22px">Link in bio</p>');
};
})();
