/* V06 · "Agent needs you" (beta): the waiting agent, the beacon, the tap, back to your life. */
V.define('v06', {
  dur: 14, fps: 30,
  build: function (V) {
    var S = this.S = {};
    S.cv = V.canvas(0);
    S.F = FS.Field(S.cv, { cell: 12, dust: .05, seed: 606, plates: [[0, 250, 1080, 480, 60]], twinkle: 2 * Math.PI * 2 / this.dur, scene: function (c, w, h, t) {
      if (S.touch) { c.fillStyle = FS.Lc(.72); c.beginPath(); c.arc(S.touch.x, S.touch.y, 46, 0, 6.3); c.fill(); }
    } });
    S.term = V.art('<div class="term" style="position:relative;width:920px;height:300px;font-size:30px;line-height:1.55"><div class="ttl" style="font-size:17px">agent · ~/app</div><div class="dots"><i></i><i></i><i></i></div><div id="bea" style="position:absolute;right:26px;top:13px;display:flex;align-items:center;gap:10px;font:500 15px/1 var(--mono);letter-spacing:.14em;text-transform:uppercase;color:var(--bone)"><i class="live" style="font-size:16px"></i><span>needs input</span></div>' +
      '<div class="a">› run the test suite</div><div id="q">Allow the agent to run tests<span class="a">?</span> <span class="a">[y/n]</span> <span class="caret"></span></div><div id="out" class="a"></div><div id="tm" class="a" style="position:absolute;left:30px;bottom:22px;font-size:22px;letter-spacing:.08em">waiting 00:41:12</div></div>', 80, 760, { zIndex: 4 });
    S.q = S.term.querySelector('#q'); S.out = S.term.querySelector('#out'); S.tm = S.term.querySelector('#tm'); S.bea = S.term.querySelector('#bea');
    S.phone = V.art('<div class="phone" style="position:absolute;inset:0;border-radius:80px;background:#070707"></div>' +
      '<div id="lock" style="position:absolute;left:0;right:0;top:120px;text-align:center"><div style="font:300 110px/1 var(--ui);letter-spacing:-.02em;color:#EDE8DF">2:14</div><div style="font:500 20px var(--mono);letter-spacing:.14em;text-transform:uppercase;color:var(--ash);margin-top:10px">Tuesday</div></div>' +
      '<div id="nt" class="notif" style="position:absolute;left:30px;right:30px;top:330px;padding:20px 22px"><div class="ic" style="width:58px;height:58px">' + FS.markSVG(34, { rows: FS.ARROW_S }) + '</div><div><small style="font-size:15px">farside · now</small><b style="font-size:26px">Your agent needs you</b><span style="font-size:23px">It wants to run tests. Tap to answer.</span></div></div>' +
      '<div id="ask" style="position:absolute;left:30px;right:30px;top:120px;opacity:0"><div style="font:500 18px var(--mono);letter-spacing:.14em;text-transform:uppercase;color:var(--ash)">Studio Mac · agent</div><div style="margin-top:22px;font:500 30px/1.45 var(--mono);color:#EDE8DF">Allow the agent to run tests<span style="color:#8C877F">?</span></div>' +
      '<div style="display:flex;gap:14px;margin-top:44px"><span style="flex:1;height:84px;border-radius:22px;background:rgba(237,232,223,.1);box-shadow:inset 0 0 0 2px var(--line2);display:grid;place-items:center;font:600 30px var(--ui)">Deny</span><span style="flex:1;height:84px;border-radius:22px;background:#EDE8DF;color:#0A0A0A;display:grid;place-items:center;font:600 30px var(--ui)">Allow</span></div></div>', 250, 1090, { width: '580px', height: '1000px', zIndex: 6 });
    S.lock = S.phone.querySelector('#lock'); S.nt = S.phone.querySelector('#nt'); S.ask = S.phone.querySelector('#ask');
    S.beacon = V.art('', 0, 0, { zIndex: 7 });
    S.tag = V.text('<span class="tag" style="font-size:22px">Beta</span>', 810, 1110, 150, '', { textAlign: 'right' });
    S.tag.setAttribute('data-safe', 'box');
    S.hook = V.text('<h1 class="vh1" style="font-size:90px">' + V.lines(['Your agent', 'has been waiting', '41 minutes']) + '</h1>', 80, 300, 880);
    S.t2 = V.text('<h1 class="vh1" style="font-size:132px">' + V.lines(['Your phone', 'taps you']) + '</h1>', 80, 300, 880);
    S.t3 = V.text('<h1 class="vh1" style="font-size:132px">' + V.lines(['Tap Allow']) + '</h1><p class="vser" style="font-size:88px;margin-top:12px">Back to your life.</p>', 80, 300, 880);
    S.t4 = V.text('<h1 class="vh1" style="font-size:112px">' + V.lines(['Agent needs', 'you']) + '</h1><p class="vsub" style="margin-top:22px;font-size:46px"><b>Beta</b> · for AI coding agents running on your Mac</p>', 80, 300, 880);
    S.end = V.endCard({ y: 330, markH: 190, foot: 'Agent needs you · beta' });
  },
  frame: function (t) {
    var S = this.S, E = V.E, P = V.prog;
    var secs = 41 * 60 + 12 + Math.floor(Math.min(t, 5.2));
    S.tm.textContent = t < 5.2 || t > 13.4 ? 'waiting 00:' + String(Math.floor(secs / 60)).padStart(2, '0') + ':' + String(secs % 60).padStart(2, '0') : 'answered from your phone';
    S.bea.style.opacity = t < 5.2 || t > 13.4 ? (.55 + .45 * Math.cos(t * Math.PI * 2 / 1.2)).toFixed(3) : 0;
    var caretOn = Math.floor(t * 2.2) % 2 === 0;
    var answered = t >= 5.3 && t < 13.4;
    S.q.innerHTML = 'Allow the agent to run tests<span class="a">?</span> <span class="a">[y/n]</span> ' + (answered ? '<span style="color:var(--bone)">y</span>' : '<span class="caret" style="opacity:' + (caretOn ? 1 : 0) + '"></span>');
    S.out.innerHTML = answered ? (t > 5.8 ? '› running tests' + '.'.repeat(1 + Math.floor((t * 3) % 3)) : '') + (t > 7.2 ? '<br><span style="color:var(--bone)">› done</span>' : '') : '';
    var up = t < 2.2 ? 0 : t < 3.0 ? E.primary(P(t, 2.2, 3.0)) : t < 12.9 ? 1 : 1 - E.inOut(P(t, 12.9, 13.6));
    S.phone.style.transform = 'translateY(' + ((1 - up) * 900).toFixed(1) + 'px)';
    var opened = t >= 4.2;
    S.lock.style.opacity = opened ? 0 : 1; S.nt.style.opacity = opened ? 0 : 1; S.ask.style.opacity = opened ? 1 : 0;
    var nx = 250 + 30 + 22 + 29, ny = 1090 + 330 + 20 + 29 + (1 - up) * 900;
    var r = '';
    if (!opened && up > .5) for (var k = 0; k < 3; k++) { var ph = ((t * .8) + k / 3) % 1; r += '<circle cx="' + nx + '" cy="' + ny.toFixed(1) + '" r="' + (30 + ph * 150).toFixed(1) + '" fill="none" stroke="#FF5B1F" stroke-width="4" stroke-dasharray="2 10" stroke-linecap="round" opacity="' + (1 - ph).toFixed(2) + '"/>'; }
    var taps = [[4.0, 520, 1480], [5.2, 675, 1423]];
    taps.forEach(function (c) { var age = t - c[0]; if (age >= 0 && age < 1.0) r += '<circle cx="' + c[1] + '" cy="' + c[2] + '" r="' + (12 + age * 120).toFixed(1) + '" fill="none" stroke="#FF5B1F" stroke-width="' + (6 * (1 - age)).toFixed(2) + '" opacity="' + (1 - age).toFixed(2) + '"/>'; });
    S.beacon.innerHTML = r ? '<svg width="1080" height="1920" style="position:absolute;left:0;top:0">' + r + '</svg>' : '';
    S.touch = t > 3.5 && t < 4.3 ? { x: 520, y: 1480 + (1 - P(t, 3.5, 4.0)) * 120 } : t > 4.7 && t < 5.5 ? { x: 675, y: 1423 + (1 - P(t, 4.7, 5.2)) * 120 } : null;
    S.F.draw(t, []);
    V.vis(S.tag, t, 2.6, 12.9, { fi: .3 });
    var dim = t < 10.5 ? 1 : t < 10.9 ? 1 - .78 * E.out(P(t, 10.5, 10.9)) : t < 13.3 ? .22 : .22 + .78 * E.inOut(P(t, 13.3, 13.9));
    [S.term, S.phone, S.beacon, S.cv].forEach(function (e) { e.style.opacity = dim.toFixed(3); });
    if (t < 2.3) V.reveal(S.hook, t, -1, 2.3, { instant: true });
    else if (t > 13.5) V.reveal(S.hook, t, 13.5, 15, { stagger: .06, dur: .35 });
    else V.reveal(S.hook, t, -1, -.5);
    V.reveal(S.t2, t, 2.35, 5.25);
    V.reveal(S.t3, t, 5.35, 8.0);
    V.reveal(S.t4, t, 8.1, 10.5);
    S.end(t, 10.6, 13.3);
  }
});
