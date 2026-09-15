export function classifyAddress(address) {
  if (typeof address !== 'string' || !address) return 'unknown';
  if (address.endsWith('.local')) return 'mdns';
  if (address === '127.0.0.1' || address === '::1' || address.startsWith('127.')) return 'loopback';
  const ipv4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(address);
  if (ipv4) {
    const [a, b] = ipv4.slice(1).map(Number);
    if ([a, b].some((n) => n > 255)) return 'unknown';
    if (a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 169 && b === 254)) return 'private-lan';
    if (a === 100 && b >= 64 && b <= 127) return 'tailscale-cgnat';
    return 'public';
  }
  const lower = address.toLowerCase();
  if (/^[0-9a-f:]+$/.test(lower) && lower.includes(':')) {
    if (lower.startsWith('fe80:') || lower.startsWith('fc') || lower.startsWith('fd')) return 'private-lan';
    return 'public';
  }
  return 'unknown';
}
