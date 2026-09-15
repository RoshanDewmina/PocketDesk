export function resolveMarkerMode(search) { return new URLSearchParams(search).get('marker') === 'full' ? 'full' : 'crop'; }

function parseTile(value) {
  if (typeof value !== 'string') return null;
  const parts = value.split(',').map(Number);
  if (parts.length !== 4 || parts.some((n) => !Number.isFinite(n) || n < 0)) return null;
  const [x, y, w, h] = parts;
  return w > 0 && h > 0 ? { x, y, w, h } : null;
}

export function parseDiagParams(search) {
  const params = new URLSearchParams(search);
  const bench = Number.parseInt(params.get('bench') ?? '', 10);
  return {
    diag: params.get('diag') === '1',
    marker: resolveMarkerMode(search),
    bench: Number.isFinite(bench) && bench > 0 ? Math.min(bench, 1000) : 110,
    tile: parseTile(params.get('tile')),
  };
}

export function resolveTile(tile, videoWidth, videoHeight) {
  if (tile) return tile;
  const w = 64, h = 64;
  return { x: Math.max(0, Math.round(((videoWidth || 0) - w) / 2)), y: Math.max(0, Math.round(((videoHeight || 0) - h) / 2)), w, h };
}
