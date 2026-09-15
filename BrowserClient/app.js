import { canonical, generateEphemeral, generateIdentity, hash, random, seal, sealEnrollment, open, sharedKey, sign, verify } from './src/crypto.js';
import { createPacket, releasePacket, validDecimal } from './src/control/input.js';
import { decodeMarker } from './src/viewer/marker.js';
import { markerSourceRect } from './src/diag/marker-crop.js';
import { parseDiagParams } from './src/diag/params.js';
import { createDiagController } from './src/diag/controller.js';

const $ = (id) => document.getElementById(id); const text = new TextEncoder();
const status = $('status'); const connect = $('connect'); const end = $('end'); const reveal = $('reveal'); const controls = $('interactive-controls'); const video = $('video'); const viewport = $('viewport'); const message = $('video-message'); const inputState = $('input-state');
let mediaTimeout; let enrollment; let identity; let state = {}; let peer; let channel; let signalSocket; let signalKey; let challengeHash; let admissionAbort; let sentSequence = 0; let receivedSequence = 0; let inputSequence = 0; let marker; let markerCanvas; let markerContext; let frameCallback; let markerTimer; let pendingText; let composing = false; let dragHeld = false; let generation = 0; let incomingSignals = Promise.resolve(); let outgoingSignals = Promise.resolve(); let remoteCandidates = []; let pan = { x: 0, y: 0, zoom: 1 }; const viewportPointers = new Map();

let enrollmentAbort; let enrollmentGeneration = 0;
const diagParams = parseDiagParams(location.search); const markerMode = diagParams.marker;
const diag = diagParams.diag ? createDiagController({ tile: diagParams.tile, benchCount: diagParams.bench, sendAction: (action) => sendAction(action), getVideo: () => video, isFresh: () => controls.dataset.interactive === 'true', getMarkerMode: () => markerMode }) : null;
function say(value) { status.textContent = value; }
function invalidateEnrollment() { enrollmentGeneration += 1; enrollmentAbort?.abort(); enrollmentAbort = undefined; $('enroll').disabled = false; }
function safeError(error) { return error instanceof Error ? error.message.replace(/[\r\n]/g, ' ').slice(0, 140) : 'request failed'; }
function endpoint(path) { if (!enrollment?.url) throw new Error('Enroll this browser first'); return new URL(path, enrollment.url); }
function expiry(value) { if (typeof value !== 'string') return false; const number = Number(value); if (!validDecimal(String(value)) || !Number.isSafeInteger(number)) return false; return (number < 100000000000 ? number * 1000 : number) > Date.now(); }
function recordFields(value, count) { const fields = Array.isArray(value) ? value : value?.fields; return Array.isArray(fields) && fields.length === count && fields.every((field) => typeof field === 'string') ? fields : null; }
async function request(operation, body, signal) { const response = await fetch(endpoint(`/browser-api/${encodeURIComponent(enrollment.hostID)}/${operation}`), { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body), credentials: 'omit', cache: 'no-store', signal }); if (!response.ok) throw new Error(`request refused (${response.status})`); return response.json(); }
function offerFrom(value) {
  if (value.length > 16384 || !value.startsWith('pocketdesk-browser:')) throw new Error('Offer prefix is missing or too large');
  const encoded = value.slice('pocketdesk-browser:'.length);
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) throw new Error('Offer encoding is invalid');
  const parsed = JSON.parse(atob(encoded));
  if (!parsed || parsed.version !== 1 || typeof parsed.url !== 'string' || !/^[a-f0-9]{64}$/.test(parsed.hostID) || !/^[a-f0-9]{64}$/.test(parsed.secret) || typeof parsed.hostKey !== 'string' || parsed.hostKey.length !== 88 || !expiry(parsed.expires)) throw new Error('Offer is invalid or expired');
  const url = new URL(parsed.url), loopback = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  if (url.protocol !== 'https:' && !(loopback && url.protocol === 'http:')) throw new Error('Offer must use HTTPS except exact loopback');
  if (parsed.url !== url.origin || url.origin !== location.origin || url.username || url.password || url.search || url.hash) throw new Error('Offer must match this viewer origin exactly');
  return parsed;
}
function openDatabase() { return new Promise((resolve, reject) => { const request = indexedDB.open('pocketdesk-browser-v1', 1); request.onupgradeneeded = () => request.result.createObjectStore('browser'); request.onsuccess = () => resolve(request.result); request.onerror = () => reject(new Error('Local browser key storage is unavailable')); }); }
let storageQueue = Promise.resolve();
function localCurrent(current) { if (current !== enrollmentGeneration) throw new Error('Local enrollment operation ended'); }
function stored(key, value, current = enrollmentGeneration) {
  const writing = arguments.length >= 2;
  const operation = storageQueue.then(async () => {
    const database = await openDatabase();
    try {
      if (writing) localCurrent(current);
      return await new Promise((resolve, reject) => {
        const transaction = database.transaction('browser', writing ? 'readwrite' : 'readonly');
        const store = transaction.objectStore('browser');
        const request = key === null ? store.clear() : writing ? store.put(value, key) : store.get(key);
        transaction.oncomplete = () => resolve(request.result);
        transaction.onabort = transaction.onerror = () => reject(new Error('Local browser storage failed'));
      });
    } finally { database.close(); }
  });
  storageQueue = operation.catch(() => {});
  return operation;
}
async function eraseLocal() {
  invalidateEnrollment(); endSession();
  identity = undefined; enrollment = undefined; connect.disabled = true;
  $('enroll').disabled = true; $('forget').disabled = true;
  try { await stored(null, null); say('Local browser enrollment and key cleared.'); }
  catch { say('Local storage could not be cleared. Close this viewer and clear its site data.'); }
  finally { $('enroll').disabled = false; $('forget').disabled = false; }
}
async function localIdentity(current = enrollmentGeneration) {
  localCurrent(current);
  if (identity) return identity;
  let local = await stored('identity'); localCurrent(current);
  if (!local) {
    local = await generateIdentity(); localCurrent(current);
    await stored('identity', local, current); localCurrent(current);
  }
  identity = local; return local;
}
async function loadEnrollment() {
  $('enroll').disabled = true; $('forget').disabled = true;
  const current = enrollmentGeneration;
  try {
    const saved = await stored('enrollment'); localCurrent(current);
    if (saved && saved.url === location.origin && saved.origin === location.origin && ['view','interactive'].includes(saved.mode) && /^[a-f0-9]{64}$/.test(saved.hostID) && /^[a-f0-9]{64}$/.test(saved.peerID)) {
      await localIdentity(current); localCurrent(current);
      enrollment = saved; connect.disabled = false; say('Enrolled browser is ready. Connect remains explicit.');
    }
  } finally { if (current === enrollmentGeneration) { $('enroll').disabled = false; $('forget').disabled = false; } }
}
function updateControls() { const interactive = state.mode === 'interactive' && state.healthy === true && state.control === true && validDecimal(String(state.revision)); const fresh = marker && performance.now() - marker.at <= 600 && marker.revision === String(state.revision); const enabled = Boolean(channel?.readyState === 'open' && interactive && fresh); if (!enabled && dragHeld) release(); controls.dataset.interactive = String(enabled); $('trackpad').setAttribute('aria-disabled', String(!enabled)); for (const item of controls.querySelectorAll('button,input,select,textarea')) item.disabled = !enabled; $('draft').disabled = !enabled; $('send-text').disabled = !enabled || Boolean(pendingText) || composing; inputState.textContent = enabled ? (pendingText ? 'Text receipt pending; draft retained locally.' : 'Interactive host and decoded frame marker are current.') : 'Controls wait for interactive host consent, capture health, and a valid decoded frame marker.'; }
function currentMarker() { if (!marker || performance.now() - marker.at > 600 || marker.revision !== String(state.revision)) throw new Error('Wait for a current decoded frame marker'); return marker.token; }
function updateViewport() { viewport.classList.toggle('zoom', pan.zoom > 1); viewport.style.setProperty('--zoom', String(pan.zoom)); viewport.style.setProperty('--pan-x', `${pan.x}px`); viewport.style.setProperty('--pan-y', `${pan.y}px`); }
function decodeMarkerRegion(sx, sy, sw, sh, mode) { markerCanvas ??= document.createElement('canvas'); if (markerCanvas.width !== sw || markerCanvas.height !== sh) { markerCanvas.width = sw; markerCanvas.height = sh; } markerContext ??= markerCanvas.getContext('2d', { willReadFrequently: true }); const t0 = diag ? performance.now() : 0; markerContext.drawImage(video, sx, sy, sw, sh, 0, 0, sw, sh); const t1 = diag ? performance.now() : 0; const image = markerContext.getImageData(0, 0, sw, sh); const t2 = diag ? performance.now() : 0; const decoded = decodeMarker(image); const t3 = diag ? performance.now() : 0; diag?.recordMarkerCost(mode, t0, t1, t2, t3); return decoded; }
function decodeFrame() { clearTimeout(mediaTimeout); message.hidden = true; say(state.mode === 'view' ? 'Connected · view only' : 'Connected · controls require current video and host consent'); let decoded; if (video.videoWidth && video.videoHeight) { try { if (markerMode === 'full') decoded = decodeMarkerRegion(0, 0, video.videoWidth, video.videoHeight, 'full'); else { const rect = markerSourceRect(video.videoWidth, video.videoHeight); if (rect) decoded = decodeMarkerRegion(rect.sx, rect.sy, rect.sw, rect.sh, 'crop'); } } catch {} } marker = decoded && validDecimal(String(state.revision)) ? { ...decoded, at: performance.now(), revision: String(state.revision) } : undefined; updateControls(); frameCallback = video.requestVideoFrameCallback?.(decodeFrame); }
function beginMarkerRead() { video.cancelVideoFrameCallback?.(frameCallback); clearInterval(markerTimer); markerTimer = setInterval(updateControls, 100); frameCallback = video.requestVideoFrameCallback?.(decodeFrame); }
function sendRaw(value) { if (channel?.readyState !== 'open') throw new Error('Control channel is unavailable'); channel.send(text.encode(JSON.stringify(value))); diag?.observeBufferedAmount(channel.bufferedAmount); }
function sendAction(action) { if (state.mode !== 'interactive' || !state.healthy || !state.control) throw new Error('Host control is unavailable'); const frameToken = currentMarker(); const packet = createPacket({ session: state.session, sequence: String(++inputSequence), revision: String(state.revision), frameToken, action: { x: 0, y: 0, text: '', key: '', modifiers: [], epoch: Number(state.revision), ...action } }); sendRaw(packet); }
function release() { dragHeld = false; $('drag').textContent = 'Hold drag'; trackPointers.clear(); trackCenter = undefined; if (!state.session || channel?.readyState !== 'open') return; try { sendRaw(releasePacket({ session: state.session, sequence: String(++inputSequence), revision: String(state.revision ?? '0') })); } catch { /* scoped release is best effort during teardown */ } dragHeld = false; $('drag').textContent = 'Hold drag'; }
async function sendSignal(signal, current = generation) { outgoingSignals = outgoingSignals.then(async () => { if (current !== generation || signalSocket?.readyState !== WebSocket.OPEN || !signalKey || !state.session) throw new Error('Session ended'); const envelope = await seal(signal, signalKey, state.session, 'browser', ++sentSequence, challengeHash); if (current !== generation || signalSocket?.readyState !== WebSocket.OPEN) throw new Error('Session ended'); signalSocket.send(JSON.stringify({ type: 'signal', session: state.session, envelope })); }); return outgoingSignals; }
async function handleSignal(signal, current) {
  const localPeer = peer;
  const check = () => { if (current !== generation || !localPeer || peer !== localPeer) throw new Error('Session ended'); };
  check();
  if (signal.kind === 'offer') {
    await localPeer.setRemoteDescription({ type: 'offer', sdp: signal.sdp }); check();
    for (const candidate of remoteCandidates.splice(0)) { await localPeer.addIceCandidate(candidate); check(); }
    const answer = await localPeer.createAnswer(); check();
    await localPeer.setLocalDescription(answer); check();
    await sendSignal({ kind: 'answer', sdp: localPeer.localDescription?.sdp }, current);
  } else if (signal.kind === 'candidate') {
    const candidate = new RTCIceCandidate({ candidate: signal.candidate, sdpMid: signal.mid, sdpMLineIndex: signal.line });
    if (localPeer.remoteDescription) { await localPeer.addIceCandidate(candidate); check(); }
    else remoteCandidates.push(candidate);
  } else throw new Error('Unexpected host signal');
}
function attachChannel(candidate, current) { if (current !== generation) { candidate.close(); return; } if (channel || candidate.label !== 'control' || candidate.ordered !== true) { candidate.close(); endSession(); return; } channel = candidate; channel.binaryType = 'arraybuffer'; channel.onopen = () => { if (current !== generation || channel !== candidate) return; sendRaw({ type: 'bind', session: state.session, challengeHash }); updateControls(); }; channel.onclose = () => { if (current === generation) updateControls(); }; channel.onmessage = ({ data }) => { if (current !== generation || channel !== candidate) return; try { const value = JSON.parse(typeof data === 'string' ? data : new TextDecoder().decode(data)); if (value.type === 'status' && value.session === state.session && validDecimal(String(value.revision))) { const priorMode = state.mode; state = { ...state, ...value, revision: String(value.revision) }; if (value.mode !== priorMode) { endSession(); return; } if (!state.healthy || !state.control) release(); updateControls(); } else if (value.type === 'textResult' && value.key === pendingText?.key) { const sent = pendingText; pendingText = undefined; if (value.accepted) { if ($('draft').value === sent.draft) $('draft').value = ''; inputState.textContent = $('draft').value ? 'Earlier text accepted; newer draft retained locally.' : 'Text was accepted for host injection.'; } else inputState.textContent = 'Host refused the text; draft retained locally.'; updateControls(); } } catch { release(); } }; }
function makePeer(current) { const localPeer = new RTCPeerConnection(); peer = localPeer; mediaTimeout = setTimeout(() => { if (current !== generation) return; endSession(); say('No video arrived. Check network reachability before connecting again.'); }, 30000); localPeer.ontrack = ({ streams, track }) => { if (current !== generation || peer !== localPeer) return; video.srcObject = streams[0] ?? new MediaStream([track]); video.play().catch(() => { message.textContent = 'Tap video to start playback.'; }); message.hidden = false; message.textContent = 'Waiting for the first video frame…'; document.body.classList.add('connected'); say('Authenticated · waiting for media connection'); beginMarkerRead(); diag?.onTrack(localPeer); }; localPeer.ondatachannel = ({ channel: next }) => attachChannel(next, current); localPeer.onicecandidate = ({ candidate }) => { if (candidate) sendSignal({ kind: 'candidate', candidate: candidate.candidate, mid: candidate.sdpMid ?? '', line: candidate.sdpMLineIndex ?? 0 }, current).catch(() => { if (current === generation) endSession(); }); }; localPeer.onconnectionstatechange = () => { if (current === generation && peer === localPeer && ['failed', 'closed', 'disconnected'].includes(localPeer.connectionState)) endSession(); }; }
async function connectSession() {
  if (!enrollment || enrollmentAbort || admissionAbort || state.session) return;
  const enrolled = enrollment, current = ++generation, abort = new AbortController();
  admissionAbort = abort; connect.disabled = true; end.disabled = false;
  const check = () => { if (current !== generation || abort.signal.aborted || enrollment !== enrolled) throw new Error('Session ended'); };
  say('Requesting a fresh authenticated session…');
  try {
    const nonce = random(), mode = enrolled.mode;
    const challenge = await request('challenge', { peerID: enrolled.peerID, nonce, mode }, abort.signal); check();
    const fields = recordFields(challenge.fields ?? challenge, 12);
    const names = ['challenge', enrolled.hostID, enrolled.peerID, location.origin, mode];
    if (!fields || names.some((value, index) => fields[index] !== value) || fields[5] !== enrolled.display || !validDecimal(fields[6]) || !/^[a-f0-9]{64}$/.test(fields[7]) || fields[9] !== nonce || !/^[a-f0-9]{64}$/.test(fields[10]) || !expiry(fields[8])) throw new Error('Challenge does not match this browser');
    const verified = await verify(fields, challenge.signature, enrolled.hostKey); check();
    if (!verified) throw new Error('Challenge signature was rejected');
    const ephemeral = await generateEphemeral(); check();
    const nextHash = await hash(canonical(fields)); check();
    const nextKey = await sharedKey(ephemeral.privateKey, fields[11], fields); check();
    const local = await localIdentity(); check();
    const signature = await sign(['proof', nextHash, ephemeral.publicKey], local.privateKey); check();
    const proof = await request('proof', { session: fields[7], publicKey: ephemeral.publicKey, signature }, abort.signal); check();
    const ticketFields = ['ticket', proof.session, proof.ticket, proof.expires, nextHash];
    if (ticketFields.some(field => typeof field !== 'string') || proof.session !== fields[7] || !/^[a-f0-9]{64}$/.test(proof.ticket) || !expiry(proof.expires)) throw new Error('Ticket was rejected');
    const ticketVerified = await verify(ticketFields, proof.signature, enrolled.hostKey); check();
    if (!ticketVerified) throw new Error('Ticket signature was rejected');
    challengeHash = nextHash; signalKey = nextKey;
    state = { session: fields[7], revision: fields[6], mode, healthy: false, control: false };
    remoteCandidates = []; incomingSignals = Promise.resolve(); outgoingSignals = Promise.resolve();
    openSignal(proof.ticket, current); say('Admission succeeded. Establishing encrypted media…');
  } catch (error) {
    if (current === generation) { endSession(); say(`Connect did not start: ${safeError(error)}`); }
  } finally { if (admissionAbort === abort) admissionAbort = undefined; }
}
function openSignal(ticket, current) { const url = endpoint('/browser-signal'); url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:'; const socket = new WebSocket(url); signalSocket = socket; socket.onopen = () => { if (current === generation && signalSocket === socket) socket.send(JSON.stringify({ type: 'browser', hostID: enrollment.hostID, session: state.session, ticket })); }; socket.onmessage = ({ data }) => { incomingSignals = incomingSignals.then(async () => { if (current !== generation || signalSocket !== socket) return; const messageValue = JSON.parse(data); if (messageValue.type === 'registered' && messageValue.session === state.session) { if (peer) throw new Error('Repeated registration'); makePeer(current); await sendSignal({ kind: 'ready' }, current); } else if (messageValue.type === 'signal' && messageValue.session === state.session) { const envelope = messageValue.envelope; const sequence = Number(envelope?.sequence); if (!Number.isSafeInteger(sequence) || sequence <= receivedSequence) throw new Error('Signal sequence is stale'); receivedSequence = sequence; await handleSignal(await open(envelope, signalKey, state.session, 'host', challengeHash), current); } else if (messageValue.type === 'end') endSession(); }).catch(() => { if (current === generation) endSession(); }); }; socket.onclose = () => { if (current === generation && signalSocket === socket && state.session) endSession(false); }; }
function endSession(sendEnd = true) { clearTimeout(mediaTimeout); diag?.stopSampling(); diag?.abort(); generation += 1; admissionAbort?.abort(); admissionAbort = undefined; pendingText = undefined; composing = false; release(); viewportPointers.clear(); delete viewport.dataset.distance; document.body.classList.remove('connected'); if (sendEnd && signalSocket?.readyState === WebSocket.OPEN && state.session) signalSocket.send(JSON.stringify({ type: 'end', session: state.session })); signalSocket?.close(); signalSocket = undefined; peer?.close(); peer = undefined; channel = undefined; video.pause(); video.srcObject = null; marker = undefined; clearInterval(markerTimer); video.cancelVideoFrameCallback?.(frameCallback); frameCallback = undefined; state = {}; signalKey = undefined; challengeHash = undefined; sentSequence = 0; receivedSequence = 0; inputSequence = 0; remoteCandidates = []; dragHeld = false; end.disabled = true; connect.disabled = !enrollment; message.hidden = false; message.textContent = 'No session is active.'; updateControls(); say(enrollment ? 'Session ended. A future connection requires a fresh challenge.' : 'Session ended.'); }
async function enroll() { endSession(); enrollmentAbort?.abort(); const current = ++enrollmentGeneration; const abort = new AbortController(); enrollmentAbort = abort; connect.disabled = true; $('enroll').disabled = true; try { const offer = offerFrom($('offer').value.trim()); const local = await localIdentity(current); if (current !== enrollmentGeneration) return; const peerID = random(); const body = await sealEnrollment(offer, peerID, local.publicKey); if (current !== enrollmentGeneration) return; const response = await fetch(new URL(`/browser-api/${offer.hostID}/enroll`, offer.url), { method: 'POST', headers: { 'content-type': 'application/json' }, credentials: 'omit', cache: 'no-store', signal: abort.signal, body: JSON.stringify(body) }); if (!response.ok) throw new Error(`Enrollment refused (${response.status})`); const result = await response.json(); if (current !== enrollmentGeneration) return; const fields = recordFields(result.receipt, 7); if (!fields || fields[0] !== 'enrolled' || fields[1] !== offer.hostID || fields[2] !== peerID || fields[3] !== local.publicKey || fields[4] !== location.origin || !['view', 'interactive'].includes(fields[5]) || !await verify(fields, result.signature, offer.hostKey) || current !== enrollmentGeneration) throw new Error('Enrollment receipt was rejected'); const next = { url: offer.url, hostID: offer.hostID, hostKey: offer.hostKey, peerID, origin: fields[4], mode: fields[5], display: fields[6] }; await stored('enrollment', next, current); if (current !== enrollmentGeneration) return; enrollment = next; $('offer').value = ''; connect.disabled = false; say('Browser enrolled. Connect remains an explicit action.'); } catch (error) { if (current === enrollmentGeneration && error.name !== 'AbortError') say(`Enrollment did not complete: ${safeError(error)}`); } finally { if (current === enrollmentGeneration) { enrollmentAbort = undefined; $('enroll').disabled = false; connect.disabled = !enrollment || Boolean(state.session) || Boolean(admissionAbort); } } }
const fit = document.createElement('button'); fit.type = 'button'; fit.textContent = 'Fit / reset zoom'; fit.setAttribute('aria-label', 'Fit remote display and reset local zoom'); const zoom = document.createElement('input'); zoom.type = 'range'; zoom.min = '1'; zoom.max = '3'; zoom.step = '0.1'; zoom.value = '1'; zoom.setAttribute('aria-label', 'Local viewer zoom'); end.after(fit, zoom); zoom.addEventListener('input', () => { pan.zoom = Number(zoom.value); updateViewport(); }); fit.addEventListener('click', () => { pan = { x: 0, y: 0, zoom: 1 }; zoom.value = '1'; updateViewport(); }); reveal.addEventListener('click', () => { controls.hidden = !controls.hidden; reveal.setAttribute('aria-expanded', String(!controls.hidden)); reveal.textContent = controls.hidden ? 'Show controls' : 'Hide controls'; }); connect.addEventListener('click', connectSession); end.addEventListener('click', () => endSession()); $('enroll').addEventListener('click', enroll); $('forget').addEventListener('click', eraseLocal);
controls.addEventListener('click', (event) => { const action = event.target.dataset.action; if (action) { try { sendAction({ action }); } catch (error) { inputState.textContent = safeError(error); } } }); $('drag').addEventListener('click', () => { try { sendAction({ action: dragHeld ? 'dragUp' : 'dragDown' }); dragHeld = !dragHeld; $('drag').textContent = dragHeld ? 'Release drag' : 'Hold drag'; } catch (error) { inputState.textContent = safeError(error); } }); $('send-key').addEventListener('click', () => { try { sendAction({ action: 'key', key: $('key').value.trim().toLowerCase(), modifiers: $('modifier').value ? [$('modifier').value] : [] }); } catch (error) { inputState.textContent = safeError(error); } }); $('draft').addEventListener('compositionstart', () => { composing = true; updateControls(); }); $('draft').addEventListener('compositionend', () => { composing = false; updateControls(); }); $('send-text').addEventListener('click', () => { const draft = $('draft').value; if (!draft || pendingText || composing) return; try { const key = random().slice(0, 32); pendingText = { key, draft }; sendAction({ action: 'text', text: draft, key }); inputState.textContent = 'Text submitted once; draft stays until the matching host receipt.'; updateControls(); } catch (error) { pendingText = undefined; inputState.textContent = safeError(error); updateControls(); } });
const trackPointers = new Map(); let trackCenter; const trackpad = $('trackpad'); trackpad.addEventListener('pointerdown', (event) => { if (controls.dataset.interactive !== 'true') return; trackPointers.set(event.pointerId, { x: event.clientX, y: event.clientY }); trackpad.setPointerCapture(event.pointerId); }); trackpad.addEventListener('pointermove', (event) => { if (!trackPointers.has(event.pointerId) || controls.dataset.interactive !== 'true') return; const before = trackPointers.get(event.pointerId); trackPointers.set(event.pointerId, { x: event.clientX, y: event.clientY }); const points = [...trackPointers.values()]; try { if (points.length === 1) sendAction({ action: 'move', x: event.clientX - before.x, y: event.clientY - before.y }); else if (points.length === 2) { const center = { x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2 }; if (trackCenter) sendAction({ action: 'scroll', x: center.x - trackCenter.x, y: center.y - trackCenter.y }); trackCenter = center; } } catch {} }); ['pointerup', 'pointercancel'].forEach((name) => trackpad.addEventListener(name, (event) => { trackPointers.delete(event.pointerId); trackCenter = undefined; if (name === 'pointercancel' && dragHeld) release(); })); trackpad.addEventListener('wheel', (event) => { if (controls.dataset.interactive !== 'true') return; event.preventDefault(); try { sendAction({ action: 'scroll', x: event.deltaX, y: event.deltaY }); } catch {} }, { passive: false });
viewport.addEventListener('pointerdown', (event) => { viewportPointers.set(event.pointerId, { x: event.clientX, y: event.clientY }); viewport.setPointerCapture(event.pointerId); }); viewport.addEventListener('pointermove', (event) => { const previous = viewportPointers.get(event.pointerId); if (!previous) return; viewportPointers.set(event.pointerId, { x: event.clientX, y: event.clientY }); const points = [...viewportPointers.values()]; if (points.length === 1 && pan.zoom > 1) { pan.x += event.clientX - previous.x; pan.y += event.clientY - previous.y; } else if (points.length === 2) { const distance = Math.hypot(points[0].x - points[1].x, points[0].y - points[1].y); const old = viewport.dataset.distance ? Number(viewport.dataset.distance) : distance; pan.zoom = Math.max(1, Math.min(3, pan.zoom * distance / old)); viewport.dataset.distance = String(distance); } updateViewport(); }); ['pointerup', 'pointercancel'].forEach((name) => viewport.addEventListener(name, (event) => { viewportPointers.delete(event.pointerId); delete viewport.dataset.distance; }));
window.visualViewport?.addEventListener('resize', () => document.documentElement.style.setProperty('--vvh', `${window.visualViewport.height}px`)); document.addEventListener('visibilitychange', () => { if (document.hidden) { invalidateEnrollment(); endSession(); } }); window.addEventListener('pagehide', () => { invalidateEnrollment(); endSession(); }); video.addEventListener('click', () => video.play().catch(() => {})); loadEnrollment().catch(() => say('Local browser enrollment storage is unavailable.'));
if (diag) { const panel = document.createElement('section'); panel.id = 'diag-panel'; const heading = document.createElement('h2'); heading.textContent = `Diagnostics · marker=${markerMode}`; const run = document.createElement('button'); run.type = 'button'; run.textContent = 'Latency run'; const sendReportButton = document.createElement('button'); sendReportButton.type = 'button'; sendReportButton.textContent = 'Send report'; const readout = document.createElement('pre'); readout.id = 'diag-readout'; readout.textContent = 'No latency run yet.'; run.addEventListener('click', async () => { run.disabled = true; readout.textContent = 'Running…'; try { readout.textContent = JSON.stringify(await diag.runLatencyBench(), null, 2); } catch (error) { readout.textContent = safeError(error); } finally { run.disabled = false; } }); sendReportButton.addEventListener('click', async () => { sendReportButton.disabled = true; try { await diag.sendReport(); readout.textContent = 'Diagnostics report sent.'; } catch (error) { readout.textContent = safeError(error); } finally { sendReportButton.disabled = false; } }); panel.append(heading, run, sendReportButton, readout); document.body.append(panel); }
