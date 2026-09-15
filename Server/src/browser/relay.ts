import type { IceServer, PeerRole, TurnCredentialProvider } from '../turn';

export type RelayRole = 'host' | 'browser';
export type RelayPolicy = 'all' | 'relay';
export type IssuedRelay = { servers: IceServer[]; policy: RelayPolicy };

export type BrowserRelayConfig = {
  provider?: TurnCredentialProvider;
  stunURLs?: string[];
  timeoutMs?: number;
  issuesPerMinute?: number;
  testForceRelay?: boolean;
};

function integerOption(name: string, value: number, minimum: number, maximum: number) {
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be an integer from ${minimum} to ${maximum}`);
  }
  return value;
}

export function createBrowserRelay(config: BrowserRelayConfig = {}) {
  if (config.testForceRelay && !config.provider) {
    throw new Error('testForceRelay requires a relay provider');
  }
  const provider = config.provider;
  const stunURLs = config.stunURLs ?? [];
  const timeoutMs = integerOption('relayTimeoutMs', config.timeoutMs ?? 3_000, 250, 10_000);
  const issuesPerMinute = integerOption('relayIssuesPerMinute', config.issuesPerMinute ?? 24, 2, 600);
  const policy: RelayPolicy = config.testForceRelay ? 'relay' : 'all';

  let issueWindow = Date.now();
  let issueCount = 0;
  const pendingIssuances = new Set<Promise<unknown>>();
  const pendingRevocations = new Set<Promise<void>>();

  const revoke = (servers: IceServer[]) => {
    if (!provider?.revoke || servers.length === 0) return;
    const task = Promise.resolve().then(() => provider.revoke!(servers));
    pendingRevocations.add(task);
    void task.then(() => pendingRevocations.delete(task), () => pendingRevocations.delete(task));
  };

  const issue = async (room: string, role: RelayRole): Promise<IssuedRelay> => {
    const servers: IceServer[] = [];
    if (stunURLs.length) servers.push({ urls: [...stunURLs] });
    if (provider) {
      const now = Date.now();
      if (now - issueWindow >= 60_000) { issueWindow = now; issueCount = 0; }
      if (issueCount >= issuesPerMinute) throw new Error('relay issuance rate exceeded');
      issueCount += 1;
      let timer: Timer | undefined;
      let timedOut = false;
      let issuedByProvider: IceServer[] | undefined;
      try {
        const providerRole: PeerRole = role === 'browser' ? 'client' : 'host';
        const issuance = provider.issue({ room, role: providerRole });
        pendingIssuances.add(issuance);
        void issuance.then(
          issued => { pendingIssuances.delete(issuance); if (timedOut) revoke(issued); },
          () => pendingIssuances.delete(issuance),
        );
        issuedByProvider = await Promise.race([
          issuance,
          new Promise<never>((_resolve, reject) => {
            timer = setTimeout(() => { timedOut = true; reject(new Error('relay timeout')); }, timeoutMs);
          }),
        ]);
        servers.push(...issuedByProvider);
      } finally {
        clearTimeout(timer);
      }
      if (servers.length > 8 || servers.some(server => server.urls.length > 8)) {
        if (issuedByProvider) revoke(issuedByProvider);
        throw new Error('relay configuration exceeds client limits');
      }
    }
    if (servers.length > 8 || servers.some(server => server.urls.length > 8)) {
      throw new Error('relay configuration exceeds client limits');
    }
    return { servers, policy };
  };

  const drain = async (deadlineMs: number) => {
    const deadline = Date.now() + Math.max(0, deadlineMs);
    while (Date.now() < deadline) {
      const active = [...pendingIssuances, ...pendingRevocations];
      if (active.length === 0) break;
      const remaining = deadline - Date.now();
      await Promise.race([Promise.allSettled(active), new Promise(resolve => setTimeout(resolve, remaining))]);
    }
  };

  return { issue, revoke, drain };
}
