const SYNC = 0x50444231;
export function crc32c(bytes) { let crc = 0xffffffff; for (const byte of bytes) { crc ^= byte; for (let bit = 0; bit < 8; bit += 1) crc = (crc >>> 1) ^ (crc & 1 ? 0x82f63b78 : 0); } return (crc ^ 0xffffffff) >>> 0; }
function bitsToNumber(bits) { return bits.reduce((value, bit) => (value * 2) + bit, 0); }
function hex(bytes) { return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join(''); }
export function decodeMarker(image) {
  if (!image || !Number.isInteger(image.width) || !Number.isInteger(image.height) || image.width < 88 || image.height < 48 || !(image.data instanceof Uint8ClampedArray)) return null;
  const bits = []; const originX = image.width - 88 + 4; const originY = image.height - 48 + 4;
  for (let row = 0; row < 10; row += 1) for (let column = 0; column < 20; column += 1) { const x = originX + column * 4 + 2; const y = originY + row * 4 + 2; const offset = (y * image.width + x) * 4; const luminance = image.data[offset] + image.data[offset + 1] + image.data[offset + 2]; bits.push(luminance > 382 ? 1 : 0); }
  if (bitsToNumber(bits.slice(0, 32)) !== SYNC || bitsToNumber(bits.slice(32, 40)) !== 1) return null;
  const token = new Uint8Array(16); for (let index = 0; index < 16; index += 1) token[index] = bitsToNumber(bits.slice(40 + index * 8, 48 + index * 8));
  const reported = bitsToNumber(bits.slice(168, 200)); const payload = new Uint8Array([1, ...token]);
  return crc32c(payload) === reported ? { token: hex(token), version: 1 } : null;
}
