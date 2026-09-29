/* V07 · Talk to your phone. It types on your Mac. */
V.define('v07', {
  dur: 10, fps: 30,
  build: function (V) {
    var S = this.S = {};
    S.cv = V.canvas(0);
    S.F = FS.Field(S.cv, { cell: 12, dust: .05, seed: 707, plates: [[0, 250, 1080, 480, 60]], twinkle: 2 * Math.PI * 2 / this.dur, scene: function (c, w, h, t) {
      if (S.touch) { c.fillStyle = FS.Lc(.72); c.beginPath(); c.arc(S.touch.x, S.touch.y, 44, 0, 6.3); c.fill(); }
    } });
    var cols = 15, wave = '<div id="wave" style="display:flex;align-items:center;gap:13px;height:120px">';
    for (var i = 0; i < cols; i++) { wave += '<div style="display:grid;gap:6px;align-content:center">'; for (var j = 0; j < 8; j++) wave += '<i style="display:block;width:11px;height:11px;border-radius:50%;background:#EDE8DF"></i>'; wave += '</div>'; }
    wave += '</div>';
    S.card = V.art('<div class="card" style="position:relative;width:920px;height:190px"><div style="height:100%;display:grid;grid-template-columns:auto 1fr auto;align-items:center;gap:28px;padding:0 34px">' + wave +
      '<div><div style="font:500 21px/1 var(--mono);letter-spacing:.14em;text-transform:uppercase;display:flex;align-items:center;gap:12px"><i class="live" style="font-size:21px"></i>Listening</div><div style="font:400 30px/1.3 var(--ui);color:var(--ash);margin-top:12px">Speak, then Done</div></div>' +
      '<span id="done" style="height:76px;padding:0 32px;border-radius:999px;background:var(--bone);color:#0A0A0A;font:600 32px/76px var(--ui)">Done</span></div></div>', 80, 760, { zIndex: 4 });
    S.cols = S.card.querySelectorAll('#wave > div');
    S.win = V.art('<div class="win" style="position:relative;width:920px;height:300px"><div class="tb"><i></i><i></i><i></i><span>Finder · rename</span></div><div style="padding:52px 40px;display:flex;align-items:center;gap:26px"><div style="width:96px;height:118px;border-radius:12px;background:#1E1E1E;box-shadow:inset 0 0 0 2px var(--line2);flex:none"></div><div id="nm" style="flex:1;border-radius:12px;box-shadow:inset 0 0 0 3px rgba(237,232,223,.55);padding:22px 24px;font:500 44px/1 var(--ui);letter-spacing:-.01em;min-height:92px"></div></div></div>', 80, 1010, { zIndex: 4 });
    S.nm = S.win.querySelector('#nm');
    S.rip = V.art('', 0, 0, { zIndex: 6 });
    S.hook = V.text('<h1 class="vh1" style="font-size:132px">' + V.lines(['Talk to', 'your phone']) + '</h1>', 80, 300, 880);
    S.t2 = V.text('<h1 class="vh1" style="font-size:124px">' + V.lines(['It types on', 'your Mac']) + '</h1><p class="vser" style="font-size:66px;margin-top:14px">Even the embarrassing file names.</p>', 80, 300, 880);
    S.end = V.endCard({ y: 330, markH: 190, foot: 'Voice dictation into your Mac' });
  },
  frame: function (t) {
    var S = this.S, E = V.E, P = V.prog;
    var talking = t < 3.1 || t > 9.5;
    S.cols.forEach(function (col, i) {
      var env = Math.sin(Math.PI * (i + .5) / S.cols.length);
      var v = talking ? .2 + .8 * env * (.5 + .5 * Math.sin(t * 9 + i * 1.7) * Math.sin(t * 4.3 + i * .6)) : .12;
      var n = Math.max(1, Math.round(Math.abs(v) * 8));
      col.childNodes.forEach(function (d, j) { d.style.opacity = (Math.abs(j - 3.5) < n / 2 ? 1 : 0); });
    });
    var full = 'final final v2', txt;
    if (t < 1.2 || t > 9.5) txt = '<span style="background:rgba(237,232,223,.28);padding:0 4px;border-radius:4px">Untitled 3.mov</span>';
    else { var n = Math.min(full.length, Math.floor((t - 1.2) * 9)); txt = full.slice(0, n) + (t < 3.3 ? '<span class="caret" style="margin-left:4px;opacity:' + ((Math.floor(t * 2.2) % 2 === 0 || n < full.length) ? 1 : 0) + '"></span>' : ''); }
    S.nm.innerHTML = txt;
    var r = '', age = t - 3.2;
    if (age >= 0 && age < 1.0) r = '<svg width="1080" height="1920" style="position:absolute;left:0;top:0"><circle cx="880" cy="855" r="' + (12 + age * 120).toFixed(1) + '" fill="none" stroke="#FF5B1F" stroke-width="' + (6 * (1 - age)).toFixed(2) + '" opacity="' + (1 - age).toFixed(2) + '"/></svg>';
    S.rip.innerHTML = r;
    S.touch = t > 2.7 && t < 3.5 ? { x: 880, y: 855 + (1 - P(t, 2.7, 3.2)) * 110 } : null;
    S.F.draw(t, []);
    var dim = t < 6.4 ? 1 : t < 6.8 ? 1 - .8 * E.out(P(t, 6.4, 6.8)) : t < 9.3 ? .2 : .2 + .8 * E.inOut(P(t, 9.3, 9.9));
    [S.card, S.win, S.cv, S.rip].forEach(function (e) { e.style.opacity = dim.toFixed(3); });
    if (t < 3.3) V.reveal(S.hook, t, -1, 3.3, { instant: true });
    else if (t > 9.5) V.reveal(S.hook, t, 9.5, 11, { stagger: .06, dur: .35 });
    else V.reveal(S.hook, t, -1, -.5);
    V.reveal(S.t2, t, 3.4, 6.4);
    S.end(t, 6.5, 9.35);
  }
});
