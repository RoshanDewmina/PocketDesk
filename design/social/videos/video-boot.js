(function () {
'use strict';
var id = V.q.get('id') || 'v01', def = V.defs[id];
if (!def) throw new Error('no video ' + id);
window.SPEC = { w: V.W, h: V.H, fps: def.fps || 30, dur: def.dur, id: id };
window.seek = function (t) { def.frame(t); return Promise.resolve(); };
window.__ready = FS.fontsReady().then(function () {
  def.build(V);
  def.frame(0);
  return new Promise(function (r) { requestAnimationFrame(function () { requestAnimationFrame(r); }); });
});
if (!V.q.get('render')) {
  window.__ready.then(function () {
    var t0 = performance.now();
    (function loop(now) { def.frame(((now - t0) / 1000) % def.dur); requestAnimationFrame(loop); })(t0);
  });
}
})();
