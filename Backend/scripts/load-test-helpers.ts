export function parseBoundedInteger(raw: string | undefined, fallback: number, min: number, max: number): number {
  if (raw === undefined) return fallback;
  if (!/^\d+$/.test(raw)) throw new Error("must be an integer");
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < min || value > max) throw new Error("out of range");
  return value;
}

export function loadConcurrency(roomCount: number, requested: number, hasEntitlement: boolean): number {
  return hasEntitlement ? 1 : Math.min(roomCount, requested);
}

export function clientFeatures(): string[] {
  // remote.1 lets the server return an authoritative access field while still downgrading unpaid rooms to local.
  return ["renew.1", "route.1", "remote.1"];
}

export function resolveEntitlementTokens(roomCount: number, tokenListJson: string | undefined,
  singleToken: string | undefined): Array<string | undefined> {
  if (tokenListJson !== undefined && singleToken !== undefined) throw new Error("use either one token or a token list");
  if (tokenListJson === undefined) return Array.from({ length: roomCount }, () => singleToken);
  let tokens: unknown;
  try { tokens = JSON.parse(tokenListJson); } catch { throw new Error("token list must be a JSON array"); }
  if (!Array.isArray(tokens) || tokens.length !== roomCount ||
      !tokens.every(value => typeof value === "string" && value.length > 0) || new Set(tokens).size !== roomCount) {
    throw new Error("token list must contain one distinct non-empty token per room");
  }
  return tokens as string[];
}

export function validRoomRegistration(clientMessages: Record<string, unknown>[], hostMessages: Record<string, unknown>[],
  hasEntitlement: boolean): boolean {
  const expectedAccess = hasEntitlement ? "remote" : "local";
  const clientNoticeCount = clientMessages.filter(message => message.type === "error" && message.code === "entitlement_required").length;
  const clientRegistration = clientMessages.find(message => message.type === "registered");
  const clientIce = clientMessages.find(message => message.type === "ice");
  const clientRoute = clientMessages.find(message => message.type === "route");
  const hostRoute = hostMessages.find(message => message.type === "route");
  const online = (messages: Record<string, unknown>[]) => messages.some(message => message.type === "peer" && message.online === true);
  const unexpectedError = (messages: Record<string, unknown>[]) => messages.some(message => message.type === "error" && message.code !== "entitlement_required");
  return !unexpectedError(clientMessages) && !unexpectedError(hostMessages) &&
    clientNoticeCount === (hasEntitlement ? 0 : clientNoticeCount) && clientNoticeCount <= 1 &&
    clientRegistration?.role === "client" && clientRegistration.access === expectedAccess &&
    clientIce !== undefined && clientRoute?.access === expectedAccess && hostRoute?.access === expectedAccess &&
    online(clientMessages) && online(hostMessages);
}

export function safeWebSocketUrl(input: string): string {
  const url = new URL(input);
  if (url.protocol !== "ws:" && url.protocol !== "wss:") throw new Error("URL must use ws or wss");
  return `${url.protocol}//${url.host}${url.pathname}`;
}
