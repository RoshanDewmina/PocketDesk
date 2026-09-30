// Builds B's layers from the real iPad landscape session screenshot (sample "Notes" desktop only).
import { $ } from "bun";
const SRC = `${process.env.HOME}/Downloads/farside-phone-ipad-landscape-session.png`;
const W = 2420, H = 1668, Y0 = 58, DH = 1513;
const WIN = { x0: 509, y0: 391, x1: 1910, y1: 1236 };
const work = "work";
await $`ffmpeg -v error -y -i ${SRC} -f rawvideo -pix_fmt rgb24 ${work}/ipad.rgb`;
const src = await Bun.file(`${work}/ipad.rgb`).bytes();
const img = new Uint8Array(src);
const idx = (x: number, y: number) => (y * W + x) * 3;
const copy = (dx: number, dy: number, sx: number, sy: number) => { const d = idx(dx, dy), s = idx(sx, sy); img[d] = src[s]; img[d + 1] = src[s + 1]; img[d + 2] = src[s + 2]; };
const fill = (x0: number, y0: number, x1: number, y1: number, rgb: number[]) => { for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) { const d = idx(x, y); img[d] = rgb[0]; img[d + 1] = rgb[1]; img[d + 2] = rgb[2]; } };
// wallpaper patch: same row, tiled from a clean column band (the gradient is vertical only)
const wall = (x0: number, y0: number, x1: number, y1: number, bandL: number, bandW: number) => { for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) copy(x, y, bandL + ((x - x0) % bandW), y); };

// window layer first (from the untouched source + erasures)
fill(555, 626, 1370, 702, [255, 255, 255]);          // "Offline preview · no remote actions" + baked pointer
fill(1050, 410, 1372, 447, [242, 242, 242]);         // title text (re-set in HTML as "Notes")
const ww = WIN.x1 - WIN.x0 + 1, wh = WIN.y1 - WIN.y0 + 1;
const win = new Uint8Array(ww * wh * 3);
for (let y = 0; y < wh; y++) win.set(img.subarray(idx(WIN.x0, WIN.y0 + y), idx(WIN.x0, WIN.y0 + y) + ww * 3), y * ww * 3);
await Bun.write(`${work}/win.rgb`, win);

// desktop layer: remove window + its shadow, and the four corner test labels
wall(440, 330, 1985, 1345, 30, 380);
wall(0, 120, 270, 212, 300, 400);
wall(2130, 120, 2419, 212, 300, 400);
wall(0, 1470, 275, 1570, 300, 360);
wall(2120, 1470, 2419, 1570, 300, 360);
wall(1080, 1556, 1340, 1569, 300, 360);
const desk = img.subarray(idx(0, Y0), idx(0, Y0 + DH));
await Bun.write(`${work}/desk.rgb`, desk);

// handle pill (real Farside dock handle) sits on black below the desktop
await $`ffmpeg -v error -y -f rawvideo -pix_fmt rgb24 -s ${W}x${DH} -i ${work}/desk.rgb ${work}/desk.png`;
await $`ffmpeg -v error -y -f rawvideo -pix_fmt rgb24 -s ${ww}x${wh} -i ${work}/win.rgb ${work}/win.png`;
await $`ffmpeg -v error -y -i ${SRC} -vf crop=160:52:1130:1564 ${work}/handle.png`;
console.log(JSON.stringify({ win: { x: WIN.x0 / W, y: (WIN.y0 - Y0) / DH, w: ww / W, h: wh / DH, titleH: 74 / wh, radius: 24 / ww }, desk: { w: W, h: DH } }));
