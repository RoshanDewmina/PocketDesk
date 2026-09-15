const ACTIONS = new Set(['move', 'click', 'right', 'double', 'dragDown', 'dragUp', 'scroll', 'text', 'key', 'release']);
const MODIFIERS = new Set(['command', 'shift', 'option', 'control']);
const encoder = new TextEncoder();

export function validDecimal(value) { return typeof value === 'string' && /^(0|[1-9]\d*)$/.test(value) && Number.isSafeInteger(Number(value)); }
export function validToken(token) { return typeof token === 'string' && /^[0-9a-f]{32}$/.test(token); }
export function validSession(session) { return typeof session === 'string' && /^[0-9a-f]{64}$/.test(session); }
export function validateAction(action) {
  if (!action || !ACTIONS.has(action.action)) return false;
  if (!Number.isFinite(action.x ?? 0) || !Number.isFinite(action.y ?? 0) || Math.abs(action.x ?? 0) > 20000 || Math.abs(action.y ?? 0) > 20000) return false;
  const modifiers = action.modifiers ?? [];
  if (!Array.isArray(modifiers) || modifiers.length > 4 || !modifiers.every((item) => MODIFIERS.has(item))) return false;
  if (encoder.encode(action.text ?? '').byteLength > 4096 || (action.text ?? '').length > 1024 || encoder.encode(action.key ?? '').byteLength > 32) return false;
  return true;
}
export function createPacket({ session, sequence, revision, frameToken, action }) {
  const normalized = { x: 0, y: 0, text: '', key: '', modifiers: [], epoch: Number(revision), ...action };
  if (normalized.action === 'key' && typeof normalized.key === 'string') normalized.key = normalized.key.trim().toLowerCase();
  if (!validSession(session) || !validDecimal(sequence) || Number(sequence) < 1 || !validDecimal(revision) || !validToken(frameToken) || normalized.epoch !== Number(revision) || !validateAction(normalized)) throw new TypeError('Invalid browser control packet');
  return { type: 'input', session, sequence, revision, frameToken, action: normalized };
}
export function releasePacket({ session, sequence, revision = '0' }) {
  if (!validSession(session) || !validDecimal(sequence) || Number(sequence) < 1 || !validDecimal(revision)) throw new TypeError('Invalid release packet');
  return { type: 'input', session, sequence, revision, frameToken: '00000000000000000000000000000000', action: { action: 'release', x: 0, y: 0, text: '', key: '', modifiers: [], epoch: Number(revision) } };
}
