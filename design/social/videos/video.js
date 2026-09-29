(function () {
'use strict';
var q = new URLSearchParams(location.search);
var W = +q.get('w') || 1080, H = +q.get('h') || 1920, LAND = W > H;
var root = document.getElementById('root');
root.style.width = W + 'px'; root.style.height = H + 'px';
document.body.style.width = W + 'px'; document.body.style.height = H + 'px';
var E = FS.ease, clamp = FS.clamp;

var V = window.V = {
  W: W, H: H, LAND: LAND, q: q, root: root, defs: {}, E: E, clamp: clamp, prog: FS.prog, lerp: FS.lerp,
  SAFE: LAND ? { x0: 90, y0: 70, x1: W - 90, y1: H - 120 } : { x0: 65, y0: 270, x1: 960, y1: 1440 }
};
V.define = function (id, def) { V.defs[id] = def; };

V.el = function (html, style, cls, safe) {
  var e = document.createElement('div');
  e.className = 'v ' + (cls || '');
  if (safe) e.setAttribute('data-safe', safe === true ? 'text' : safe);
  e.innerHTML = html || '';
  Object.assign(e.style, style || {});
  root.appendChild(e);
  return e;
};
V.text = function (html, x, y, w, cls, style) { return V.el(html, Object.assign({ left: x + 'px', top: y + 'px', width: w ? w + 'px' : 'auto' }, style || {}), cls, true); };
V.art = function (html, x, y, style, cls) { return V.el(html, Object.assign({ left: x + 'px', top: y + 'px' }, style || {}), cls, false); };
V.canvas = function (z) { var c = document.createElement('canvas'); c.width = W; c.height = H; c.className = 'cv-full'; c.style.zIndex = z == null ? 0 : z; root.appendChild(c); return c; };
V.lines = function (arr) { return arr.map(function (s) { return '<span class="ln"><span>' + s + '</span></span>'; }).join(''); };

/* visibility window [a,b] with eased in/out; fi:0 means already visible (frame 0 hook) */
V.vis = function (el, t, a, b, o) {
  o = o || {};
  var fi = o.fi == null ? .45 : o.fi, fo = o.fo == null ? .3 : o.fo, dy = o.dy == null ? 28 : o.dy;
  var op = 0, y = 0, kin = 0, kout = 0;
  if (t >= a && t <= b) {
    kin = fi > 0 ? E.primary(clamp((t - a) / fi, 0, 1)) : 1;
    kout = fo > 0 ? clamp((b - t) / fo, 0, 1) : 1;
    op = Math.min(kin, kout);
    y = (1 - kin) * dy - (1 - E.out(kout)) * dy * .6;
  }
  el.style.opacity = op.toFixed(3);
  el.style.transform = (o.scaleIn ? 'scale(' + (1 - (1 - kin) * .06).toFixed(4) + ') ' : '') + 'translateY(' + y.toFixed(2) + 'px)';
  return op;
};
/* masked line reveal: .ln > span slides up, staggered; exits by fading */
V.reveal = function (el, t, a, b, o) {
  o = o || {};
  var st = o.stagger == null ? .12 : o.stagger, d = o.dur == null ? .8 : o.dur, fo = o.fo == null ? .3 : o.fo;
  var spans = el.querySelectorAll('.ln > span');
  var vis = t >= a && t <= b;
  el.style.opacity = vis ? clamp((b - t) / fo, 0, 1).toFixed(3) : 0;
  spans.forEach(function (s, i) {
    var k = o.instant ? 1 : E.primary(clamp((t - a - i * st) / d, 0, 1));
    s.style.transform = 'translateY(' + ((1 - k) * 110).toFixed(2) + '%)';
  });
};
V.type = function (el, full, t, a, cps, caret) {
  var n = t < a ? 0 : Math.min(full.length, Math.floor((t - a) * cps));
  el.innerHTML = full.slice(0, n) + (caret ? '<span class="caret" style="margin-left:4px;opacity:' + ((Math.floor(t * 2.2) % 2 === 0 || n < full.length) ? 1 : 0) + '"></span>' : '');
  return n >= full.length;
};
V.ripple = function (x, y, t0, s, v, w, life) { return { x: x, y: y, t0: t0, s: s == null ? 1.4 : s, v: v || 780, w: w || 56, life: life || 1.9 }; };

/* shared end card: mark + wordmark + line + CTA; returns an updater */
V.endCard = function (o) {
  o = o || {};
  var y = o.y == null ? 560 : o.y, cx = o.x == null ? 0 : o.x, w = o.w || W;
  var veil = V.art('', 0, 0, { width: W + 'px', height: H + 'px', background: '#050505', zIndex: 5, opacity: 0 });
  var mk = V.art(FS.markSVG(o.markH || 220, { tipR: .66, glow: 3.6, id: 77 }), 0, y, { width: w + 'px', left: cx + 'px', display: 'flex', justifyContent: 'center' });
  var wm = V.text('<div class="endwm center">farside</div>', cx, y + (o.markH || 220) + 50, w);
  var line = V.text('<p class="vsub center" style="color:var(--bone);font-size:52px">Control your Mac from <span class="it">iPhone.</span></p>', cx, y + (o.markH || 220) + 230, w);
  var cta = V.text('<div style="display:flex;justify-content:center"><span class="pill" style="font-size:40px">' + (o.cta || 'Beta list · link in bio') + ' <i>' + FS.arrowSVG(30, '#EDE8DF') + '</i></span></div>', cx, y + (o.markH || 220) + 350, w, '', {});
  cta.setAttribute('data-safe', 'box');
  var foot = o.foot ? V.text('<p class="vcap center" style="font-size:24px">' + o.foot + '</p>', cx, y + (o.markH || 220) + 490, w) : null;
  return function (t, a, b) {
    var k = t < a - .25 || t > b + .25 ? 0 : Math.min(1, (t - (a - .25)) / .35, (b + .25 - t) / .35);
    veil.style.opacity = (Math.max(0, k) * .86).toFixed(3); veil.style.transform = 'none';
    V.vis(mk, t, a, b, { dy: 20, fo: o.fo }); V.vis(wm, t, a + .08, b, { fo: o.fo }); V.vis(line, t, a + .2, b, { fo: o.fo }); V.vis(cta, t, a + .34, b, { fo: o.fo });
    if (foot) V.vis(foot, t, a + .45, b, { fo: o.fo });
  };
};

function effOpacity(e) { var o = 1; while (e && e !== document.body) { var cs = getComputedStyle(e); if (cs.display === 'none' || cs.visibility === 'hidden') return 0; o *= +cs.opacity; e = e.parentElement; } return o; }
window.__safeCheck = function () {
  var S = V.SAFE, hits = [];
  root.querySelectorAll('[data-safe]').forEach(function (e) {
    if (effOpacity(e) < .05) return;
    var r;
    if (e.getAttribute('data-safe') === 'box') { var kids = e.querySelectorAll('.pill,.tag,.card,.notif'); r = (kids[0] || e).getBoundingClientRect(); }
    else {
      var tw = document.createTreeWalker(e, NodeFilter.SHOW_TEXT), n, x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
      while ((n = tw.nextNode())) {
        if (!n.nodeValue.trim() || effOpacity(n.parentElement) < .05) continue;
        var rg = document.createRange(); rg.selectNodeContents(n);
        Array.prototype.forEach.call(rg.getClientRects(), function (q) { if (q.width < .5) return; x0 = Math.min(x0, q.left); y0 = Math.min(y0, q.top); x1 = Math.max(x1, q.right); y1 = Math.max(y1, q.bottom); });
      }
      if (x1 < x0) return;
      r = { left: x0, top: y0, right: x1, bottom: y1, width: x1 - x0, height: y1 - y0 };
    }
    if (!r || r.width < 1 || r.height < 1) return;
    if (r.left < S.x0 - .5 || r.top < S.y0 - .5 || r.right > S.x1 + .5 || r.bottom > S.y1 + .5)
      hits.push({ text: (e.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 70), rect: [r.left, r.top, r.right, r.bottom] });
  });
  return hits;
};
})();
