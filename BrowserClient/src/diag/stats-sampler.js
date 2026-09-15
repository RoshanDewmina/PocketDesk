import { classifyAddress } from './address-class.js';

const numOrNull = (value) => (typeof value === 'number' && Number.isFinite(value) ? value : null);

export function extractCandidatePair(entries) {
  const byId = new Map(entries.map((entry) => [entry.id, entry]));
  const transport = entries.find((entry) => entry.type === 'transport' && entry.selectedCandidatePairId);
  let pair = transport ? byId.get(transport.selectedCandidatePairId) : undefined;
  if (!pair) pair = entries.find((entry) => entry.type === 'candidate-pair' && entry.nominated && entry.state === 'succeeded');
  if (!pair) return null;
  const local = byId.get(pair.localCandidateId);
  const remote = byId.get(pair.remoteCandidateId);
  return {
    localCandidateType: local?.candidateType ?? null,
    remoteCandidateType: remote?.candidateType ?? null,
    protocol: local?.protocol ?? pair.protocol ?? null,
    relayProtocol: local?.relayProtocol ?? null,
    networkType: local?.networkType ?? null,
    localAddressClass: classifyAddress(local?.address ?? local?.ip ?? null),
    remoteAddressClass: classifyAddress(remote?.address ?? remote?.ip ?? null),
    currentRoundTripTime: numOrNull(pair.currentRoundTripTime),
    availableIncomingBitrate: numOrNull(pair.availableIncomingBitrate),
  };
}

export function extractInboundVideo(entries) {
  const byId = new Map(entries.map((entry) => [entry.id, entry]));
  const inbound = entries.find((entry) => entry.type === 'inbound-rtp' && (entry.kind === 'video' || entry.mediaType === 'video'));
  if (!inbound) return null;
  const codec = inbound.codecId ? byId.get(inbound.codecId) : undefined;
  return {
    codec: codec?.mimeType ?? null,
    frameWidth: numOrNull(inbound.frameWidth),
    frameHeight: numOrNull(inbound.frameHeight),
    framesPerSecond: numOrNull(inbound.framesPerSecond),
    framesDecoded: numOrNull(inbound.framesDecoded),
    framesDropped: numOrNull(inbound.framesDropped),
    totalDecodeTime: numOrNull(inbound.totalDecodeTime),
    jitterBufferDelay: numOrNull(inbound.jitterBufferDelay),
    jitterBufferEmittedCount: numOrNull(inbound.jitterBufferEmittedCount),
    bytesReceived: numOrNull(inbound.bytesReceived),
    nackCount: numOrNull(inbound.nackCount),
    pliCount: numOrNull(inbound.pliCount),
    packetsLost: numOrNull(inbound.packetsLost),
  };
}

export function createBitrateTracker() {
  let last = null;
  return (bytesReceived, timestampMs) => {
    if (bytesReceived === null || !Number.isFinite(timestampMs)) { last = null; return null; }
    if (!last || timestampMs <= last.timestampMs || bytesReceived < last.bytesReceived) { last = { bytesReceived, timestampMs }; return null; }
    const deltaSeconds = (timestampMs - last.timestampMs) / 1000;
    const bitrate = deltaSeconds > 0 ? Math.round(((bytesReceived - last.bytesReceived) * 8) / deltaSeconds) : null;
    last = { bytesReceived, timestampMs };
    return bitrate;
  };
}
