import { describe, expect, test } from 'bun:test';
import { crc32c, decodeMarker } from '../src/viewer/marker.js';
import { markerSourceRect } from '../src/diag/marker-crop.js';

function numberBits(value: number, count: number) { return Array.from({ length: count }, (_, index) => (value >>> (count - index - 1)) & 1); }

function frameWithMarker(width: number, height: number, token: number[], corrupt = false) {
  const data = new Uint8ClampedArray(width * height * 4);
  const payload = [1, ...token];
  const bits = [...numberBits(0x50444231, 32), ...numberBits(1, 8), ...payload.slice(1).flatMap((byte) => numberBits(byte, 8)), ...numberBits((crc32c(new Uint8Array(payload)) ^ (corrupt ? 1 : 0)) >>> 0, 32)];
  const originX = width - 88 + 4, originY = height - 48 + 4;
  bits.forEach((bit, index) => {
    const row = Math.floor(index / 20), column = index % 20;
    const x = originX + column * 4 + 2, y = originY + row * 4 + 2;
    const offset = (y * width + x) * 4;
    data[offset] = data[offset + 1] = data[offset + 2] = bit ? 255 : 0;
    data[offset + 3] = 255;
  });
  return { width, height, data };
}

function cropToMarker(image: { width: number; height: number; data: Uint8ClampedArray }) {
  const rect = markerSourceRect(image.width, image.height);
  if (!rect) return null;
  const data = new Uint8ClampedArray(rect.sw * rect.sh * 4);
  for (let row = 0; row < rect.sh; row += 1) {
    for (let column = 0; column < rect.sw; column += 1) {
      const srcOffset = ((rect.sy + row) * image.width + (rect.sx + column)) * 4;
      const dstOffset = (row * rect.sw + column) * 4;
      data.set(image.data.subarray(srcOffset, srcOffset + 4), dstOffset);
    }
  }
  return { width: rect.sw, height: rect.sh, data };
}

const token = Array.from({ length: 16 }, (_, i) => i + 1);
const sizes: Array<[number, number]> = [[88, 48], [200, 100], [640, 480], [1920, 1080]];

describe('marker crop matches the full-frame decode', () => {
  for (const [width, height] of sizes) {
    test(`decodes identically at ${width}x${height}`, () => {
      const full = frameWithMarker(width, height, token);
      const cropped = cropToMarker(full);
      expect(decodeMarker(cropped)).toEqual(decodeMarker(full));
      expect(decodeMarker(full)?.token).toBe('0102030405060708090a0b0c0d0e0f10');
    });
  }
  test('rejects a corrupted marker identically in both modes', () => {
    const full = frameWithMarker(200, 100, token, true);
    expect(decodeMarker(full)).toBeNull();
    expect(decodeMarker(cropToMarker(full))).toBeNull();
  });
  test('fails closed for frames at or below the marker footprint', () => {
    expect(markerSourceRect(80, 48)).toBeNull();
    expect(markerSourceRect(88, 40)).toBeNull();
    expect(markerSourceRect(0, 0)).toBeNull();
    expect(markerSourceRect(Number.NaN, 48)).toBeNull();
    expect(markerSourceRect(88, 48)).toEqual({ sx: 0, sy: 0, sw: 88, sh: 48 });
  });
});
