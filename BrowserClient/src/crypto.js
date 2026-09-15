const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });
export function canonical(fields) {
  if (!Array.isArray(fields) || fields.length > 32 || fields.some(x => typeof x !== 'string' || encoder.encode(x).length > 262144)) throw new Error('Invalid transcript');
  const parts = ['PocketDesk/browser/1', ...fields].map(x => encoder.encode(x));
  const out = new Uint8Array(parts.reduce((n, p) => n + 4 + p.length, 0));
  const view = new DataView(out.buffer); let offset = 0;
  for (const part of parts) { view.setUint32(offset, part.length); offset += 4; out.set(part, offset); offset += part.length; }
  return out;
}
export const hex = bytes => Array.from(new Uint8Array(bytes), x => x.toString(16).padStart(2, '0')).join('');
export const random = () => hex(crypto.getRandomValues(new Uint8Array(32)));
export const hash = async bytes => hex(await crypto.subtle.digest('SHA-256', bytes));
const b64 = bytes => { let text = ''; for (const byte of new Uint8Array(bytes)) text += String.fromCharCode(byte); return btoa(text); };
function unb64(value) {
  if (typeof value !== 'string' || value.length > 350000) throw new Error('Invalid encoding');
  const bytes = Uint8Array.from(atob(value), c => c.charCodeAt(0));
  if (b64(bytes) !== value) throw new Error('Noncanonical encoding');
  return bytes;
}
export async function generateIdentity() {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign', 'verify']);
  return { privateKey: pair.privateKey, publicKey: b64(await crypto.subtle.exportKey('raw', pair.publicKey)) };
}
export async function generateEphemeral() {
  const pair = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']);
  return { privateKey: pair.privateKey, publicKey: b64(await crypto.subtle.exportKey('raw', pair.publicKey)) };
}
export async function sign(fields, key) { return b64(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, canonical(fields))); }
export async function verify(fields, signature, publicKey) {
  try {
    const sig = unb64(signature), raw = unb64(publicKey);
    if (sig.length !== 64 || raw.length !== 65 || raw[0] !== 4) return false;
    const key = await crypto.subtle.importKey('raw', raw, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
    return await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, sig, canonical(fields));
  } catch { return false; }
}
export async function sharedKey(privateKey, publicKey, challenge) {
  const raw = unb64(publicKey); if (raw.length !== 65 || raw[0] !== 4) throw new Error('Invalid peer key');
  const peer = await crypto.subtle.importKey('raw', raw, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const bits = await crypto.subtle.deriveBits({ name: 'ECDH', public: peer }, privateKey, 256);
  const key = await crypto.subtle.importKey('raw', bits, 'HKDF', false, ['deriveKey']);
  return crypto.subtle.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt: await crypto.subtle.digest('SHA-256', canonical(challenge)), info: encoder.encode('PocketDesk/browser/1/signaling') }, key, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
}
function parameters(session, direction, sequence, challengeHash) {
  if (!/^[a-f0-9]{64}$/.test(session) || !/^[a-f0-9]{64}$/.test(challengeHash) || !['host', 'browser'].includes(direction) || !/^[1-9][0-9]*$/.test(String(sequence)) || !Number.isSafeInteger(Number(sequence))) throw new Error('Invalid envelope');
  const nonce = new Uint8Array(12); const view = new DataView(nonce.buffer);
  view.setUint32(0, direction === 'host' ? 1 : 2); view.setBigUint64(4, BigInt(sequence));
  return { name: 'AES-GCM', iv: nonce, additionalData: canonical(['signal', session, direction, String(sequence), challengeHash]), tagLength: 128 };
}
export async function seal(signal, key, session, direction, sequence, challengeHash) {
  const data = encoder.encode(JSON.stringify(signal)); if (data.length > 131072) throw new Error('Signal too large');
  return { direction, sequence: String(sequence), payload: b64(await crypto.subtle.encrypt(parameters(session, direction, sequence, challengeHash), key, data)) };
}
export async function open(envelope, key, session, direction, challengeHash) {
  if (envelope.direction !== direction || typeof envelope.sequence !== 'string') throw new Error('Wrong direction');
  const data = unb64(envelope.payload); if (data.length > 131088) throw new Error('Signal too large');
  return JSON.parse(decoder.decode(await crypto.subtle.decrypt(parameters(session, direction, envelope.sequence, challengeHash), key, data)));
}
// The setup relay never receives the enrollment secret or proposed browser key.
export async function sealEnrollment(offer, peerID, publicKey) {
  if (!/^[a-f0-9]{64}$/.test(offer.secret) || !/^[a-f0-9]{64}$/.test(offer.hostID) || !/^[a-f0-9]{64}$/.test(peerID)) throw new Error('Invalid enrollment');
  const raw = unb64(publicKey); if (raw.length !== 65 || raw[0] !== 4) throw new Error('Invalid browser key');
  const bytes = Uint8Array.from(offer.secret.match(/../g), value => parseInt(value, 16));
  const key = await crypto.subtle.importKey('raw', bytes, 'AES-GCM', false, ['encrypt']);
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const parameters = { name: 'AES-GCM', iv: nonce, additionalData: canonical(['enroll', offer.hostID, offer.url]), tagLength: 128 };
  const payload = await crypto.subtle.encrypt(parameters, key, encoder.encode(JSON.stringify({ peerID, publicKey })));
  return { nonce: b64(nonce), payload: b64(payload) };
}
