import { drawCodeScene } from '/fixtures/code-scene.js';

const $ = (id) => document.getElementById(id);
const startButton = $('start'); const stopButton = $('stop'); const receiver = $('receiver'); const stage = $('stage');
const status = $('status'); const codecLabel = $('codec'); const resolution = $('resolution'); const theme = $('theme');
const view = $('view'); const zoom = $('zoom'); const zoomValue = $('zoom-value'); const details = $('control-details');
let mediaTimeout; let decodedCallback; let canvas; let context; let stream; let senderPeer; let receiverPeer; let animation; let frame = 0; let pan = { x: 0, y: 0 }; let drag; let generation = 0;

function setStatus(message) { status.textContent = message; }
function dimensions() { return resolution.value.split('x').map(Number); }
function draw() { if (!context || !canvas) return; const [width, height] = dimensions(); if (canvas.width !== width || canvas.height !== height) { canvas.width = width; canvas.height = height; } drawCodeScene(context, { width, height, themeName: theme.value, frame: frame++, timestamp: Date.now() }); animation = requestAnimationFrame(draw); }
function preferredH264() { const codecs = globalThis.RTCRtpSender?.getCapabilities?.('video')?.codecs ?? []; return codecs.filter((codec) => codec.mimeType?.toLowerCase() === 'video/h264'); }
function cleanup() { clearTimeout(mediaTimeout); receiver.cancelVideoFrameCallback?.(decodedCallback); generation += 1; cancelAnimationFrame(animation); animation = undefined; receiver.pause(); receiver.srcObject = null; stream?.getTracks().forEach((track) => track.stop()); stream = undefined; senderPeer?.getSenders().forEach((sender) => sender.track?.stop()); senderPeer?.close(); receiverPeer?.close(); senderPeer = undefined; receiverPeer = undefined; canvas = undefined; context = undefined; startButton.disabled = false; stopButton.disabled = true; codecLabel.textContent = 'Codec: inactive. No tracks or peer connections remain.'; setStatus('Stopped and cleared local tracks and peer connections.'); }
async function start() {
  if (senderPeer) return;
  if (!('RTCPeerConnection' in window) || !HTMLCanvasElement.prototype.captureStream) { setStatus('This browser does not expose the local WebRTC/canvas APIs required by the probe.'); return; }
  startButton.disabled = true; stopButton.disabled = false;
  setStatus('Starting synthetic canvas and local WebRTC loopback…');
  const currentGeneration = ++generation;
  const sender = new RTCPeerConnection(), remote = new RTCPeerConnection();
  senderPeer = sender; receiverPeer = remote;
  const check = () => { if (currentGeneration !== generation) throw new Error('Probe ended'); };
  mediaTimeout = setTimeout(() => {
    if (currentGeneration !== generation) return;
    cleanup(); setStatus('No video arrived. This browser runtime could not establish the local media path.');
  }, 15000);
  try {
    canvas = document.createElement('canvas'); context = canvas.getContext('2d'); frame = 0; draw();
    stream = canvas.captureStream(30); const [track] = stream.getVideoTracks();
    const toSender = [], toReceiver = [];
    const forward = (target, queue) => async candidate => {
      check(); if (!candidate) return;
      if (!target.remoteDescription) { queue.push(candidate); return; }
      await target.addIceCandidate(candidate); check();
    };
    sender.onicecandidate = ({ candidate }) => forward(remote, toReceiver)(candidate).catch(() => {});
    remote.onicecandidate = ({ candidate }) => forward(sender, toSender)(candidate).catch(() => {});
    remote.ontrack = ({ streams, track: receivedTrack }) => {
      if (currentGeneration !== generation) return;
      receiver.srcObject = streams[0] ?? new MediaStream([receivedTrack]);
      receiver.play().catch(() => { if (currentGeneration === generation) setStatus('Tap video to allow playback.'); });
      decodedCallback = receiver.requestVideoFrameCallback?.(() => {
        if (currentGeneration !== generation) return;
        clearTimeout(mediaTimeout); setStatus('Running: decoded synthetic code video over local WebRTC.');
      });
    };
    const transceiver = sender.addTransceiver(track, { direction: 'sendonly', streams: [stream] });
    const h264 = preferredH264();
    if (h264.length && transceiver.setCodecPreferences) transceiver.setCodecPreferences(h264);
    const offer = await sender.createOffer(); check();
    await sender.setLocalDescription(offer); check();
    await remote.setRemoteDescription(offer); check();
    for (const candidate of toReceiver.splice(0)) { await remote.addIceCandidate(candidate); check(); }
    const answer = await remote.createAnswer(); check();
    await remote.setLocalDescription(answer); check();
    await sender.setRemoteDescription(answer); check();
    for (const candidate of toSender.splice(0)) { await sender.addIceCandidate(candidate); check(); }
    codecLabel.textContent = `Codec preference: ${h264.length ? 'H.264 requested from browser capabilities' : 'H.264 unavailable; browser fallback negotiated'}.`;
  } catch (error) {
    if (currentGeneration !== generation) return;
    cleanup(); setStatus(`Local loopback could not start: ${error instanceof Error ? error.message : String(error)}`);
  }
}
function updateView() { stage.classList.remove('fit', 'zoom', 'crop'); stage.classList.add(view.value); stage.style.setProperty('--zoom', view.value === 'fit' ? '1' : zoom.value); zoomValue.textContent = `${Number(zoom.value).toFixed(1)}×`; }
startButton.addEventListener('click', start); stopButton.addEventListener('click', cleanup);
theme.addEventListener('change', () => { if (context) { cancelAnimationFrame(animation); draw(); } }); resolution.addEventListener('change', () => { if (context) { cancelAnimationFrame(animation); draw(); } });
view.addEventListener('change', updateView); zoom.addEventListener('input', updateView); updateView();
stage.addEventListener('pointerdown', (event) => { if (Number(zoom.value) <= 1 && view.value !== 'crop') return; drag = { x: event.clientX, y: event.clientY, panX: pan.x, panY: pan.y }; stage.setPointerCapture(event.pointerId); });
stage.addEventListener('pointermove', (event) => { if (!drag) return; pan = { x: drag.panX + event.clientX - drag.x, y: drag.panY + event.clientY - drag.y }; stage.style.setProperty('--pan-x', `${pan.x}px`); stage.style.setProperty('--pan-y', `${pan.y}px`); });
stage.addEventListener('pointerup', () => { drag = undefined; }); stage.addEventListener('pointercancel', () => { drag = undefined; });
let composing = 0; let viewportChanges = 0; const localInput = $('local-input'); const observation = $('input-observation');
function updateObservation() { observation.textContent = `Local only: ${composing} composition event${composing === 1 ? '' : 's'} observed; ${viewportChanges} visual viewport change${viewportChanges === 1 ? '' : 's'}; no text transmitted.`; }
['compositionstart', 'compositionupdate', 'compositionend'].forEach((name) => localInput.addEventListener(name, () => { composing += 1; updateObservation(); }));
window.visualViewport?.addEventListener('resize', () => { viewportChanges += 1; document.documentElement.style.setProperty('--visual-viewport-height', `${window.visualViewport.height}px`); updateObservation(); });
$('toggle-controls').addEventListener('click', (event) => { const collapsed = details.classList.toggle('is-collapsed'); event.currentTarget.setAttribute('aria-expanded', String(!collapsed)); event.currentTarget.textContent = collapsed ? 'Show controls' : 'Hide controls'; });
document.addEventListener('visibilitychange', () => { if (document.hidden) cleanup(); }); window.addEventListener('pagehide', cleanup, { once: false });
