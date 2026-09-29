(function () {
'use strict';
var SK = window.SK, B = SK.B, W = SK.W, H = SK.H, root = SK.root, add = SK.add, field = SK.field;
var T = 10;

function raw(html) { root.insertAdjacentHTML('beforeend', html); return root.lastElementChild; }
function box(x, y, w, hh, html, cls, style) { var e = add(html || '', Object.assign({ left: x + 'px', top: y + 'px', width: w + 'px', height: hh == null ? 'auto' : hh + 'px' }, style || {}), cls); return e; }
function ring(x, y, R, s, w) { return { x: x, y: y, t0: T - R / 400, s: s == null ? .8 : s, v: 400, w: w || 12, life: R / 400 + 1 }; }
function header(label, o) {
  o = o || {};
  raw('<div class="hd"' + (o.center ? ' style="justify-content:center;gap:28px"' : '') + '>' + SK.brand(o.size || 34) + '<span class="cap">' + label + '</span></div>');
}
function footer(left, right) { raw('<div class="ft"><span class="cap">' + (left || '') + '</span><span class="cap">' + (right || '') + '</span></div>'); }
function reach(o) {
  var hdrPlate = [0, 0, W, 132, 18];
  return field({
    cell: o.cell || 10, dust: o.dust == null ? .05 : o.dust, seed: o.seed || 7, t: T, dustLum: o.dustLum,
    plates: [hdrPlate].concat(o.plates || []),
    ripples: (o.rings || []).map(function (r) { return ring(o.cx, o.cy, r[0], r[1], r[2]); }),
    scene: function (c, w, hh) {
      if (o.pre) o.pre(c, w, hh);
      if (o.cursor !== false) FS.drawCursor(c, o.cx + (o.cdx == null ? 5 : o.cdx), o.cy + (o.cdy == null ? 2 : o.cdy), o.cs || .6, o.ca || 0, !!o.frame);
      if (o.hand !== false) FS.drawHand(c, o.cx - 3, o.cy + 2, o.hs || .9, o.ha == null ? -.5 : o.ha);
      FS.glow(c, o.cx, o.cy, o.glow || 38, o.glowA == null ? .9 : o.glowA);
      if (o.post) o.post(c, w, hh);
    }
  });
}
function pointer(x, y, hh, o) { o = o || {}; return box(x, y, null, null, FS.pointerSVG(hh, o), '', { width: 'auto', filter: o.shadow === false ? 'none' : 'drop-shadow(0 10px 24px rgba(0,0,0,.6))' }); }
function phone(x, y, w, hh, inner) { var e = box(x, y, w, hh, inner || '', 'phone'); e.classList.remove('abs'); e.style.position = 'absolute'; return e; }
function winEl(x, y, w, hh, title, inner) { return box(x, y, w, hh, '<div class="tb"><i></i><i></i><i></i><span>' + (title || '') + '</span></div>' + (inner || ''), 'win'); }
function dotWave(n, hmax, gap, seed, color) {
  var R = FS.rng(seed || 4), s = '<div style="display:flex;align-items:center;gap:' + gap + 'px;height:' + hmax + 'px">';
  for (var i = 0; i < n; i++) {
    var env = Math.sin(Math.PI * (i + .5) / n), v = .18 + .82 * env * (.45 + .55 * R());
    var k = Math.max(1, Math.round(v * hmax / 16));
    s += '<div style="display:grid;gap:6px">';
    for (var j = 0; j < k; j++) s += '<i style="display:block;width:10px;height:10px;border-radius:50%;background:' + (color || '#EDE8DF') + '"></i>';
    s += '</div>';
  }
  return s + '</div>';
}
function dottedPath(pts, step, r, color, opacity) {
  var s = '', acc = 0;
  for (var i = 1; i < pts.length; i++) {
    var a = pts[i - 1], b = pts[i], L = Math.hypot(b[0] - a[0], b[1] - a[1]);
    for (var d = acc; d < L; d += step) { var k = d / L; s += '<circle cx="' + (a[0] + (b[0] - a[0]) * k).toFixed(1) + '" cy="' + (a[1] + (b[1] - a[1]) * k).toFixed(1) + '" r="' + r + '" fill="' + (color || '#EDE8DF') + '" opacity="' + (opacity || 1) + '"/>'; }
    acc = (acc + step - (L % step)) % step;
  }
  return s;
}
function svgLayer(inner, z) { var e = raw('<svg xmlns="http://www.w3.org/2000/svg" width="' + W + '" height="' + H + '" viewBox="0 0 ' + W + ' ' + H + '" style="position:absolute;left:0;top:0;z-index:' + (z || 4) + '">' + inner + '</svg>'); return e; }
function emberRing(x, y, radii, dotR, gapPx, opac) {
  var s = '';
  radii.forEach(function (R, i) { var n = Math.max(8, Math.round(2 * Math.PI * R / gapPx)); for (var k = 0; k < n; k++) { var a = k / n * Math.PI * 2; s += '<circle cx="' + (x + Math.cos(a) * R).toFixed(1) + '" cy="' + (y + Math.sin(a) * R).toFixed(1) + '" r="' + (dotR * (1 - i * .18)).toFixed(1) + '" fill="#FF5B1F" opacity="' + ((opac || 1) * (1 - i * .28)).toFixed(2) + '"/>'; } });
  return s;
}
function macCard(x, y, w, o) {
  o = o || {};
  return box(x, y, w, null,
    '<div style="padding:34px 36px 30px;display:grid;grid-template-columns:1fr auto;gap:22px;align-items:center">' +
    '<div><div style="font:600 46px/1.1 var(--ui);letter-spacing:-.02em">' + (o.name || 'Studio Mac') + '</div><div style="font:400 28px/1.35 var(--ui);color:var(--ash);margin-top:4px">' + (o.model || 'MacBook Pro · home office') + '</div>' +
    '<div style="display:flex;align-items:center;gap:14px;margin-top:22px;font:500 21px/1 var(--mono);letter-spacing:.12em;text-transform:uppercase">' + (o.live ? '<i class="live" style="font-size:22px"></i>' : '<i style="width:12px;height:12px;border-radius:50%;background:var(--dim);display:inline-block"></i>') + (o.status || 'Awake · home Wi-Fi') + '</div></div>' +
    '<div style="width:190px;height:122px;border-radius:16px;box-shadow:0 0 0 2px var(--line2);background:radial-gradient(circle,rgba(237,232,223,.55) 0 1.6px,transparent 2px) 0 0/8px 8px,#0B0B0B"></div>' +
    '<div style="grid-column:1/-1;display:flex;justify-content:space-between;border-top:1.5px solid var(--line);padding-top:22px;font:500 21px/1.2 var(--mono);letter-spacing:.1em;text-transform:uppercase;color:var(--ash)"><span>' + (o.metaL || 'Last reached 11:48 PM') + '</span><span style="color:var(--bone)">' + (o.metaR || 'We won’t ask why') + '</span></div></div>', 'card');
}
Object.assign(SK, { raw: raw, box: box, ring: ring, header: header, footer: footer, reach: reach, pointer: pointer, phone: phone, winEl: winEl, dotWave: dotWave, dottedPath: dottedPath, svgLayer: svgLayer, emberRing: emberRing, macCard: macCard, T: T });

/* P01 · Reach hero · IG 4:5 */
B['post-01'] = function () {
  reach({ cell: 11, cx: 590, cy: 520, hs: 1.62, ha: -.46, cs: 1.0, glow: 50, rings: [[150, .8, 15]], plates: [[0, 905, W, 445, 60], [40, 170, 250, 70, 20], [790, 170, 260, 70, 20]] });
  header('Reach · 01');
  raw('<p class="cap abs z5" style="left:64px;top:190px;font-size:22px">Phone <b>side</b></p><p class="cap abs z5" style="right:64px;top:190px;font-size:22px;text-align:right">Mac <b>side</b></p>');
  box(64, 948, 960, null, '<h1 class="h1" style="font-size:104px"><span class="ln">Your Mac is far<span class="pd">.</span></span><span class="ln">Your reach <span class="it">isn’t.</span></span></h1>');
  footer('Control your Mac from <b>iPhone</b>', 'Coming soon');
};

/* P02 · Big pointer energy · IG 1:1 */
B['post-02'] = function () {
  var tx = 470, ty = 330;
  field({ cell: 9, dust: .05, seed: 21, t: T, plates: [[0, 0, W, 120, 20], [0, 716, W, 364, 30]],
    ripples: [ring(tx, ty, 112, .8, 12), ring(tx, ty, 190, .45, 10)],
    scene: function (c) { FS.glow(c, tx, ty, 44, .95); } });
  header('Closes the gap · pointer', { center: true, size: 30 });
  pointer(tx, ty, 400, { tip: true, tipR: 6.5, sw: 4.6 });
  box(0, 726, W, null, '<h1 class="h1 center" style="font-size:108px;line-height:.96"><span class="ln">Big pointer</span><span class="ln"><span class="it" style="font-size:1.12em">energy.</span></span></h1>');
  box(0, 1000, W, null, '<p class="mono-l center" style="font-size:22px">Big, sharp, drawn right on your <b>phone</b></p>');
};

/* P03 · Voice dictation · IG 4:5 */
B['post-03'] = function () {
  header('Closes the gap · voice');
  box(64, 170, 952, null, '<h1 class="h1" style="font-size:98px"><span class="ln">Talk to your</span><span class="ln">phone<span class="pd">.</span></span></h1><p class="ser" style="font-size:74px;margin-top:18px">It types on your Mac.</p>');
  box(64, 560, 952, 170, '<div style="height:100%;display:grid;grid-template-columns:auto 1fr auto;align-items:center;gap:30px;padding:0 34px">' + SK.dotWave(13, 112, 14, 9) + '<div><div style="font:500 20px/1 var(--mono);letter-spacing:.14em;text-transform:uppercase;color:var(--bone);display:flex;align-items:center;gap:12px"><i class="live" style="font-size:20px"></i>Listening</div><div style="font:400 30px/1.3 var(--ui);color:var(--ash);margin-top:12px">Speak, then Done</div></div><span style="height:72px;padding:0 30px;border-radius:999px;background:var(--bone);color:#0A0A0A;font:600 30px/72px var(--ui)">Done</span></div>', 'card');
  svgLayer(SK.dottedPath([[540, 742], [540, 830]], 18, 4.5, '#EDE8DF', .75));
  var w = winEl(64, 850, 952, 250, 'Finder · rename');
  w.insertAdjacentHTML('beforeend', '<div style="padding:44px 40px;display:flex;align-items:center;gap:24px"><div style="width:86px;height:104px;border-radius:12px;background:#1E1E1E;box-shadow:inset 0 0 0 2px var(--line2);flex:none"></div><div style="flex:1;border-radius:12px;box-shadow:inset 0 0 0 3px rgba(237,232,223,.5);padding:20px 22px;font:500 40px/1 var(--ui);letter-spacing:-.01em">final final v2<span class="caret" style="margin-left:4px"></span></div></div>');
  footer('Voice dictation into your <b>Mac</b>', 'iPhone to Mac');
};

/* P04 · Clipboard both ways · X 16:9 */
B['post-04'] = function () {
  header('Closes the gap · clipboard');
  box(0, 150, W, null, '<h1 class="h1 center" style="font-size:96px">Copy here<span class="pd">.</span> Paste <span class="it">there.</span></h1>');
  phone(190, 320, 290, 470, '<div style="position:absolute;left:30px;right:30px;top:108px;display:grid;gap:18px"><div style="height:18px;border-radius:9px;background:rgba(237,232,223,.18)"></div><div style="height:18px;width:80%;border-radius:9px;background:rgba(237,232,223,.18)"></div><div style="display:flex;gap:10px;align-items:center"><div style="height:18px;width:24%;border-radius:9px;background:rgba(237,232,223,.18)"></div><span style="padding:8px 14px;border-radius:10px;background:rgba(237,232,223,.9);color:#0A0A0A;font:600 20px/1 var(--ui)">address.txt</span></div><div style="height:18px;width:64%;border-radius:9px;background:rgba(237,232,223,.18)"></div></div><div style="position:absolute;left:30px;right:30px;bottom:34px;height:72px;border-radius:999px;background:var(--bone);color:#0A0A0A;display:grid;place-items:center;font:600 30px var(--ui)">Copy</div>');
  var w = winEl(820, 330, 620, 400, 'Mail · new message');
  w.insertAdjacentHTML('beforeend', '<div style="padding:34px 36px;display:grid;gap:18px"><div style="font:400 24px/1 var(--ui);color:var(--ash)">To: <span style="color:var(--bone)">landlord</span></div><div style="height:1.5px;background:var(--line)"></div><div style="font:400 30px/1.3 var(--ui)">New address is<span class="caret" style="margin-left:6px"></span></div><div style="margin-top:34px;display:flex;justify-content:flex-end"><span id="pasteBtn" style="padding:16px 28px;border-radius:14px;background:rgba(237,232,223,.12);box-shadow:inset 0 0 0 2px var(--line2);font:600 28px/1 var(--ui)">Paste</span></div></div>');
  svgLayer(SK.dottedPath([[500, 500], [630, 440], [790, 450]], 20, 5) + SK.dottedPath([[790, 610], [650, 660], [500, 610]], 20, 5, '#8C877F') +
    '<path d="M776 438l20 12-20 12" fill="none" stroke="#EDE8DF" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><path d="M514 598l-20 12 20 12" fill="none" stroke="#8C877F" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/>' +
    SK.emberRing(1360, 588, [34, 54], 5, 16, .95));
  pointer(1356, 585, 92, { tip: true, tipR: 7, sw: 5.5 });
  footer('Clipboard works both ways', 'iPhone to Mac · Mac to iPhone');
};

/* P05 · Agent needs you (beta) · X 16:9 */
B['post-05'] = function () {
  header('Agent needs you · beta');
  box(96, 176, 700, null, '<h1 class="h1" style="font-size:104px"><span class="ln">Your agent</span><span class="ln">needs <span class="it">you.</span></span></h1><p class="sub" style="margin-top:28px;max-width:640px;font-size:36px">When your AI coding agent stops to ask a question, your phone taps you on the shoulder.</p>');
  box(96, 600, 700, 176, '<div class="ttl">agent · ~/farside</div><div class="dots"><i></i><i></i><i></i></div><div class="a">› run the test suite</div><div>Allow the agent to run tests<span class="a">?</span> <span class="a">[y/n]</span> <span class="caret"></span></div>', 'term');
  var nx = 900, ny = 330;
  svgLayer(SK.emberRing(nx + 64, ny + 64, [70, 108, 146], 6, 22, .9), 3);
  box(nx, ny, 600, null, '<div class="ic">' + FS.markSVG(40, { rows: FS.ARROW_S }) + '</div><div><small>farside · now</small><b>Your agent needs you</b><span>It wants to run tests. Tap to answer.</span></div>', 'notif');
  box(nx, ny + 196, 600, null, '<div style="display:flex;gap:16px"><span style="flex:1;height:78px;border-radius:20px;background:rgba(237,232,223,.1);box-shadow:inset 0 0 0 2px var(--line2);display:grid;place-items:center;font:600 30px var(--ui)">Deny</span><span style="flex:1;height:78px;border-radius:20px;background:var(--bone);color:#0A0A0A;display:grid;place-items:center;font:600 30px var(--ui)">Allow</span></div>');
  raw('<span class="tag abs z5" style="left:' + (nx + 440) + 'px;top:' + (ny - 70) + 'px;font-size:20px">Beta</span>');
  footer('For AI coding agents on your Mac', 'Beta');
};

/* P06 · The sign-up form (no account) · IG 1:1 */
B['post-06'] = function () {
  header('Closes the gap · pairing', { center: true, size: 30 });
  box(0, 150, W, null, '<h1 class="h2 center" style="font-size:90px">The sign<span class="pd">-</span>up form</h1>');
  var rows = [['Email', 'Not needed'], ['Password', 'Not needed'], ['Confirm password', 'Not needed'], ['Mother’s maiden name', 'Absolutely not']];
  box(135, 300, 810, null, '<div style="padding:18px 40px 30px">' + rows.map(function (r, i) {
    return '<div style="display:flex;justify-content:space-between;align-items:center;padding:22px 0;border-bottom:1.5px solid var(--line)"><span style="font:400 34px/1.2 var(--ui);color:var(--ash);text-decoration:line-through;text-decoration-thickness:3px;text-decoration-color:rgba(237,232,223,.55)">' + r[0] + '</span><span style="font:500 19px/1 var(--mono);letter-spacing:.14em;text-transform:uppercase;color:var(--bone)">' + r[1] + '</span></div>';
  }).join('') + '<div style="display:flex;align-items:center;gap:28px;padding-top:30px"><div style="flex:none;width:118px;height:118px;border-radius:18px;box-shadow:inset 0 0 0 2px rgba(237,232,223,.35);display:grid;place-items:center">' + FS.codeSVG(92, 7) + '</div><div><div style="font:600 38px/1.15 var(--ui);letter-spacing:-.015em">Scan the code on your Mac<span style="color:var(--ash)">.</span></div><div style="font:400 30px/1.3 var(--ui);color:var(--ash);margin-top:6px">Approve it. That’s the whole form.</div></div></div></div>', 'card');
  box(0, 986, W, null, '<p class="mono-l center" style="font-size:22px">QR pairing · <b>no account</b></p>');
};

/* P07 · Auto-follow zoom · X 16:9 */
B['post-07'] = function () {
  header('Closes the gap · zoom');
  box(96, 176, 700, null, '<h1 class="h1" style="font-size:108px"><span class="ln">Tiny button<span class="pd">?</span></span></h1><p class="ser" style="font-size:76px;margin-top:14px">The view follows you.</p><p class="sub" style="margin-top:34px;max-width:620px;font-size:36px">Zoom in and the view follows your pointer around the screen. <b>No panning around.</b></p>');
  var mx = 800, my = 470, mw = 250, mh = 156;
  box(mx, my, mw, mh, '', 'mac', { borderRadius: '14px' }).insertAdjacentHTML('beforeend', '<div style="position:absolute;left:14px;top:18px;width:110px;height:84px;border-radius:6px;background:#1A1A1A;box-shadow:inset 0 0 0 1.5px var(--line2)"></div><div style="position:absolute;left:104px;top:40px;width:120px;height:92px;border-radius:6px;background:#1E1E1E;box-shadow:inset 0 0 0 1.5px var(--line2)"></div><div style="position:absolute;left:176px;top:108px;width:32px;height:11px;border-radius:3px;background:rgba(237,232,223,.85)"></div>');
  raw('<p class="cap abs z5" style="left:' + mx + 'px;top:' + (my + mh + 18) + 'px;font-size:18px">Your whole Mac</p>');
  var vx = mx + 150, vy = my + 86, vw = 84, vh = 50;
  svgLayer('<rect x="' + (vx - 70) + '" y="' + (vy - 46) + '" width="' + vw + '" height="' + vh + '" rx="5" fill="none" stroke="#8C877F" stroke-width="2" stroke-dasharray="1 7" stroke-linecap="round" opacity=".5"/>' +
    '<rect x="' + (vx - 35) + '" y="' + (vy - 23) + '" width="' + vw + '" height="' + vh + '" rx="5" fill="none" stroke="#8C877F" stroke-width="2.5" stroke-dasharray="1 7" stroke-linecap="round" opacity=".75"/>' +
    '<rect x="' + vx + '" y="' + vy + '" width="' + vw + '" height="' + vh + '" rx="5" fill="none" stroke="#EDE8DF" stroke-width="3" stroke-dasharray="1 7" stroke-linecap="round"/>' +
    SK.dottedPath([[vx + vw + 6, vy + 10], [1080, 330]], 16, 3.5, '#EDE8DF', .6) + SK.dottedPath([[vx + vw + 6, vy + vh - 6], [1080, 700]], 16, 3.5, '#EDE8DF', .6), 6);
  var ph = phone(1090, 140, 400, 680, '');
  ph.insertAdjacentHTML('beforeend', '<div style="position:absolute;left:16px;right:16px;top:70px;bottom:18px;border-radius:12px 12px 46px 46px;overflow:hidden;background:#1C1C1C">' +
    '<div style="position:absolute;left:-40px;top:40px;width:330px;height:420px;border-radius:26px;background:#232323;box-shadow:inset 0 0 0 3px rgba(237,232,223,.16)"></div>' +
    '<div style="position:absolute;left:28px;top:96px;width:200px;height:22px;border-radius:11px;background:rgba(237,232,223,.2)"></div><div style="position:absolute;left:28px;top:140px;width:150px;height:22px;border-radius:11px;background:rgba(237,232,223,.2)"></div>' +
    '<div style="position:absolute;left:120px;top:330px;width:250px;height:96px;border-radius:22px;background:#EDE8DF;color:#0A0A0A;display:grid;place-items:center;font:600 42px var(--ui)">Export</div></div>');
  svgLayer(SK.emberRing(1444, 612, [26, 44], 5, 14, .95), 6);
  pointer(1440, 608, 170, { tip: true, tipR: 7, sw: 5 });
  footer('Auto-follow zoom', '');
};

/* P08 · Status line: last reached · IG 1:1 */
B['post-08'] = function () {
  header('Status line · 01', { center: true, size: 30 });
  box(0, 170, W, null, '<h1 class="h2 center" style="font-size:84px"><span style="display:block">No follow-up</span><span style="display:block">questions<span class="pd">.</span></span></h1>');
  SK.macCard(140, 420, 800, {});
  box(0, 930, W, null, '<p class="mono-l center" style="font-size:22px">Farside remembers when you last reached your Mac<br><b>That is all it remembers about it</b></p>');
};

/* P09 · 2019 dialog · IG 4:5 */
B['post-09'] = function () {
  header('Status line · 02');
  box(64, 164, 952, null, '<h1 class="h1" style="font-size:104px"><span class="ln">Answer it from</span><span class="ln">the <span class="it">couch.</span></span></h1>');
  field({ cell: 10, dust: 0, seed: 3, t: T, plates: [[0, 0, W, 420, 10]], ripples: [ring(300, 1076, 52, .7, 10)],
    scene: function (c) { c.fillStyle = FS.Lc(.5); c.beginPath(); c.arc(300, 1076, 40, 0, 6.3); c.fill(); FS.glow(c, 300, 1076, 20, .0); } });
  var d = box(100, 450, 880, null, '<div style="padding:52px 48px 44px"><b style="font-size:40px">Are you sure you’re sure?</b><p style="margin:16px 0 38px;font-size:29px">This dialog has been open since 2019.</p><div class="bt"><span style="height:76px;font-size:29px">No</span><span class="yes" style="height:76px;font-size:29px">Yes, I’m sure</span></div></div>', 'dlg');
  svgLayer(SK.emberRing(884, 694, [28, 46], 5, 14, 1), 6);
  pointer(880, 690, 124, { tip: true, tipR: 7, sw: 5.5 });
  raw('<p class="cap abs z5" style="left:208px;top:1146px;font-size:21px">Tap down here</p><p class="cap abs z5" style="left:700px;top:866px;font-size:21px;color:var(--ember)">Pointer’s already here</p>');
  box(430, 1010, 590, null, '<p class="sub" style="font-size:34px">The pointer is already on the button. <b>Tap anywhere and it clicks right there.</b></p>');
  footer('The whole screen is a trackpad', 'Status line · 02');
};

/* P10 · Built with agents · X 4:5 */
B['post-10'] = function () {
  header('Built with agents · 01');
  box(64, 170, 952, null, '<h1 class="h1" style="font-size:100px"><span class="ln">One human<span class="pd">.</span></span><span class="ln">A few <span class="it">agents.</span></span></h1>');
  box(64, 470, 952, 560, '<div class="ttl">build log · farside</div><div class="dots"><i></i><i></i><i></i></div>' +
    '<div style="display:grid;grid-template-columns:200px 1fr;row-gap:22px;font-size:32px;line-height:1.3;margin-top:18px">' +
    '<span class="a">agent</span><span>writes the code</span>' +
    '<span class="a">agent</span><span>writes the tests</span>' +
    '<span class="a">agent</span><span>reviews the other agents</span>' +
    '<span style="color:var(--bone)">human</span><span>decides, tests on a real iPhone, writes the jokes</span>' +
    '<span class="a">status</span><span>building in public <span class="caret"></span></span></div>', 'term');
  box(64, 1074, 952, null, '<p class="sub" style="font-size:36px">Farside is being built by one developer and a handful of AI coding agents. <b>Follow along.</b></p>');
  footer('Build in public', 'Built with agents · 01');
};

/* P11 · Free on your Wi-Fi · IG 4:5 */
B['post-11'] = function () {
  header('Plans');
  var cx = 540, cy = 640;
  var house = [[cx - 300, cy - 40], [cx, cy - 290], [cx + 300, cy - 40], [cx + 300, cy + 250], [cx - 300, cy + 250], [cx - 300, cy - 40]];
  svgLayer(SK.dottedPath(house, 26, 7, '#EDE8DF', .9) + SK.dottedPath([[cx - 150, cy + 90], [cx + 150, cy + 90]], 20, 5, '#8C877F') + '<circle cx="' + cx + '" cy="' + (cy + 90) + '" r="13" fill="#FF5B1F"/><circle cx="' + cx + '" cy="' + (cy + 90) + '" r="34" fill="none" stroke="#FF5B1F" stroke-width="3" stroke-dasharray="2 9" stroke-linecap="round"/>', 3);
  box(cx - 250, cy + 12, 90, 156, '', '', { borderRadius: '22px', boxShadow: 'inset 0 0 0 4px #EDE8DF' });
  box(cx + 120, cy + 30, 150, 104, '', '', { borderRadius: '12px', boxShadow: 'inset 0 0 0 4px #EDE8DF' });
  box(cx + 100, cy + 138, 190, 12, '', '', { borderRadius: '6px', background: '#EDE8DF' });
  box(64, 160, 952, null, '<h1 class="h1" style="font-size:118px"><span class="ln">Free at home<span class="pd">.</span></span></h1>');
  box(64, 960, 952, null, '<p class="ser" style="font-size:66px">Not a trial in a trench coat.</p><p class="sub" style="margin-top:24px;font-size:36px">Free when your iPhone and Mac share a Wi-Fi. <b>Away from home: the Anywhere plan is coming.</b></p>');
  footer('Same Wi-Fi · free', 'Anywhere plan · coming');
};

/* P12 · Please don't walk · X 16:9 */
B['post-12'] = function () {
  header('Status line · 03');
  box(96, 170, 760, null, '<h1 class="h1" style="font-size:96px"><span class="ln">Please don<span class="pd">’</span>t walk</span><span class="ln">back to your <span class="it">desk.</span></span></h1>');
  var rows = [['Couch to desk', '6 m', false], ['You, walking', '0 m', true]];
  box(96, 440, 1408, null, rows.map(function (r) {
    return '<div style="display:flex;justify-content:space-between;align-items:center;border-top:1.5px solid var(--line);padding:18px 0 14px"><span class="mono-l" style="font-size:28px">' + r[0] + '</span><span class="doto" style="font-size:104px;line-height:1">' + r[1].replace(' m', '') + '<span style="font:500 40px var(--mono);color:var(--ash);margin-left:18px">m</span></span></div>';
  }).join(''));
  footer('Control your Mac from <b>iPhone</b>', 'The couch approves');
};

/* P13 · Someone is controlling your Mac · X 4:5 */
B['post-13'] = function () {
  header('Status line · 04');
  box(64, 164, 952, null, '<h1 class="h1" style="font-size:92px"><span class="ln">Someone is</span><span class="ln">controlling</span><span class="ln">your Mac<span class="pd">…</span></span></h1>');
  var mx = 64, my = 520, mw = 952, mh = 520;
  var m = box(mx, my, mw, mh, '<div class="bar"><i></i><i></i><i></i><span style="margin-left:auto;display:flex;align-items:center;gap:12px;font:500 18px/1 var(--mono);letter-spacing:.14em;text-transform:uppercase;color:var(--bone)"><i class="live" style="font-size:18px"></i>Live · Studio Mac</span></div>', 'mac');
  m.insertAdjacentHTML('beforeend', '<div style="position:absolute;left:44px;top:84px;width:520px;height:360px;border-radius:14px;background:#161616;box-shadow:inset 0 0 0 1.5px var(--line2)"><div style="padding:30px 30px;display:grid;gap:18px"><div style="height:16px;width:70%;border-radius:8px;background:rgba(237,232,223,.16)"></div><div style="height:16px;width:90%;border-radius:8px;background:rgba(237,232,223,.16)"></div><div style="height:16px;width:54%;border-radius:8px;background:rgba(237,232,223,.16)"></div><div style="margin-top:14px;font:500 34px/1.2 var(--ui)">buy milk<span class="caret" style="margin-left:6px"></span></div></div></div><div style="position:absolute;left:610px;top:120px;width:300px;height:220px;border-radius:14px;background:#1B1B1B;box-shadow:inset 0 0 0 1.5px var(--line2)"></div>');
  svgLayer(SK.dottedPath([[mx + 880, my + 470], [mx + 760, my + 380], [mx + 600, my + 330]], 22, 4, '#8C877F', .8), 6);
  pointer(mx + 560, my + 300, 110, { tip: false, sw: 5.5 });
  box(64, 1086, 952, null, '<p class="ser" style="font-size:88px">It’s you.</p><p class="sub" style="margin-top:6px;font-size:32px">From the couch. We only look while a phone you approved is connected.</p>');
};

/* P14 · Feel the click · IG 1:1 */
B['post-14'] = function () {
  var tx = 520, ty = 520;
  field({ cell: 9, dust: .04, seed: 14, t: T, plates: [[0, 0, W, 330, 26], [0, 900, W, 180, 20]],
    ripples: [ring(tx, ty, 96, 1.1, 14), ring(tx, ty, 190, .75, 13), ring(tx, ty, 290, .42, 12)],
    scene: function (c) { FS.glow(c, tx, ty, 52, 1); } });
  header('Closes the gap · haptics', { center: true, size: 30 });
  box(0, 150, W, null, '<h1 class="h1 center" style="font-size:108px">Feel the <span class="it">click.</span></h1>');
  pointer(tx, ty, 260, { tip: true, tipR: 7, sw: 5 });
  box(0, 946, W, null, '<p class="mono-l center" style="font-size:24px">Tap anywhere · <b>your phone clicks back</b></p>');
};

/* P15 · Beta list · IG 4:5 */
B['post-15'] = function () {
  header('Beta list');
  var mk = box(0, 190, W, 420, '', '', { display: 'grid', placeItems: 'center' });
  mk.innerHTML = FS.markSVG(360, { tipR: .66, glow: 3.6, id: 9 });
  box(64, 680, 952, null, '<h1 class="h1" style="font-size:96px"><span class="ln">Beta seats for</span><span class="ln">people who refuse</span><span class="ln">to get <span class="it">up.</span></span></h1>');
  box(64, 1066, 952, null, '<div style="display:flex;align-items:center;justify-content:space-between;gap:24px"><p class="sub" style="font-size:34px;max-width:560px">Farside puts your Mac on your iPhone. <b>Free on the same Wi-Fi.</b></p><span class="pill" style="font-size:32px">Join the list <i>' + FS.arrowSVG(26, '#EDE8DF') + '</i></span></div>');
  footer('Link in bio', 'Control your Mac from <b>iPhone</b>');
};
})();
