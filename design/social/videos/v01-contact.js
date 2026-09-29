/* V01 · Contact: the fingertip meets the pointer. Sound-off hook: "Watch the dot". */
V.define('v01', {
  dur: 10, fps: 30,
  build: function (V) {
    var L = V.LAND, S = this.S = {};
    S.C = L ? { x: 1270, y: 520 } : { x: 540, y: 1100 };
    S.G0 = L ? 360 : 380; S.ha = L ? -.42 : -.62; S.hs = L ? 1.25 : 1.6; S.cs = L ? .82 : 1.12;
    S.cv = V.canvas(0);
    var dur = this.dur;
    S.F = FS.Field(S.cv, { cell: 12, dust: .05, seed: 101, plates: L ? [[90, 150, 820, 780, 60], [1030, 225, 480, 70, 20]] : [[0, 250, 1080, 520, 60], [230, 812, 620, 70, 20]], twinkle: 2 * Math.PI * 2 / dur, scene: function (c, w, h, t) {
      var fl = Math.sin(t * 2 * Math.PI / dur * 3) * 6, dir = { x: Math.cos(S.ha), y: Math.sin(S.ha) };
      FS.drawCursor(c, S.C.x + 5, S.C.y + 2 + fl, S.cs, 0, false);
      FS.drawHand(c, S.C.x - 3 - dir.x * S.gap, S.C.y + 2 + fl - dir.y * S.gap, S.hs, S.ha);
      if (S.glow > 0) FS.glow(c, S.C.x, S.C.y + fl, (L ? 60 : 64) * (.7 + S.glow * .5), Math.min(1, S.glow));
    } });
    var tx = L ? 120 : 80, tw = L ? 760 : 880;
    S.readout = V.text('<span class="readout" style="font-size:' + (L ? 28 : 34) + 'px">Gap · <b>41 cm</b></span>', L ? S.C.x - 220 : 240, L ? 250 : 830, L ? 440 : 600, '', { textAlign: 'center' });
    S.hook = V.text('<p class="vcap" style="font-size:30px">Sound off<span class="pd">?</span></p><h1 class="vh1" style="font-size:' + (L ? 130 : 150) + 'px;margin-top:22px">' + V.lines(['Watch', 'the dot']) + '</h1>', tx, L ? 230 : 300, tw);
    S.conn = V.text('<h1 class="vh1" style="font-size:' + (L ? 124 : 136) + 'px">' + V.lines(['Connected']) + '</h1><p class="vser" style="font-size:' + (L ? 80 : 76) + 'px;margin-top:18px">That’s the whole product.</p>', tx, L ? 260 : 300, tw);
    S.line = V.text('<h1 class="vh1" style="font-size:' + (L ? 104 : 118) + 'px">' + V.lines(['Your Mac', 'is far<span class="pd">.</span>', 'Your reach', '<span class="it">isn’t.</span>']) + '</h1>', tx, L ? 170 : 290, tw);
    S.end = V.endCard(L ? { y: 150, x: 0, w: 1920, markH: 190, foot: 'Free on the same Wi-Fi · no account' } : { y: 430, markH: 200, foot: 'Free on the same Wi-Fi · no account' });
  },
  frame: function (t) {
    var S = this.S, E = V.E, P = V.prog;
    var g;
    if (t < 1.25) g = S.G0 * (1 - E.out(t / 1.25));
    else if (t < 3.3) g = 0;
    else if (t < 3.75) g = 46 * E.out(P(t, 3.3, 3.75));
    else if (t < 3.95) g = 46 * (1 - E.inOut(P(t, 3.75, 3.95)));
    else if (t < 8.9) g = 0;
    else g = S.G0 * E.inOut(P(t, 8.9, 9.95));
    S.gap = g;
    var contact = t >= 1.25 && t < 8.9;
    var flash = Math.max(t >= 1.25 ? Math.max(0, 1 - (t - 1.25) / .9) : 0, t >= 3.95 ? Math.max(0, 1 - (t - 3.95) / .9) : 0);
    S.glow = contact ? .5 + .9 * flash : Math.max(0, 1 - g / 80) * .5;
    var rip = [V.ripple(S.C.x, S.C.y, 1.25, 1.5, 820, 60, 1.9), V.ripple(S.C.x, S.C.y, 3.95, .95, 700, 50, 1.6)];
    S.F.draw(t, rip);
    var dim = t < 7.3 ? 1 : t < 7.8 ? 1 - .82 * E.out(P(t, 7.3, 7.8)) : t < 9.3 ? .18 : .18 + .82 * E.inOut(P(t, 9.3, 9.9));
    S.cv.style.opacity = dim.toFixed(3);
    var b = S.readout.querySelector('b');
    if (t < 1.25) { b.textContent = Math.max(1, Math.round(g / 8)) + ' cm'; b.className = ''; }
    else if (t >= 3.95 && t < 4.7) { b.textContent = 'click'; b.className = 'hit'; }
    else { b.textContent = '0 cm · connected'; b.className = 'hit'; }
    var rOp = t < 7.2 ? 1 : Math.max(0, 1 - (t - 7.2) / .3);
    if (t > 9.6) rOp = Math.min(1, (t - 9.6) / .3);
    S.readout.style.opacity = rOp.toFixed(3);
    if (t > 9.6) b.textContent = Math.max(1, Math.round(S.G0 / 8)) + ' cm', b.className = '';
    if (t < 1.5) V.reveal(S.hook, t, -1, 1.5, { instant: true, fo: .25 });
    else if (t > 9.55) { V.reveal(S.hook, t, 9.55, 11, { stagger: .08, dur: .4 }); }
    else V.reveal(S.hook, t, -1, -.5);
    V.reveal(S.conn, t, 1.5, 4.25, { fo: .3 });
    V.reveal(S.line, t, 4.35, 7.35, { stagger: .14 });
    S.end(t, 7.45, 9.5);
  }
});
