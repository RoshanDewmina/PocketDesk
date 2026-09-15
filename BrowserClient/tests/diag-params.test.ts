import { describe, expect, test } from 'bun:test';
import { parseDiagParams, resolveMarkerMode, resolveTile } from '../src/diag/params.js';

describe('diagnostic URL params default to the disabled, unmodified path', () => {
  test('an empty query stays off, crop, default bench, no tile', () => {
    expect(parseDiagParams('')).toEqual({ diag: false, marker: 'crop', bench: 110, tile: null });
  });
  test('opts in only on exact matches', () => {
    expect(parseDiagParams('?diag=1&marker=full&bench=25&tile=1,2,3,4')).toEqual({ diag: true, marker: 'full', bench: 25, tile: { x: 1, y: 2, w: 3, h: 4 } });
    expect(parseDiagParams('?diag=true')).toEqual(expect.objectContaining({ diag: false }));
    expect(resolveMarkerMode('?marker=something-else')).toBe('crop');
  });
  test('clamps an out-of-range bench count and rejects a malformed tile', () => {
    expect(parseDiagParams('?bench=5000').bench).toBe(1000);
    expect(parseDiagParams('?bench=0').bench).toBe(110);
    expect(parseDiagParams('?bench=-5').bench).toBe(110);
    expect(parseDiagParams('?tile=1,2,3').tile).toBeNull();
    expect(parseDiagParams('?tile=-1,2,3,4').tile).toBeNull();
    expect(parseDiagParams('?tile=1,2,0,4').tile).toBeNull();
  });
});

describe('resolveTile', () => {
  test('falls back to a centered 64x64 default', () => expect(resolveTile(null, 800, 600)).toEqual({ x: 368, y: 268, w: 64, h: 64 }));
  test('keeps an explicit tile untouched', () => expect(resolveTile({ x: 1, y: 2, w: 3, h: 4 }, 800, 600)).toEqual({ x: 1, y: 2, w: 3, h: 4 }));
});
