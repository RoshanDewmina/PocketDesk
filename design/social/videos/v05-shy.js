/* V05 · The pointer dodges your finger (twice), then contact. */
V.define('v05', {
  dur: 12, fps: 30,
  build: function (V) {
    var S = this.S = {}, dur = this.dur;
    S.ha = -.6; S.hs = 1.5; S.cs = 1.05;
    S.P0 = { x: 590, y: 1130 }; S.P1 = { x: 800, y: 900 }; S.P2 = { x: 400, y: 880 };
    S.cv = V.canvas(0);
    S.F = FS.Field(S.cv, { cell: 12, dust: .05, seed: 505, twinkle: 2 * Math.PI * 2 / dur, plates: [[0, 250, 1080, 560, 60]], scene: function (c, w, h, t) {
      FS.drawCursor(c, S.cur.x + 5, S.cur.y + 2, S.cs, S.tilt || 0, false);
      FS.drawHand(c, S.tip.x - 3, S.tip.y + 2, S.hs, S.ha);
      if (S.glow > 0) FS.glow(c, S.cur.x, S.cur.y, 66 * (.7 + S.glow * .5), Math.min(1, S.glow));
    } });
    S.readout = V.text('<span class="readout" style="font-size:34px">Gap · <b>40 cm</b></span>', 240, 740, 600, '', { textAlign: 'center' });
    S.hook = V.text('<h1 class="vh1" style="font-size:132px">' + V.lines(['Reach for', 'the pointer']) + '</h1>', 80, 300, 880);
    S.shy = V.text('<h1 class="vh1" style="font-size:150px">' + V.lines(['It<span class="pd">’</span>s shy']) + '</h1><p class="vser" style="font-size:84px;margin-top:12px">the first time.</p>', 80, 300, 880);
    S.still = V.text('<h1 class="vh1" style="font-size:150px">' + V.lines(['Still shy']) + '</h1><p class="vser" style="font-size:84px;margin-top:12px">Keep going.</p>', 80, 300, 880);
    S.conn = V.text('<h1 class="vh1" style="font-size:136px">' + V.lines(['Connected']) + '</h1><p class="vser" style="font-size:80px;margin-top:14px">That’s the whole product.</p>', 80, 300, 880);
    S.line = V.text('<h1 class="vh1" style="font-size:118px">' + V.lines(['Your Mac', 'is far<span class="pd">.</span>', 'Your reach', '<span class="it">isn’t.</span>']) + '</h1>', 80, 290, 880);
    S.end = V.endCard({ y: 330, markH: 190, foot: 'Free on the same Wi-Fi · no account' });
  },
  frame: function (t) {
    var S = this.S, E = V.E, P = V.prog;
    var dir = { x: Math.cos(S.ha), y: Math.sin(S.ha) };
    function near(p, d) { return { x: p.x - dir.x * d, y: p.y - dir.y * d }; }
    function mix(a, b, k) { return { x: V.lerp(a.x, b.x, k), y: V.lerp(a.y, b.y, k) }; }
    var T0 = near(S.P0, 380), cur, tip;
    if (t < 1.0) cur = S.P0; else if (t < 1.22) cur = mix(S.P0, S.P1, E.outBack(P(t, 1.0, 1.22))); else if (t < 2.5) cur = S.P1;
    else if (t < 2.72) cur = mix(S.P1, S.P2, E.outBack(P(t, 2.5, 2.72))); else if (t < 10.5) cur = S.P2; else cur = mix(S.P2, S.P0, E.inOut(P(t, 10.5, 11.5)));
    if (t < 1.0) tip = mix(T0, near(S.P0, 26), E.out(P(t, 0, 1.0)));
    else if (t < 2.45) tip = mix(near(S.P0, 26), near(S.P1, 24), E.inOut(P(t, 1.25, 2.45)));
    else if (t < 3.95) tip = mix(near(S.P1, 24), S.P2, E.inOut(P(t, 2.75, 3.95)));
    else if (t < 10.3) tip = S.P2;
    else tip = mix(S.P2, T0, E.inOut(P(t, 10.3, 11.95)));
    var jig = (t > 1.0 && t < 1.5) || (t > 2.5 && t < 3.0) ? Math.sin(t * 60) * 5 * (1 - ((t > 2.5 ? t - 2.5 : t - 1.0) / .5)) : 0;
    S.cur = { x: cur.x + jig, y: cur.y }; S.tip = tip; S.tilt = jig * .004;
    var contact = t >= 3.95 && t < 10.3;
    var flash = t >= 3.95 ? Math.max(0, 1 - (t - 3.95) / .9) : 0;
    var gap = Math.hypot(S.cur.x - tip.x, S.cur.y - tip.y);
    S.glow = contact ? .5 + .9 * flash : Math.max(0, 1 - gap / 80) * .45;
    S.F.draw(t, [V.ripple(S.P2.x, S.P2.y, 3.95, 1.5, 820, 60, 1.9)]);
    var b = S.readout.querySelector('b');
    if (contact) { b.textContent = '0 cm · connected'; b.className = 'hit'; } else { b.textContent = Math.max(1, Math.round(gap / 8)) + ' cm'; b.className = ''; }
    var dim = t < 9.1 ? 1 : t < 9.5 ? 1 - .8 * E.out(P(t, 9.1, 9.5)) : t < 11.0 ? .2 : .2 + .8 * E.inOut(P(t, 11.0, 11.9));
    S.cv.style.opacity = dim.toFixed(3);
    S.readout.style.opacity = (t < 8.9 ? 1 : t < 9.2 ? 1 - P(t, 8.9, 9.2) : t > 11.6 ? P(t, 11.6, 11.9) : 0).toFixed(3);
    if (t < 1.0) V.reveal(S.hook, t, -1, 1.0, { instant: true, fo: .15 });
    else if (t > 11.55) V.reveal(S.hook, t, 11.55, 13, { stagger: .06, dur: .35 });
    else V.reveal(S.hook, t, -1, -.5);
    V.reveal(S.shy, t, 1.05, 2.5, { dur: .5, fo: .15 });
    V.reveal(S.still, t, 2.55, 3.95, { dur: .5, fo: .15 });
    V.reveal(S.conn, t, 4.0, 6.6);
    V.reveal(S.line, t, 6.7, 9.1, { stagger: .12 });
    S.end(t, 9.2, 11.4);
  }
});
