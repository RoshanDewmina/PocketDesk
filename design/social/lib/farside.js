(function (G) {
'use strict';
var FS = G.FS = {};
FS.C = { void: '#050505', void2: '#0B0B0B', panel: '#121212', panel2: '#191919', bone: '#EDE8DF', ash: '#8C877F', dim: '#4A4742', ember: '#FF5B1F', emberD: '#C23D0E', mid: '#F7A57F' };
var BONE = [237, 232, 223], EMBER = [255, 91, 31];

FS.rng = function (seed) {
  var a = seed >>> 0;
  return function () { a = (a + 0x6D2B79F5) >>> 0; var t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
};
FS.clamp = function (v, a, b) { return v < a ? a : v > b ? b : v; };
FS.lerp = function (a, b, k) { return a + (b - a) * k; };
FS.prog = function (t, a, b) { return FS.clamp((t - a) / (b - a), 0, 1); };
FS.ease = {
  outExpo: function (t) { return t >= 1 ? 1 : 1 - Math.pow(2, -10 * t); },
  inOut: function (t) { return t < .5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2; },
  out: function (t) { return 1 - Math.pow(1 - t, 3); },
  inExpo: function (t) { return t <= 0 ? 0 : Math.pow(2, 10 * t - 10); },
  outBack: function (t) { var c1 = 1.70158, c3 = c1 + 1; return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2); },
  primary: function (t) { return cubicBezier(.16, 1, .3, 1, t); },
  reveal: function (t) { return cubicBezier(.22, 1, .36, 1, t); }
};
function cubicBezier(x1, y1, x2, y2, x) {
  if (x <= 0) return 0; if (x >= 1) return 1;
  var t = x;
  for (var i = 0; i < 8; i++) {
    var cx = 3 * x1 * t * (1 - t) * (1 - t) + 3 * x2 * t * t * (1 - t) + t * t * t - x;
    var dx = 3 * x1 * (1 - t) * (1 - t) + 6 * (x2 - x1) * t * (1 - t) + 3 * (1 - x2) * t * t;
    if (Math.abs(cx) < 1e-6) break; if (Math.abs(dx) < 1e-6) break; t -= cx / dx; t = FS.clamp(t, 0, 1);
  }
  return 3 * y1 * t * (1 - t) * (1 - t) + 3 * y2 * t * t * (1 - t) + t * t * t;
}

/* Scene luminance convention (from 21-reach): bone brightness lives in R/G, ember in B. */
FS.Lc = function (v) { v = Math.round(FS.clamp(v, 0, 1) * 255); return 'rgb(' + v + ',' + v + ',0)'; };
var Lc = FS.Lc;

FS.drawHand = function (c, tx, ty, s, a) {
  c.save(); c.translate(tx, ty); c.rotate(a); c.scale(s, s);
  var g = c.createLinearGradient(0, 0, -640, 230); g.addColorStop(0, Lc(1)); g.addColorStop(.28, Lc(.82)); g.addColorStop(.6, Lc(.46)); g.addColorStop(1, Lc(.18));
  var g2 = c.createLinearGradient(0, 0, -560, 200); g2.addColorStop(0, Lc(.78)); g2.addColorStop(.35, Lc(.6)); g2.addColorStop(1, Lc(.16));
  c.lineCap = 'round'; c.lineJoin = 'round';
  function seg(p, lw, st, out) { c.beginPath(); c.moveTo(p[0][0], p[0][1]); for (var i = 1; i < p.length; i++) c.lineTo(p[i][0], p[i][1]); if (out) { c.strokeStyle = 'rgb(10,10,0)'; c.lineWidth = lw + 8; c.stroke(); } c.strokeStyle = st; c.lineWidth = lw; c.stroke(); }
  seg([[-440, 142], [-1000, 360]], 150, Lc(.2));
  seg([[-240, 66], [-470, 150]], 106, g);
  c.strokeStyle = Lc(.62); c.lineWidth = 5; c.beginPath(); c.moveTo(-440 + 26, 142 + 68); c.lineTo(-440 - 26, 142 - 68); c.stroke();
  c.fillStyle = g; c.beginPath(); c.ellipse(-206, 64, 66, 55, -.14, 0, 6.2832); c.fill();
  seg([[-188, 86], [-150, 98], [-136, 113], [-150, 125]], 28, g2, true);
  seg([[-182, 60], [-134, 70], [-116, 90], [-132, 106]], 33, g2, true);
  seg([[-176, 34], [-120, 42], [-98, 64], [-114, 82]], 36, g2, true);
  seg([[-176, 8], [-94, 4], [-17, 0]], 34, g, true);
  c.strokeStyle = 'rgb(40,40,0)'; c.lineWidth = 2.4; c.beginPath(); c.arc(-94, 4, 10, -1.2, 1.2); c.stroke(); c.beginPath(); c.arc(-46, 2, 8, -1.1, 1.1); c.stroke();
  seg([[-250, 74], [-202, 66], [-156, 54], [-128, 52]], 30, g, true);
  c.restore();
};
FS.CUR = [[0, 0], [0, 250], [60, 196], [98, 284], [134, 268], [96, 180], [176, 180]];
FS.drawCursor = function (c, tx, ty, s, a, frame, lum) {
  var CUR = FS.CUR;
  c.save(); c.translate(tx, ty); c.rotate(a); c.scale(s, s);
  if (frame) {
    c.strokeStyle = Lc(.13); c.lineWidth = 3; c.strokeRect(80, -40, 1000, 560); c.beginPath(); c.moveTo(80, -6); c.lineTo(1080, -6); c.stroke(); c.fillStyle = Lc(.26);
    [102, 124, 146].forEach(function (x) { c.beginPath(); c.arc(x, -23, 6, 0, 6.3); c.fill(); });
    c.fillStyle = Lc(.07); for (var i = 0; i < 8; i++) { c.fillRect(250, 40 + i * 34, 120 + ((i * 97) % 260), 10); }
  }
  c.beginPath(); c.moveTo(CUR[0][0], CUR[0][1]); for (var j = 1; j < CUR.length; j++) c.lineTo(CUR[j][0], CUR[j][1]); c.closePath();
  c.fillStyle = Lc(.13); c.fill(); c.lineJoin = 'round'; c.lineWidth = 13; c.strokeStyle = Lc(lum == null ? 1 : lum); c.stroke();
  c.restore();
};
FS.glow = function (c, x, y, r, a) {
  if (a <= 0 || r <= 0) return;
  c.save(); c.globalCompositeOperation = 'lighter'; var gr = c.createRadialGradient(x, y, 0, x, y, r); gr.addColorStop(0, 'rgba(0,0,255,' + FS.clamp(a, 0, 1) + ')'); gr.addColorStop(1, 'rgba(0,0,255,0)'); c.fillStyle = gr; c.fillRect(x - r, y - r, r * 2, r * 2); c.restore();
};
FS.vgrad = function (c, x, y, r, a, b) { var g = c.createRadialGradient(x, y, 0, x, y, r); g.addColorStop(0, a); g.addColorStop(1, b); return g; };

/* Deterministic halftone field. Ripples are data: {x,y,t0,s,v,w,life}. */
FS.Field = function (cv, o) {
  o = o || {};
  var ctx = cv.getContext('2d');
  var off = document.createElement('canvas'), oc = off.getContext('2d', { willReadFrequently: true });
  var F = { W: cv.width, H: cv.height, cell: o.cell || 10, ripples: [] };
  F.cols = Math.ceil(F.W / F.cell); F.rows = Math.ceil(F.H / F.cell);
  off.width = F.cols; off.height = F.rows;
  var n = F.cols * F.rows, R = FS.rng(o.seed || 11);
  var dust = new Float32Array(n), ph = new Float32Array(n), mask = new Float32Array(n);
  var dustP = o.dust == null ? .06 : o.dust;
  for (var i = 0; i < n; i++) { dust[i] = R() < dustP ? .4 + R() * .6 : 0; ph[i] = R() * 6.2832; mask[i] = 1; }
  F.setPlates = function (plates) {
    for (var i = 0; i < n; i++) mask[i] = 1;
    (plates || []).forEach(function (p) {
      var fe = p[4] == null ? 28 : p[4];
      for (var y = 0; y < F.rows; y++) for (var x = 0; x < F.cols; x++) {
        var cx = (x + .5) * F.cell, cy = (y + .5) * F.cell;
        var dx = Math.max(p[0] - cx, 0, cx - (p[0] + p[2])), dy = Math.max(p[1] - cy, 0, cy - (p[1] + p[3]));
        var d = Math.sqrt(dx * dx + dy * dy), m = fe > 0 ? FS.clamp(d / fe, 0, 1) : (d > 0 ? 1 : 0);
        var k = y * F.cols + x; if (m < mask[k]) mask[k] = m;
      }
    });
  };
  F.setPlates(o.plates);
  F.draw = function (t, ripples) {
    var cols = F.cols, rows = F.rows, cell = F.cell;
    oc.setTransform(1, 0, 0, 1, 0, 0); oc.globalCompositeOperation = 'source-over'; oc.fillStyle = '#000'; oc.fillRect(0, 0, cols, rows);
    oc.setTransform(cols / F.W, 0, 0, rows / F.H, 0, 0); if (o.scene) o.scene(oc, F.W, F.H, t);
    var d = oc.getImageData(0, 0, cols, rows).data;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    if (o.bg === false) ctx.clearRect(0, 0, F.W, F.H); else { ctx.fillStyle = FS.C.void; ctx.fillRect(0, 0, F.W, F.H); }
    var pB = new Path2D(), pM = new Path2D(), pE = new Path2D();
    var Rp = (ripples || F.ripples).filter(function (k) { return t >= k.t0 && t - k.t0 < (k.life || 1.9); });
    var rr = cell * .5 * (o.dotScale || 1.12), tw = o.twinkle == null ? 1.7 : o.twinkle;
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < cols; x++) {
        var i = y * cols + x, m = mask[i]; if (m <= 0) continue;
        var L = d[i * 4] / 255, E = d[i * 4 + 2] / 255, cx = (x + .5) * cell, cy = (y + .5) * cell;
        if (L < .03) { var du = dust[i]; L = du > 0 ? du * (o.dustLum || .09) * (.55 + .45 * Math.sin(t * tw + ph[i])) : 0; }
        var rp = 0, ox = 0, oy = 0;
        for (var k = 0; k < Rp.length; k++) {
          var q = Rp[k], dx = cx - q.x, dy = cy - q.y, dd = Math.sqrt(dx * dx + dy * dy), age = t - q.t0, fr = age * (q.v || 780), life = q.life || 1.9;
          var b = (dd - fr) / (q.w || 56); b = Math.exp(-b * b) * (q.s == null ? 1.4 : q.s) * (1 - age / life);
          if (b > .02) { rp += b; var inv = 1 / (dd || 1); ox += dx * inv * b * 4; oy += dy * inv * b * 4; }
        }
        var lum = L + rp * (L > .05 ? .4 : .26); if (E > .05) lum = Math.max(lum, E * .62);
        lum *= m; if (lum > 1) lum = 1;
        var r = rr * Math.sqrt(lum); if (r < (o.minR || .38)) continue;
        var e = (E + rp * .9) * m, P = e > .5 ? pE : (e > .18 ? pM : pB), px = cx + ox, py = cy + oy;
        P.moveTo(px + r, py); P.arc(px, py, r, 0, 6.2832);
      }
    }
    ctx.fillStyle = 'rgb(' + BONE + ')'; ctx.fill(pB); ctx.fillStyle = FS.C.mid; ctx.fill(pM); ctx.fillStyle = 'rgb(' + EMBER + ')'; ctx.fill(pE);
  };
  return F;
};

/* Dot-matrix pointer mark (21-reach), tip dot in ember. */
FS.ARROW = ['#', '##', '###', '####', '#####', '######', '#######', '########', '#########', '##########', '######', '##.##', '#...##', '....##', '.....##', '.....##'];
FS.ARROW_M = ['#', '##', '###', '####', '#####', '######', '#######', '########', '####', '#.##', '...##', '...##'];
FS.ARROW_S = ['#', '##', '###', '####', '#####', '######', '###', '#.##', '...#'];
FS.markSVG = function (h, opt) {
  opt = opt || {};
  var rows = opt.rows || (h <= 20 ? FS.ARROW_S : FS.ARROW), W = 0, n = rows.length, s = '';
  var col = opt.dark ? '#0A0A0A' : (opt.color || FS.C.bone), tipR = opt.tipR || .5, r = opt.r || .42;
  var defs = '';
  if (opt.glow) defs = '<defs><radialGradient id="mg' + (opt.id || 0) + '"><stop offset="0" stop-color="#FF5B1F" stop-opacity=".55"/><stop offset="1" stop-color="#FF5B1F" stop-opacity="0"/></radialGradient></defs><circle cx=".5" cy=".5" r="' + opt.glow + '" fill="url(#mg' + (opt.id || 0) + ')"/>';
  rows.forEach(function (row, y) {
    W = Math.max(W, row.length);
    for (var x = 0; x < row.length; x++) if (row[x] === '#') {
      var tip = x === 0 && y === 0;
      if (!tip) s += '<circle cx="' + (x + .5) + '" cy="' + (y + .5) + '" r="' + r + '" fill="' + col + '"/>';
    }
  });
  s += '<circle cx=".5" cy=".5" r="' + tipR + '" fill="#FF5B1F"/>';
  var pad = opt.pad || 0, vb = (-pad) + ' ' + (-pad) + ' ' + (W + pad * 2) + ' ' + (n + pad * 2), sc = h / (n + pad * 2);
  return '<svg xmlns="http://www.w3.org/2000/svg" width="' + ((W + pad * 2) * sc).toFixed(2) + '" height="' + h + '" viewBox="' + vb + '" overflow="visible" aria-hidden="true">' + defs + s + '</svg>';
};
FS.markInto = function (root) {
  (root || document).querySelectorAll('[data-mark]').forEach(function (el) { el.innerHTML = FS.markSVG(+el.dataset.mark, { dark: el.hasAttribute('data-dark'), rows: el.dataset.rows ? FS[el.dataset.rows] : null }); });
};

/* Crisp pointer (the live-session pointer): tip at (0,0). */
FS.POINTER_D = 'M0 0 L0 82 L19.5 63.5 L32.5 93 L46.5 87 L33.5 58 L60 58 Z';
FS.pointerSVG = function (h, opt) {
  opt = opt || {};
  var sw = opt.sw || 5.5, pad = sw + 2, s = h / (93 + pad * 2);
  var tip = opt.tip ? '<circle cx="0" cy="0" r="' + (opt.tipR || 7) + '" fill="#FF5B1F"/>' : '';
  var glow = opt.glow ? '<circle cx="0" cy="0" r="' + opt.glow + '" fill="url(#pg)"/>' : '';
  return '<svg xmlns="http://www.w3.org/2000/svg" width="' + ((60 + pad * 2) * s).toFixed(2) + '" height="' + h + '" viewBox="' + (-pad) + ' ' + (-pad) + ' ' + (60 + pad * 2) + ' ' + (93 + pad * 2) + '" overflow="visible" aria-hidden="true"><defs><radialGradient id="pg"><stop offset="0" stop-color="#FF5B1F" stop-opacity=".7"/><stop offset="1" stop-color="#FF5B1F" stop-opacity="0"/></radialGradient></defs>' + glow +
    '<path d="' + FS.POINTER_D + '" fill="' + (opt.fill || '#0A0A0A') + '" stroke="' + (opt.stroke || FS.C.bone) + '" stroke-width="' + sw + '" stroke-linejoin="round"/>' + tip + '</svg>';
};

FS.pointerTip = function (h, sw) { sw = sw || 5.5; var pad = sw + 2; return pad * h / (93 + pad * 2); };

/* Static dithered art (Bayer 8x8 or Atkinson), from 21-reach. */
var B8 = [0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26, 12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22, 3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25, 15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21];
FS.dither = function (cv, o) {
  var W = cv.width, H = cv.height, px = o.px || 3, w = Math.ceil(W / px), h = Math.ceil(H / px);
  var off = document.createElement('canvas'); off.width = w; off.height = h; var c = off.getContext('2d', { willReadFrequently: true });
  c.fillStyle = '#000'; c.fillRect(0, 0, w, h); c.save(); c.scale(w / W, h / H); o.draw(c, W, H); c.restore();
  var src = c.getImageData(0, 0, w, h).data, out = c.createImageData(w, h), od = out.data, n = w * h, L = new Float32Array(n), E = new Float32Array(n), i;
  for (i = 0; i < n; i++) { L[i] = src[i * 4] / 255; E[i] = src[i * 4 + 2] / 255; }
  var on = new Uint8Array(n);
  if (o.mode === 'atkinson') {
    var nb = [[1, 0], [2, 0], [-1, 1], [0, 1], [1, 1], [0, 2]];
    for (var y = 0; y < h; y++) for (var x = 0; x < w; x++) { i = y * w + x; var v = L[i], nv = v > .5 ? 1 : 0, er = (v - nv) / 8; on[i] = nv; for (var q = 0; q < 6; q++) { var X = x + nb[q][0], Y = y + nb[q][1]; if (X >= 0 && X < w && Y < h) L[Y * w + X] += er; } }
  } else { for (var y2 = 0; y2 < h; y2++) for (var x2 = 0; x2 < w; x2++) { i = y2 * w + x2; on[i] = L[i] > (B8[(y2 % 8) * 8 + (x2 % 8)] + .5) / 64 ? 1 : 0; } }
  for (i = 0; i < n; i++) {
    var x3 = i % w, y3 = (i / w) | 0, em = E[i] > (B8[(y3 % 8) * 8 + (x3 % 8)] + .5) / 64, col = em ? EMBER : (on[i] ? BONE : null);
    if (col) { od[i * 4] = col[0]; od[i * 4 + 1] = col[1]; od[i * 4 + 2] = col[2]; od[i * 4 + 3] = 255; } else { od[i * 4 + 3] = o.bg === false ? 0 : 255; od[i * 4] = 5; od[i * 4 + 1] = 5; od[i * 4 + 2] = 5; }
  }
  c.putImageData(out, 0, 0);
  var x2d = cv.getContext('2d'); x2d.imageSmoothingEnabled = false; x2d.clearRect(0, 0, W, H); x2d.drawImage(off, 0, 0, w, h, 0, 0, w * px, h * px);
};

/* Illustrative pairing code: finder squares + seeded modules. Not scannable on purpose. */
FS.codeSVG = function (size, seed, opt) {
  opt = opt || {};
  var N = 21, R = FS.rng(seed || 3), s = '', col = opt.color || FS.C.bone;
  function finder(x0, y0) { for (var y = 0; y < 7; y++) for (var x = 0; x < 7; x++) { var ring = x === 0 || y === 0 || x === 6 || y === 6, core = x >= 2 && x <= 4 && y >= 2 && y <= 4; if (ring || core) s += '<circle cx="' + (x0 + x + .5) + '" cy="' + (y0 + y + .5) + '" r=".44" fill="' + col + '"/>'; } }
  finder(0, 0); finder(N - 7, 0); finder(0, N - 7);
  for (var y = 0; y < N; y++) for (var x = 0; x < N; x++) {
    var inF = (x < 8 && y < 8) || (x > N - 9 && y < 8) || (x < 8 && y > N - 9); if (inF) continue;
    if (R() < .46) s += '<circle cx="' + (x + .5) + '" cy="' + (y + .5) + '" r=".4" fill="' + col + '"/>';
  }
  return '<svg xmlns="http://www.w3.org/2000/svg" width="' + size + '" height="' + size + '" viewBox="0 0 ' + N + ' ' + N + '" aria-hidden="true">' + s + '</svg>';
};

FS.arrowSVG = function (h, color) {
  return '<svg xmlns="http://www.w3.org/2000/svg" width="' + (h * 1.25) + '" height="' + h + '" viewBox="0 0 30 24" aria-hidden="true"><path d="M2 12h24M17 3l9 9-9 9" fill="none" stroke="' + (color || 'currentColor') + '" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/></svg>';
};
FS.checkSVG = function (h, color) {
  return '<svg xmlns="http://www.w3.org/2000/svg" width="' + h + '" height="' + h + '" viewBox="0 0 24 24" aria-hidden="true"><path d="M4 12.5l5 5L20 6.5" fill="none" stroke="' + (color || 'currentColor') + '" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/></svg>';
};

FS.fontsReady = function () {
  var loads = ['800 40px Doto', '900 40px Doto', '400 40px Geist', '600 40px Geist', '700 40px Geist', '500 40px "Geist Mono"', 'italic 400 40px "Instrument Serif"'].map(function (f) { return document.fonts.load(f); });
  return Promise.all(loads).then(function () { return document.fonts.ready; });
};

FS.h = function (tag, attrs, html) {
  var e = document.createElement(tag);
  if (attrs) for (var k in attrs) { if (k === 'style' && typeof attrs[k] === 'object') Object.assign(e.style, attrs[k]); else if (k === 'class') e.className = attrs[k]; else e.setAttribute(k, attrs[k]); }
  if (html != null) e.innerHTML = html;
  return e;
};

/* Doto text helper: strips nothing, but wraps punctuation in Geist so Doto never renders it. */
FS.dt = function (s) {
  return String(s).replace(/([.,:;!?'’“”…—–()\-])/g, '<span class="pd">$1</span>');
};
})(window);
