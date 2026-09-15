const POLICIES = new Set(['all', 'relay']);
const SCHEMES = ['stun:', 'turn:', 'turns:'];

function validURL(value) { return typeof value === 'string' && value.length <= 2048 && SCHEMES.some((scheme) => value.toLowerCase().startsWith(scheme)); }
function hasRelay(servers) { return servers.some((server) => server.urls.some((url) => url.toLowerCase().startsWith('turn:') || url.toLowerCase().startsWith('turns:'))); }
function validServer(server) {
  if (!server || typeof server !== 'object') return false;
  if (!Array.isArray(server.urls) || server.urls.length === 0 || server.urls.length > 8 || !server.urls.every(validURL)) return false;
  if (server.username !== undefined && typeof server.username !== 'string') return false;
  if (server.credential !== undefined && typeof server.credential !== 'string') return false;
  const allowed = new Set(['urls', 'username', 'credential']);
  return Object.keys(server).every((key) => allowed.has(key));
}

export function validateIceMessage(message) {
  if (!message || typeof message !== 'object') throw new Error('Malformed ice message');
  const keys = Object.keys(message);
  if (keys.length !== 3 || !['type', 'servers', 'policy'].every((key) => keys.includes(key))) throw new Error('Malformed ice message');
  if (message.type !== 'ice') throw new Error('Malformed ice message');
  if (!Array.isArray(message.servers) || message.servers.length > 8 || !message.servers.every(validServer)) throw new Error('Malformed ice message');
  if (!POLICIES.has(message.policy)) throw new Error('Malformed ice message');
  if (message.policy === 'relay' && !hasRelay(message.servers)) throw new Error('relay_required_unavailable');
  return { servers: message.servers, policy: message.policy };
}

export function buildRTCConfiguration({ servers, policy }) {
  return {
    iceServers: servers.map(({ urls, username, credential }) => ({ urls, ...(username !== undefined ? { username } : {}), ...(credential !== undefined ? { credential } : {}) })),
    iceTransportPolicy: policy
  };
}
