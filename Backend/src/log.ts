export type LogFields = Record<string, string | number | boolean | null | undefined>;

/** Fields must never carry payloads, tokens, JWS bodies, credentials or full identifiers. */
export function log(event: string, fields: LogFields = {}): void {
  console.log(JSON.stringify({ event, ...fields }));
}

export function logError(event: string, error: unknown, fields: LogFields = {}): void {
  console.error(JSON.stringify({ event, error: error instanceof Error ? error.message : String(error), ...fields }));
}

/** The only form in which a room, device or entitlement id may appear in logs or audit rows. */
export const fingerprint = (id: string | undefined) => (id ? id.slice(0, 8) : undefined);
