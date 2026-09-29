/* V03 · Distance counter: 8,421 km to 0 km. "(we rounded)". Anywhere plan labelled as coming. */
V.define('v03', {
  dur: 10, fps: 30,
  build: function (V) {
    var S = this.S = {}, dur = this.dur;
    S.C = { x: 540, y: 1150 }; S.G0 = 430; S.ha = -.58; S.hs = 1.5; S.cs = 1.05;
    S.cv = V.canvas(0);
    S.F = FS.Field(S.cv, { cell: 12, dust: .05, seed: 303, twinkle: 2 * Math.PI * 2 / dur, plates: [[0, 250, 1080, 570, 60]], scene: function (c, w, h, t) {
      var dir = { x: Math.cos(S.ha), y: Math.sin(S.ha) }, fl = Math.sin(t * 2 * Math.PI / dur * 2) * 5;
      FS.drawCursor(c, S.C.x + 5 + dir.x * S.gap * .35, S.C.y + 2 + fl + dir.y * S.gap * .35, S.cs, 0, false);
      FS.drawHand(c, S.C.x - 3 - dir.x * S.gap * .65, S.C.y + 2 + fl - dir.y * S.gap * .65, S.hs, S.ha);
      if (S.glow > 0) FS.glow(c, S.C.x, S.C.y + fl, 70 * (.7 + S.glow * .5), Math.min(1, S.glow));
    } });
    S.label = V.text('<p class="vcap" style="font-size:30px">Distance to your <b>Mac</b></p>', 80, 300, 880, '', { textAlign: 'center' });
    S.num = V.text('<div class="nowrap center" style="font:900 230px/1 var(--dot);letter-spacing:-.02em"><span id="n">8<span class="pd" style="font-size:.5em">,</span>421</span><span style="font:500 64px var(--mono);letter-spacing:.06em;color:var(--ash);margin-left:24px">km</span></div>', 65, 380, 895);
    S.nEl = S.num.querySelector('#n');
    S.conn = V.text('<p class="vcap center" style="font-size:30px;color:var(--ember)">Connected</p>', 80, 650, 880);
    S.round = V.text('<p class="vser center" style="font-size:78px">(we rounded)</p>', 80, 700, 880);
    S.line = V.text('<h1 class="vh1" style="font-size:118px">' + V.lines(['Your Mac', 'is far<span class="pd">.</span>', 'Your reach', '<span class="it">isn’t.</span>']) + '</h1>', 80, 300, 880);
    S.end = V.endCard({ y: 330, markH: 190, foot: 'Across the internet: Anywhere plan · coming' });
  },
  frame: function (t) {
    var S = this.S, E = V.E, P = V.prog;
    var k = t < 3.2 ? E.out(P(t, 0, 3.2)) : t < 9.35 ? 1 : 1 - E.inOut(P(t, 9.35, 9.97));
    var km = Math.round(8421 * (1 - k));
    var s = String(km), html = s.length > 3 ? s.slice(0, s.length - 3) + '<span class="pd" style="font-size:.5em">,</span>' + s.slice(-3) : s;
    S.nEl.innerHTML = html;
    S.gap = S.G0 * Math.pow(1 - k, .8);
    var flash = t >= 3.2 ? Math.max(0, 1 - (t - 3.2) / .9) : 0;
    S.glow = k >= 1 ? .5 + .9 * flash : Math.max(0, 1 - S.gap / 90) * .5;
    S.F.draw(t, [V.ripple(S.C.x, S.C.y, 3.2, 1.6, 820, 64, 2.0)]);
    var dim = t < 7.3 ? 1 : t < 7.8 ? 1 - .8 * E.out(P(t, 7.3, 7.8)) : t < 9.3 ? .2 : .2 + .8 * E.inOut(P(t, 9.3, 9.95));
    S.cv.style.opacity = dim.toFixed(3);
    var numOp = t < 4.7 ? 1 : t < 5.0 ? 1 - P(t, 4.7, 5.0) : t > 9.55 ? P(t, 9.55, 9.9) : 0;
    S.num.style.opacity = numOp.toFixed(3); S.label.style.opacity = numOp.toFixed(3);
    V.vis(S.conn, t, 3.2, 5.0, { fi: .25, dy: 10 });
    V.vis(S.round, t, 3.65, 5.0, { fi: .5 });
    V.reveal(S.line, t, 5.05, 7.4, { stagger: .12 });
    S.end(t, 7.5, 9.4);
  }
});
