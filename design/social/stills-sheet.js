(function () {
'use strict';
var SK = window.SK, B = SK.B, W = SK.W, H = SK.H, box = SK.box, raw = SK.raw;

function sec(y, title, n) { box(80, y, 1440, null, '<div style="display:flex;align-items:baseline;gap:18px;border-top:1.5px solid var(--line);padding-top:18px"><span class="doto" style="font-size:34px;color:var(--ash)">' + n + '</span><span class="mono-l" style="font-size:22px"><b>' + title + '</b></span></div>'); }
function zoneSVG(w, h, sc, parts) {
  var s = '<svg xmlns="http://www.w3.org/2000/svg" width="' + (w * sc) + '" height="' + (h * sc) + '" viewBox="0 0 ' + w + ' ' + h + '"><rect x="1" y="1" width="' + (w - 2) + '" height="' + (h - 2) + '" rx="' + (w * .03) + '" fill="#0B0B0B" stroke="#4A4742" stroke-width="' + (2 / sc) + '"/>';
  parts.forEach(function (p) {
    if (p.fill) s += '<rect x="' + p.x + '" y="' + p.y + '" width="' + p.w + '" height="' + p.h + '" fill="' + p.fill + '" opacity="' + (p.o || .5) + '"/>';
    else s += '<rect x="' + p.x + '" y="' + p.y + '" width="' + p.w + '" height="' + p.h + '" fill="none" stroke="' + (p.stroke || '#EDE8DF') + '" stroke-width="' + (3 / sc) + '" stroke-dasharray="' + (p.dash ? (10 / sc) + ' ' + (8 / sc) : 'none') + '"/>';
  });
  return s + '</svg>';
}

B['cheat-sheet'] = function () {
  raw('<div class="hd" style="left:80px;right:80px;top:64px">' + SK.brand(40) + '<span class="cap" style="font-size:20px">Brand for social · one-page cheat sheet · Reach</span></div>');
  box(80, 150, 1440, null, '<h1 class="h1" style="font-size:120px">Dots<span class="pd">,</span> <span class="it">one</span> ember<span class="pd">.</span></h1><p class="sub" style="font-size:34px;margin-top:18px;max-width:1300px">Black void, bone type, halftone art, and a single ember dot where the fingertip meets the pointer. Everything in the kit is rendered from code: no AI imagery.</p>');

  sec(430, 'Colour', '01');
  var sw = window.SK_COLORS || [['Void', '#050505', 'Every background'], ['Panel', '#121212', 'Cards, UI plates'], ['Bone', '#EDE8DF', 'Type, dots, pointer'], ['Ash', '#8C877F', 'Secondary type'], ['Dim', '#4A4742', 'Decoration only'], ['Ember', '#FF5B1F', 'Contact only']];
  box(80, 500, 1440, null, '<div style="display:grid;grid-template-columns:repeat(6,1fr);gap:16px">' + sw.map(function (c) {
    var dark = c[0] === 'Bone' || c[0] === 'Ash' || c[0] === 'Ember';
    return '<div style="height:190px;border-radius:20px;background:' + c[1] + ';box-shadow:inset 0 0 0 1.5px var(--line2);padding:16px;display:flex;flex-direction:column;justify-content:flex-end;color:' + (dark ? '#0A0A0A' : '#EDE8DF') + '"><b style="font:600 26px var(--ui)">' + c[0] + '</b><span style="font:500 18px var(--mono);letter-spacing:.06em">' + c[1] + '</span><span style="font:400 17px/1.25 var(--ui);opacity:.8;margin-top:4px">' + c[2] + '</span></div>';
  }).join('') + '</div><p class="sub" style="font-size:26px;margin-top:18px"><b>Ember is for contact only:</b> the touch, the click ripple, a live dot, the tip of the mark. Never a decorative word colour. Success is bone plus a check, not green.</p>');

  sec(840, 'Type', '02');
  box(80, 910, 700, null,
    '<div class="mono-l" style="font-size:18px">Display · Doto 800 to 900 · no punctuation</div><div class="doto" style="font-size:84px;line-height:1.05;margin-top:8px">Close the gap</div>' +
    '<div class="mono-l" style="font-size:18px;margin-top:26px">One accent word · Instrument Serif italic</div><div class="ser" style="font-size:84px;margin-top:4px">isn’t.</div>' +
    '<div class="mono-l" style="font-size:18px;margin-top:26px">Body · Geist 400 to 600</div><div style="font:500 34px/1.3 var(--ui);margin-top:6px">Control your Mac from iPhone</div>' +
    '<div class="mono-l" style="font-size:18px;margin-top:26px">Captions · Geist Mono caps, tracked</div><div class="cap" style="font-size:24px;margin-top:8px">Phone <b>side</b> · Mac <b>side</b></div>');
  box(840, 910, 680, null, '<div class="card" style="position:relative;padding:30px 32px"><p style="font:600 28px/1.3 var(--ui)">Rules</p><ul style="margin:14px 0 0 24px;font:400 25px/1.5 var(--ui);color:var(--ash)"><li>Doto never carries punctuation: set <b style="color:var(--bone)">. , ? ’ …</b> in Geist</li><li>Headlines 90 to 150 px on a 1080 frame; one idea per frame</li><li>At most 7 words per video card</li><li>One serif accent word per headline</li><li>Text sits on solid void or panel, never on dots</li><li>Captions at least 22 px; nothing important below 26 px in video</li></ul></div>');

  sec(1420, 'Safe zones', '03');
  var sc = .17;
  box(80, 1490, 1440, null, '<div style="display:flex;gap:40px;align-items:flex-start">' +
    '<figure>' + zoneSVG(1080, 1920, sc, [{ x: 0, y: 0, w: 1080, h: 220, fill: '#FF5B1F', o: .18 }, { x: 0, y: 1500, w: 1080, h: 420, fill: '#FF5B1F', o: .18 }, { x: 960, y: 0, w: 120, h: 1920, fill: '#FF5B1F', o: .18 }, { x: 65, y: 270, w: 895, h: 1170 }]) + '<figcaption class="cap" style="font-size:15px;margin-top:10px;max-width:190px"><b>9:16 video</b><br>text box x 65–960<br>y 270–1440</figcaption></figure>' +
    '<figure>' + zoneSVG(1080, 1350, sc * 1.2, [{ x: 34, y: 0, w: 1012, h: 1350, dash: true }, { x: 64, y: 56, w: 952, h: 1238 }]) + '<figcaption class="cap" style="font-size:15px;margin-top:10px;max-width:230px"><b>IG 4:5 post</b><br>grid shows centre 3:4<br>(dashed) · margins 64</figcaption></figure>' +
    '<figure>' + zoneSVG(1080, 1080, sc * 1.2, [{ x: 135, y: 0, w: 810, h: 1080, dash: true }]) + '<figcaption class="cap" style="font-size:15px;margin-top:10px;max-width:230px"><b>IG 1:1 post</b><br>grid shows centre 810<br>keep the headline in it</figcaption></figure>' +
    '<figure>' + zoneSVG(1500, 500, sc * 1.25, [{ x: 40, y: 334, w: 333, h: 166, fill: '#FF5B1F', o: .25 }, { x: 0, y: 70, w: 1500, h: 360, dash: true }]) + '<figcaption class="cap" style="font-size:15px;margin-top:10px;max-width:320px"><b>X header 1500×500</b><br>avatar covers lower left<br>keep text in the middle band</figcaption></figure>' +
    '</div><p class="sub" style="font-size:24px;margin-top:22px">Orange tint: covered by app UI (TikTok/Reels top 220, bottom 420, right 120). The kit\'s white box is stricter so the same file also clears Meta\'s 14% top and the Reels grid crop. The renderer checks every third frame automatically.</p>');

  sec(1990, 'Do and don’t', '04');
  box(80, 2060, 700, null, '<p style="font:600 28px var(--ui)">Do</p><ul style="margin:12px 0 0 24px;font:400 24px/1.5 var(--ui);color:var(--ash)"><li>Open every video mid-motion with the hook on screen at frame 0</li><li>Say “Free on the same Wi-Fi”; say the Anywhere plan is <b style="color:var(--bone)">coming</b></li><li>Say “agent needs you” is <b style="color:var(--bone)">beta</b></li><li>Upload natively to each app; no watermarks</li><li>Write “Farside” as one word; brand tag #farsideapp</li><li>Reply to every comment in the first hour</li></ul>');
  box(840, 2060, 680, null, '<p style="font:600 28px var(--ui)">Don’t</p><ul style="margin:12px 0 0 24px;font:400 24px/1.5 var(--ui);color:var(--ash)"><li>State a launch date, prices, latency, user counts, ratings or testimonials</li><li>Write “from anywhere” as if it has shipped</li><li>Write “the far side” or use comic imagery; avoid #farside</li><li>Use Apple logos, third-party app logos or AI-generated imagery</li><li>Put a link in the main X post (use the first reply)</li><li>Dither text, controls or the real Mac picture</li></ul>');

  box(80, 2410, 1440, null, '<div style="display:flex;justify-content:space-between;gap:24px;border-top:1.5px solid var(--line);padding-top:18px"><span class="cap" style="font-size:17px">Hashtags · IG 3–5 · TikTok 3–5 · X 0–1 · Threads 1 topic tag</span><span class="cap" style="font-size:17px">Cadence · X 2–3/day · Threads 1–2/day · IG 4–5/wk · TikTok 4–5/wk</span></div>');
};
})();
