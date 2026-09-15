import { describe, expect, test } from 'bun:test';
import { classifyAddress } from '../src/diag/address-class.js';
import { createBitrateTracker, extractCandidatePair, extractInboundVideo } from '../src/diag/stats-sampler.js';

describe('address classification never needs the raw address downstream', () => {
  test('classifies the documented ranges', () => {
    expect(classifyAddress('127.0.0.1')).toBe('loopback');
    expect(classifyAddress('::1')).toBe('loopback');
    expect(classifyAddress('192.168.1.5')).toBe('private-lan');
    expect(classifyAddress('10.0.0.4')).toBe('private-lan');
    expect(classifyAddress('172.20.4.1')).toBe('private-lan');
    expect(classifyAddress('172.10.4.1')).toBe('public');
    expect(classifyAddress('100.98.4.2')).toBe('tailscale-cgnat');
    expect(classifyAddress('8.8.8.8')).toBe('public');
    expect(classifyAddress('device.local')).toBe('mdns');
    expect(classifyAddress('fe80::1')).toBe('private-lan');
    expect(classifyAddress('2001:db8::1')).toBe('public');
  });
  test('unrecognizable or missing input classifies as unknown', () => {
    expect(classifyAddress(undefined)).toBe('unknown');
    expect(classifyAddress('')).toBe('unknown');
    expect(classifyAddress('not-an-address')).toBe('unknown');
    expect(classifyAddress('999.1.1.1')).toBe('unknown');
  });
});

describe('candidate pair extraction reports null, never zero, for unavailable fields', () => {
  test('prefers the transport-selected pair', () => {
    const entries = [
      { id: 't1', type: 'transport', selectedCandidatePairId: 'p1' },
      { id: 'p1', type: 'candidate-pair', localCandidateId: 'l1', remoteCandidateId: 'r1', nominated: true, state: 'succeeded', currentRoundTripTime: 0.02 },
      { id: 'l1', type: 'local-candidate', candidateType: 'srflx', protocol: 'udp', address: '203.0.113.9' },
      { id: 'r1', type: 'remote-candidate', candidateType: 'host', address: '192.168.1.10' },
    ];
    expect(extractCandidatePair(entries)).toEqual({
      localCandidateType: 'srflx', remoteCandidateType: 'host', protocol: 'udp', relayProtocol: null, networkType: null,
      localAddressClass: 'public', remoteAddressClass: 'private-lan', currentRoundTripTime: 0.02, availableIncomingBitrate: null,
    });
  });
  test('falls back to a nominated succeeded pair when no transport names one', () => {
    const entries = [{ id: 'p2', type: 'candidate-pair', nominated: true, state: 'succeeded', localCandidateId: 'l2', remoteCandidateId: 'r2' }, { id: 'l2', type: 'local-candidate' }, { id: 'r2', type: 'remote-candidate' }];
    const pair = extractCandidatePair(entries);
    expect(pair?.localCandidateType).toBeNull();
    expect(pair?.currentRoundTripTime).toBeNull();
  });
  test('is null when nothing qualifies', () => expect(extractCandidatePair([])).toBeNull());
});

describe('inbound video extraction', () => {
  test('reports null instead of zero for fields the report omits', () => {
    const entries = [{ id: 'c1', type: 'codec', mimeType: 'video/VP8' }, { id: 'i1', type: 'inbound-rtp', kind: 'video', codecId: 'c1', framesDecoded: 120, bytesReceived: 4096 }];
    const inbound = extractInboundVideo(entries);
    expect(inbound?.codec).toBe('video/VP8');
    expect(inbound?.framesDecoded).toBe(120);
    expect(inbound?.bytesReceived).toBe(4096);
    expect(inbound?.framesDropped).toBeNull();
    expect(inbound?.packetsLost).toBeNull();
    expect(inbound?.nackCount).toBeNull();
  });
  test('is null when there is no inbound video stream', () => expect(extractInboundVideo([])).toBeNull());
});

describe('bitrate tracker', () => {
  test('computes a bits-per-second delta between two ordered samples', () => {
    const bitrate = createBitrateTracker();
    expect(bitrate(1000, 0)).toBeNull();
    expect(bitrate(2000, 1000)).toBe(8000);
  });
  test('resets on a missing or out-of-order sample rather than reporting a bad delta', () => {
    const bitrate = createBitrateTracker();
    bitrate(1000, 0);
    expect(bitrate(null, 500)).toBeNull();
    expect(bitrate(1500, 100)).toBeNull();
  });
});
