/* V04 · "Someone is controlling your Mac… it's you." Deadpan surveillance beat, then the trust line. */
V.define('v04', {
  dur: 12, fps: 30,
  build: function (V) {
    var L = V.LAND, S = this.S = {};
    S.D = L ? { x: 860, y: 190, w: 960, h: 600 } : { x: 60, y: 790, w: 960, h: 600 };
    S.PH = L ? { x: 900, y: 250, w: 880, h: 560, s: .82 } : { x: 150, y: 820, w: 780, h: 500, s: .74 };
    S.cv = V.canvas(0);
    S.F = FS.Field(S.cv, { cell: 12, dust: .05, seed: 404, plates: L ? [[90, 150, 780, 780, 60]] : [[0, 250, 1080, 520, 60]], twinkle: 2 * Math.PI * 2 / this.dur, scene: function (c, w, h, t) {
      if (S.thumb) { c.fillStyle = FS.Lc(.72); c.beginPath(); c.arc(S.thumb.x, S.thumb.y, 46, 0, 6.3); c.fill(); }
    } });
    S.phone = V.art('<div class="phone" style="position:absolute;inset:0;border-radius:84px;background:#070707"></div>', S.PH.x, S.PH.y, { width: S.PH.w + 'px', height: S.PH.h + 'px', zIndex: 3 });
    var d = S.D;
    S.desk = V.art(
      '<div class="mac" style="position:absolute;inset:0;border-radius:24px;background:radial-gradient(ellipse at 75% 10%,rgba(255,91,31,.12),transparent 55%),#0E0D0C">' +
      '<div style="position:absolute;left:0;right:0;top:0;height:40px;background:rgba(40,40,40,.85);display:flex;align-items:center;gap:22px;padding:0 20px;font:500 17px/1 var(--ui);color:#EDE8DF"><i style="width:14px;height:14px;border-radius:50%;background:#EDE8DF"></i><b style="font-weight:600">Notes</b><span style="color:#8C877F">File</span><span style="color:#8C877F">Edit</span><span style="margin-left:auto;display:flex;align-items:center;gap:10px;font:500 15px/1 var(--mono);letter-spacing:.14em;text-transform:uppercase"><i class="live" style="font-size:15px"></i>Live · Studio Mac</span></div>' +
      '<div style="position:absolute;left:30px;top:70px;width:470px;height:480px;border-radius:16px;background:#1A1A1C;box-shadow:0 0 0 1.5px rgba(255,255,255,.1)"><div style="height:40px;display:flex;align-items:center;gap:8px;padding:0 14px;border-bottom:1.5px solid rgba(255,255,255,.07)"><i style="width:11px;height:11px;border-radius:50%;background:#4A4742"></i><i style="width:11px;height:11px;border-radius:50%;background:#4A4742"></i><i style="width:11px;height:11px;border-radius:50%;background:#4A4742"></i></div>' +
      '<div style="padding:26px 28px;display:grid;gap:16px"><div style="font:600 30px/1.2 var(--ui);color:#EDE8DF">Groceries</div><div style="height:14px;width:62%;border-radius:7px;background:rgba(237,232,223,.16)"></div><div style="height:14px;width:48%;border-radius:7px;background:rgba(237,232,223,.16)"></div><div id="note" style="font:400 32px/1.3 var(--ui);color:#EDE8DF;min-height:42px"></div></div></div>' +
      '<div style="position:absolute;left:530px;top:110px;width:400px;height:420px;border-radius:16px;background:#1F1F21;box-shadow:0 0 0 1.5px rgba(255,255,255,.1)"><div style="height:40px;display:flex;align-items:center;gap:8px;padding:0 14px;border-bottom:1.5px solid rgba(255,255,255,.07)"><i style="width:11px;height:11px;border-radius:50%;background:#4A4742"></i><i style="width:11px;height:11px;border-radius:50%;background:#4A4742"></i><i style="width:11px;height:11px;border-radius:50%;background:#4A4742"></i><span style="margin-left:10px;font:500 14px var(--mono);letter-spacing:.1em;color:#8C877F;text-transform:uppercase">Movies</span></div>' +
      '<div style="padding:40px 0 0;display:grid;justify-items:center;gap:16px"><div style="width:110px;height:130px;border-radius:12px;background:#2B2B2E;box-shadow:inset 0 0 0 2px rgba(237,232,223,.2)"></div><div id="fname" style="font:500 26px/1.2 var(--ui);color:#EDE8DF;padding:6px 12px;border-radius:8px">Untitled.mov</div></div></div>' +
      '</div>', d.x, d.y, { width: d.w + 'px', height: d.h + 'px', transformOrigin: '0 0', zIndex: 4 });
    S.note = S.desk.querySelector('#note'); S.fname = S.desk.querySelector('#fname');
    S.ptrEl = V.art(FS.pointerSVG(84, { sw: 5.5 }), 0, 0, { zIndex: 7, filter: 'drop-shadow(0 6px 12px rgba(0,0,0,.6))' });
    S.rip = V.art('', 0, 0, { zIndex: 6 });
    var tx = L ? 110 : 80, tw = L ? 700 : 880;
    S.hook = V.text('<h1 class="vh1" style="font-size:' + (L ? 104 : 118) + 'px">' + V.lines(['Someone is', 'controlling', 'your Mac<span class="pd">…</span>']) + '</h1>', tx, L ? 250 : 300, tw);
    S.you = V.text('<p class="vser" style="font-size:' + (L ? 180 : 190) + 'px;line-height:.9">It’s you.</p><p class="vcap" style="font-size:30px;margin-top:22px">From <b>the couch</b></p>', tx, L ? 300 : 320, tw);
    S.trust = V.text('<p class="vsub" style="color:var(--bone);font-size:' + (L ? 50 : 54) + 'px;line-height:1.22">We only look while<br>a phone you approved<br>is connected<span class="ash">.</span></p><p class="vcap" style="font-size:26px;margin-top:30px">Control your Mac from <b>iPhone</b></p>', tx, L ? 290 : 320, tw);
    S.end = V.endCard(L ? { y: 140, markH: 190, foot: 'Free on the same Wi-Fi · no account' } : { y: 330, markH: 190, foot: 'Free on the same Wi-Fi · no account' });
  },
  frame: function (t) {
    var S = this.S, E = V.E, P = V.prog, L = V.LAND;
    var path = [[880, 560, 0], [250, 300, 1.2], [250, 300, 2.7], [690, 290, 3.35], [690, 290, 5.3], [610, 250, 6.4], [720, 300, 7.4], [880, 560, 11.9]];
    var px = path[0][0], py = path[0][1];
    for (var i = 1; i < path.length; i++) { if (t <= path[i][2]) { var a = path[i - 1], b = path[i], k = E.inOut(P(t, a[2], b[2])); px = V.lerp(a[0], b[0], k); py = V.lerp(a[1], b[1], k); break; } if (i === path.length - 1) { px = path[i][0]; py = path[i][1]; } }
    var z = t < 4.9 ? 0 : t < 5.7 ? E.primary(P(t, 4.9, 5.7)) : t < 11.3 ? 1 : 1 - E.inOut(P(t, 11.3, 11.95));
    var D = S.D, PH = S.PH, sc = V.lerp(1, PH.s, z);
    var cx = PH.x + (PH.w - D.w * PH.s) / 2, cy = PH.y + (PH.h - D.h * PH.s) / 2;
    var ox = V.lerp(D.x, cx, z), oy = V.lerp(D.y, cy, z);
    S.desk.style.transform = 'translate(' + (ox - D.x).toFixed(1) + 'px,' + (oy - D.y).toFixed(1) + 'px) scale(' + sc.toFixed(4) + ')';
    var sx = ox + px * sc, sy = oy + py * sc, off = FS.pointerTip(84, 5.5) * sc;
    S.ptrEl.style.transform = 'translate(' + (sx - off).toFixed(1) + 'px,' + (sy - off).toFixed(1) + 'px) scale(' + sc.toFixed(4) + ')';
    S.ptrEl.style.transformOrigin = '0 0';
    S.phone.style.opacity = z.toFixed(3);
    S.phone.style.transform = 'scale(' + (1.08 - .08 * z).toFixed(4) + ')';
    V.type(S.note, 'buy milk', t, 1.45, 7, t < 2.7);
    var renamed = t >= 3.55;
    var nm = renamed ? 'final final v2' : 'Untitled.mov';
    if (renamed) { var n = Math.min(nm.length, Math.floor((t - 3.7) * 11)); nm = n <= 0 ? '' : nm.slice(0, n); }
    S.fname.innerHTML = nm + (renamed && t < 4.9 ? '<span class="caret" style="margin-left:3px;height:.9em"></span>' : '');
    S.fname.style.boxShadow = renamed && t < 4.9 ? 'inset 0 0 0 2.5px rgba(237,232,223,.7)' : 'none';
    if (t > 11.3) { S.note.innerHTML = ''; S.fname.innerHTML = 'Untitled.mov'; S.fname.style.boxShadow = 'none'; }
    var clicks = [[1.2, 250, 300], [3.45, 690, 290], [6.4, 610, 250]], r = '';
    clicks.forEach(function (c) { var age = t - c[0]; if (age >= 0 && age < 1.0) { var x = ox + c[1] * sc, y = oy + c[2] * sc; r += '<circle cx="' + x.toFixed(1) + '" cy="' + y.toFixed(1) + '" r="' + (10 + age * 110).toFixed(1) + '" fill="none" stroke="#FF5B1F" stroke-width="' + (5 * (1 - age)).toFixed(2) + '" opacity="' + (1 - age).toFixed(2) + '"/>'; } });
    S.rip.innerHTML = r ? '<svg width="' + V.W + '" height="' + V.H + '" style="position:absolute;left:0;top:0">' + r + '</svg>' : '';
    S.thumb = z > .5 && t < 11.3 ? { x: PH.x + PH.w * .78 + (px - 690) * .25, y: PH.y + PH.h * .72 + (py - 290) * .25 } : null;
    S.F.draw(t, []);
    var dim = t < 9.6 ? 1 : t < 10.0 ? 1 - .78 * E.out(P(t, 9.6, 10.0)) : t < 11.3 ? .22 : .22 + .78 * E.inOut(P(t, 11.3, 11.95));
    [S.desk, S.ptrEl, S.cv, S.rip].forEach(function (e) { e.style.opacity = dim.toFixed(3); });
    S.phone.style.opacity = (z * dim).toFixed(3);
    if (t < 4.85) V.reveal(S.hook, t, -1, 4.85, { instant: true });
    else if (t > 11.55) V.reveal(S.hook, t, 11.55, 13, { stagger: .06, dur: .35 });
    else V.reveal(S.hook, t, -1, -.5);
    V.vis(S.you, t, 5.3, 7.5, { fi: .5 });
    V.vis(S.trust, t, 7.6, 9.6);
    S.end(t, 9.7, 11.5);
  }
});
