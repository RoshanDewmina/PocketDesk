(function () {
'use strict';
var q = new URLSearchParams(location.search), ID = q.get('id') || 'avatar', W = +q.get('w') || 1080, H = +q.get('h') || 1080;
var root = document.getElementById('root');
root.style.width = W + 'px'; root.style.height = H + 'px';
document.body.style.width = W + 'px'; document.body.style.height = H + 'px';
var h = FS.h, dt = FS.dt, C = FS.C;
var B = {};
window.SK = { q: q, ID: ID, W: W, H: H, root: root, B: B };

function canvas(z) { var c = h('canvas', { class: 'cv-full' }); c.width = W; c.height = H; if (z != null) c.style.zIndex = z; root.appendChild(c); return c; }
function field(opts) { var c = canvas(opts.z); var F = FS.Field(c, opts); F.draw(opts.t || 3, opts.ripples || []); return F; }
function add(html, style, cls) { var e = h('div', { class: 'abs z5 ' + (cls || '') }, html); Object.assign(e.style, style || {}); root.appendChild(e); return e; }
function brand(size) { return '<span class="brand" style="font-size:' + size + 'px"><span data-mark="' + Math.round(size * 1.05) + '"></span><span class="wm">farside</span></span>'; }
function markCentroid(rows) { var sx = 0, sy = 0, n = 0, w = 0; rows.forEach(function (r, y) { w = Math.max(w, r.length); for (var x = 0; x < r.length; x++) if (r[x] === '#') { sx += x + .5; sy += y + .5; n++; } }); return { cx: sx / n, cy: sy / n, w: w, h: rows.length }; }

/* ---------------- AVATAR ---------------- */
function avatarMark(rows, heightFrac, tipR, glowR, o) {
  o = o || {};
  var g = markCentroid(rows), unit = (H * heightFrac) / g.h;
  var ox = W / 2 - unit * (g.w / 2 * .45 + g.cx * .55) + (o.dx || 0) * W, oy = H / 2 - unit * (g.h / 2 * .5 + g.cy * .5) + (o.dy || 0) * H;
  var s = '<svg xmlns="http://www.w3.org/2000/svg" width="' + W + '" height="' + H + '" viewBox="0 0 ' + W + ' ' + H + '">';
  s += '<defs><radialGradient id="eg"><stop offset="0" stop-color="#FF5B1F" stop-opacity=".5"/><stop offset=".4" stop-color="#FF5B1F" stop-opacity=".14"/><stop offset="1" stop-color="#FF5B1F" stop-opacity="0"/></radialGradient></defs>';
  var tx = ox + unit * .5, ty = oy + unit * .5;
  if (glowR) s += '<circle cx="' + tx + '" cy="' + ty + '" r="' + unit * glowR + '" fill="url(#eg)"/>';
  if (o.rings) o.rings.forEach(function (rg) {
    var R = unit * rg[0], n = Math.round(2 * Math.PI * R / (unit * rg[2]));
    for (var k = 0; k < n; k++) {
      var a = k / n * Math.PI * 2 + (rg[3] || 0), x = tx + Math.cos(a) * R, y = ty + Math.sin(a) * R;
      var inArrow = a > -.25 && a < 1.45;
      if (inArrow && !o.ringOver) continue;
      s += '<circle cx="' + x.toFixed(1) + '" cy="' + y.toFixed(1) + '" r="' + (unit * rg[1]).toFixed(1) + '" fill="#FF5B1F" opacity="' + (rg[4] || 1) + '"/>';
    }
  });
  rows.forEach(function (r, y) { for (var x = 0; x < r.length; x++) if (r[x] === '#' && !(x === 0 && y === 0)) s += '<circle cx="' + (ox + unit * (x + .5)) + '" cy="' + (oy + unit * (y + .5)) + '" r="' + unit * (o.r || .44) + '" fill="#EDE8DF"/>'; });
  s += '<circle cx="' + tx + '" cy="' + ty + '" r="' + unit * tipR + '" fill="#FF5B1F"/></svg>';
  return s;
}
B.avatar = function () {
  var v = q.get('v') || 'a';
  if (v === 'a') add(avatarMark(FS.ARROW, .62, .74, 4.6, { r: .45 }), { left: 0, top: 0 });
  else if (v === 'b') add(avatarMark(FS.ARROW, .5, .74, 3.2, { r: .45, dx: .06, dy: .05, rings: [[2.9, .3, 1.05, 0, 1], [4.7, .24, 1.15, .1, .7], [6.5, .18, 1.25, .2, .42]] }), { left: 0, top: 0 });
  else if (v === 'c') add(avatarMark(FS.ARROW_S, .5, .7, 3.6, { r: .45 }), { left: 0, top: 0 });
};

B['avatar-preview'] = function () {
  var out = q.get('out');
  var srcA = 'file://' + out + '/avatars/farside-avatar-1080.png', srcB = 'file://' + out + '/avatars/farside-avatar-alt-1080.png';
  var sizes = [[400, 'X upload · 400'], [150, 'IG profile · web'], [110, 'IG / Threads · app'], [48, 'X timeline'], [32, 'feed / comments']];
  function row(src, y, label, light) {
    add('<div class="mono-l" style="font-size:20px"><b>' + label + '</b></div>', { left: '64px', top: (y - 44) + 'px' });
    var x = 64;
    sizes.forEach(function (s) {
      var bg = light ? '#F2F1EE' : '#1A1A1A';
      add('<div style="width:' + (s[0] + 28) + 'px;height:' + (s[0] + 28) + 'px;border-radius:24px;background:' + bg + ';display:grid;place-items:center"><img src="' + src + '" style="width:' + s[0] + 'px;height:' + s[0] + 'px;border-radius:50%;display:block"></div><div class="cap" style="font-size:15px;margin-top:10px;letter-spacing:.1em;color:' + '#8C877F' + '">' + s[1] + '</div>', { left: x + 'px', top: y + 'px' });
      x += s[0] + 28 + 34;
    });
  }
  add('<div class="brand" style="font-size:30px"><span data-mark="30"></span><span class="wm">farside</span></div>', { left: '64px', top: '40px' });
  add('<div class="cap" style="font-size:18px">Avatar · circle-safe preview · same file on X, Instagram, Threads, TikTok</div>', { right: '64px', top: '50px' });
  row(srcA, 170, 'Primary · the mark · farside-avatar-1080.png', false);
  row(srcA, 700, 'Primary on light mode', true);
  add('<div style="position:absolute;left:0;top:0"></div>', {});
  var alt = add('<div class="mono-l" style="font-size:20px"><b>Alternate · the click · farside-avatar-alt-1080.png</b></div>', { left: '64px', top: '1186px' });
  var x = 64;
  sizes.forEach(function (s) {
    add('<div style="width:' + (s[0] + 28) + 'px;height:' + (s[0] + 28) + 'px;border-radius:24px;background:#1A1A1A;display:grid;place-items:center"><img src="' + srcB + '" style="width:' + s[0] + 'px;height:' + s[0] + 'px;border-radius:50%;display:block"></div><div class="cap" style="font-size:15px;margin-top:10px;letter-spacing:.1em">' + s[1] + '</div>', { left: x + 'px', top: '1230px' });
    x += s[0] + 28 + 34;
  });
};

/* ---------------- X HEADER 1500x500 ---------------- */
B['banner-x'] = function () {
  var cx = 600, cy = 226;
  field({ cell: 8, dust: .05, seed: 5, t: 2.2,
    plates: [[830, 110, 640, 300, 36], [30, 24, 200, 44, 16], [676, 24, 170, 44, 16]],
    ripples: [{ x: cx, y: cy, t0: 1.96, s: .8, v: 400, w: 11, life: 1.2 }],
    scene: function (c, w, hh) {
      FS.drawCursor(c, cx + 5, cy + 2, .52, -.02, false);
      FS.drawHand(c, cx - 3, cy + 2, .66, -.34);
      FS.glow(c, cx, cy, 34, .9);
    } });
  add('<p class="cap" style="font-size:17px">Phone <b>side</b></p>', { left: '48px', top: '38px' });
  add('<p class="cap" style="font-size:17px">Mac <b>side</b></p>', { left: '694px', top: '38px' });
  add('<h1 class="doto" style="font-size:58px;line-height:1.06">Your Mac is far<span class="pd">.</span><br>Your reach <span class="it">isn’t.</span></h1><p class="mono" style="margin-top:22px;font:500 18px/1.4 var(--mono);letter-spacing:.12em;text-transform:uppercase;color:var(--ash)">Control your Mac from <b style="color:var(--bone);font-weight:500">iPhone</b> and <b style="color:var(--bone);font-weight:500">iPad</b></p>', { left: '860px', top: '158px' });
};
Object.assign(window.SK, { canvas: canvas, field: field, add: add, brand: brand });
})();
