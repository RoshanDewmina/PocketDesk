/* V02 · POV: your Mac is at home and you're on the train. The Anywhere plan is labelled as coming throughout. */
V.define('v02', {
  dur: 15, fps: 30,
  build: function (V) {
    var S = this.S = {}, dur = this.dur, R = FS.rng(42);
    S.streaks = [];
    for (var i = 0; i < 26; i++) {
      var P = 1080 + 700, k = 1 + Math.floor(R() * 3);
      S.streaks.push({ y: 850 + R() * 250, x0: R() * P, v: k * P / dur, len: 90 + R() * 380, lum: .22 + R() * .7, P: P, w: 3 + R() * 7 });
    }
    S.cv = V.canvas(0);
    S.F = FS.Field(S.cv, { cell: 12, dust: .04, seed: 202, twinkle: 2 * Math.PI * 3 / dur, plates: [[0, 250, 1080, 560, 70]], scene: function (c, w, h, t) {
      c.lineCap = 'round';
      S.streaks.forEach(function (s) { var x = ((s.x0 - s.v * t) % s.P + s.P) % s.P - 350; c.strokeStyle = FS.Lc(s.lum); c.lineWidth = s.w; c.beginPath(); c.moveTo(x, s.y); c.lineTo(x + s.len, s.y); c.stroke(); });
      c.strokeStyle = FS.Lc(.2); c.lineWidth = 5; c.beginPath(); c.moveTo(0, 818); c.lineTo(1080, 818); c.moveTo(0, 1128); c.lineTo(1080, 1128); c.stroke();
      if (S.touch) { c.fillStyle = FS.Lc(.75); c.beginPath(); c.arc(S.touch.x, S.touch.y, 44, 0, 6.3); c.fill(); }
      if (S.glow > 0) FS.glow(c, S.ptr.x, S.ptr.y, 40, S.glow);
    } });
    S.chip = V.text('<span class="tag nowrap" style="font-size:21px">Anywhere plan · coming</span>', 520, 278, 440, '', { textAlign: 'right' });
    S.hook = V.text('<h1 class="vh1" style="font-size:190px;line-height:.9">' + V.lines(['POV']) + '</h1><p class="vsub" style="color:var(--bone);font-size:54px;margin-top:26px">your Mac is at home<br>and you’re on the train<span class="ash">.</span></p>', 80, 330, 880);
    S.t2 = V.text('<h1 class="vh1" style="font-size:118px">' + V.lines(['You forgot', 'to hit Export']) + '</h1>', 80, 350, 880);
    S.t3 = V.text('<h1 class="vh1" style="font-size:136px">' + V.lines(['Exported']) + '</h1><p class="vser" style="font-size:84px;margin-top:14px">from seat 14B.</p>', 80, 350, 880);
    S.t4 = V.text('<h1 class="vh1" style="font-size:118px">' + V.lines(['Your Mac', 'is far<span class="pd">.</span>', 'Your reach', '<span class="it">isn’t.</span>']) + '</h1>', 80, 340, 880);
    S.t5 = V.text('<h1 class="vh2" style="font-size:92px">' + V.lines(['Away from home', 'needs the', 'Anywhere plan']) + '</h1><p class="vsub" style="margin-top:26px;font-size:46px"><b>Coming soon.</b> Free on the same Wi-Fi.</p>', 80, 340, 880);
    var ph = V.art('<div class="phone" style="position:absolute;left:0;top:0;width:740px;height:980px;border-radius:92px;background:#070707"></div>', 170, 1150, { width: '740px', height: '980px' });
    var scr = V.art('<div style="position:absolute;inset:0;border-radius:70px 70px 0 0;overflow:hidden;background:radial-gradient(ellipse at 80% 0%,rgba(255,91,31,.14),transparent 60%),#121110">' +
      '<div style="position:absolute;left:0;right:0;top:0;height:34px;background:rgba(50,50,50,.8)"></div>' +
      '<div style="position:absolute;left:44px;top:74px;width:610px;height:170px;border-radius:18px;background:#1C1C1F;box-shadow:0 0 0 1.5px rgba(255,255,255,.1)">' +
      '<div style="height:44px;display:flex;align-items:center;gap:9px;padding:0 16px;border-bottom:1.5px solid rgba(255,255,255,.08)"><i style="width:12px;height:12px;border-radius:50%;background:#4A4742"></i><i style="width:12px;height:12px;border-radius:50%;background:#4A4742"></i><i style="width:12px;height:12px;border-radius:50%;background:#4A4742"></i><span style="margin-left:12px;font:500 16px var(--mono);letter-spacing:.1em;color:#8C877F;text-transform:uppercase">Render queue</span></div>' +
      '<div style="padding:34px 30px 0;font:500 26px/1.2 var(--ui);color:#EDE8DF">launch-video-final.mov</div>' +
      '<div style="margin:18px 30px 0;height:14px;border-radius:7px;background:rgba(237,232,223,.12)"><div style="width:100%;height:100%;border-radius:7px;background:#EDE8DF"></div></div>' +
      '<div style="padding:12px 30px 0;font:500 17px var(--mono);letter-spacing:.1em;color:#8C877F;text-transform:uppercase">Ready · waiting for you</div></div>' +
      '</div>', 192, 1172, { width: '696px', height: '960px' });
    S.btn = V.art('<div style="width:250px;height:92px;border-radius:22px;background:#EDE8DF;color:#0A0A0A;display:grid;place-items:center;font:600 40px var(--ui)">Export</div>', 420, 1432);
    S.btnDone = V.art('<div style="width:250px;height:92px;border-radius:22px;background:#EDE8DF;color:#0A0A0A;display:flex;align-items:center;justify-content:center;gap:12px;font:600 36px var(--ui)">' + FS.checkSVG(34, '#0A0A0A') + 'Exported</div>', 420, 1432);
    S.ptr = { x: 330, y: 1560 };
    S.ptrEl = V.art(FS.pointerSVG(118, { tip: true, tipR: 7, sw: 5 }), 0, 0, { filter: 'drop-shadow(0 8px 16px rgba(0,0,0,.6))', zIndex: 7 });
    S.rings = V.art('', 0, 0, { zIndex: 6 });
    S.end = V.endCard({ y: 300, markH: 190, foot: 'Free on the same Wi-Fi · Anywhere plan coming' });
    S.phoneEls = [ph, scr, S.ptrEl, S.rings];
  },
  frame: function (t) {
    var S = this.S, E = V.E, P = V.prog;
    var a = { x: 250, y: 1640 }, b = { x: 610, y: 1488 };
    var k = E.inOut(P(t, 3.1, 5.5));
    if (t > 14.3) k = 1 - E.inOut(P(t, 14.3, 14.95));
    S.ptr = { x: V.lerp(a.x, b.x, k), y: V.lerp(a.y, b.y, k) + Math.sin(k * Math.PI) * -60 };
    S.touch = (t > 2.9 && t < 6.2) ? { x: 470 + (S.ptr.x - a.x) * .45, y: 1790 + (S.ptr.y - a.y) * .45 } : null;
    var flash = t >= 5.8 ? Math.max(0, 1 - (t - 5.8) / .8) : 0;
    S.glow = flash * .9;
    S.F.draw(t, [V.ripple(b.x, b.y, 5.8, 1.2, 620, 40, 1.4)]);
    var off = FS.pointerTip(118, 5); S.ptrEl.style.transform = 'translate(' + (S.ptr.x - off).toFixed(1) + 'px,' + (S.ptr.y - off).toFixed(1) + 'px)';
    var r = '';
    if (t >= 5.8 && t < 7.2) { var age = t - 5.8; r = '<svg width="1080" height="1920" style="position:absolute;left:0;top:0" viewBox="0 0 1080 1920"><circle cx="' + b.x + '" cy="' + b.y + '" r="' + (14 + age * 150).toFixed(1) + '" fill="none" stroke="#FF5B1F" stroke-width="' + (6 * (1 - age / 1.4)).toFixed(2) + '" opacity="' + (1 - age / 1.4).toFixed(2) + '"/></svg>'; }
    S.rings.innerHTML = r;
    var exported = t >= 6.0 && t < 14.3;
    var dim = t < 12.6 ? 1 : t < 13.0 ? 1 - .75 * E.out(P(t, 12.6, 13.0)) : t < 14.4 ? .25 : .25 + .75 * E.inOut(P(t, 14.4, 14.95));
    S.cv.style.opacity = dim.toFixed(3);
    S.phoneEls.forEach(function (e) { e.style.opacity = dim.toFixed(3); });
    S.btn.style.opacity = exported ? 0 : dim.toFixed(3); S.btnDone.style.opacity = exported ? dim.toFixed(3) : 0;
    S.chip.style.opacity = t < 12.6 || t > 14.6 ? 1 : 0;
    if (t < 2.4) V.reveal(S.hook, t, -1, 2.4, { instant: true });
    else if (t > 14.55) V.reveal(S.hook, t, 14.55, 16, { stagger: .06, dur: .35 });
    else V.reveal(S.hook, t, -1, -.5);
    V.reveal(S.t2, t, 2.45, 4.7);
    V.reveal(S.t3, t, 4.8, 7.8);
    V.reveal(S.t4, t, 7.9, 10.6, { stagger: .12 });
    V.reveal(S.t5, t, 10.7, 12.9, { stagger: .1 });
    S.end(t, 13.0, 14.45);
  }
});
