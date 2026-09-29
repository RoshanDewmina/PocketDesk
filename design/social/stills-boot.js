(function () {
'use strict';
var SK = window.SK;
window.__ready = FS.fontsReady().then(function () {
  var fn = SK.B[SK.ID] || SK.B[SK.ID.replace(/-[a-z0-9]+$/, '')];
  if (!fn) throw new Error('no builder for ' + SK.ID);
  return fn();
}).then(function () {
  FS.markInto(SK.root);
  return new Promise(function (r) { requestAnimationFrame(function () { requestAnimationFrame(r); }); });
});
})();
