import { createHash, randomBytes } from 'node:crypto';
import {
  chmodSync,
  closeSync,
  existsSync,
  fsyncSync,
  lstatSync,
  openSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import { dirname, isAbsolute } from 'node:path';

export const ACCESS_TOKEN_TTL_MS = 60 * 60 * 1000;
export const AUTH_CODE_TTL_MS = 60 * 1000;
export const IDLE_GRANT_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const MAX_STORE_BYTES = 8 * 1024 * 1024;

export type Scope = 'desktop.access' | 'screen.inspect';

type ClientRecord = {
  clientId: string;
  redirectUris: string[];
  createdAt: number;
  origin: 'dcr';
};

type PendingCode = {
  hostID: string;
  clientId: string;
  clientName: string;
  redirectUri: string;
  redirectHost: string;
  codeChallenge: string;
  resource: string;
  scope: Scope[];
  offlineAccess: boolean;
  createdAt: number;
  used: boolean;
};

type GrantRecord = {
  grantId: string;
  hostID: string;
  clientId: string;
  clientName: string;
  redirectHost: string;
  scope: Scope[];
  offlineAccess: boolean;
  createdAt: number;
  lastUsedAt: number;
  revoked: boolean;
};

type AccessTokenRecord = { grantId: string; expiresAt: number };
type RefreshTokenRecord = { grantId: string; used: boolean; createdAt: number };

type Document = {
  version: 1;
  clients: Record<string, ClientRecord>;
  codes: Record<string, PendingCode>;
  grants: Record<string, GrantRecord>;
  accessTokens: Record<string, AccessTokenRecord>;
  refreshTokens: Record<string, RefreshTokenRecord>;
};

function emptyDocument(): Document {
  return { version: 1, clients: {}, codes: {}, grants: {}, accessTokens: {}, refreshTokens: {} };
}

function requirePrivatePath(path: string) {
  if (!isAbsolute(path)) throw new Error('mcp store path must be absolute');
  if (!existsSync(dirname(path))) throw new Error('mcp store directory does not exist');
}

function atomicPrivateWrite(path: string, body: string) {
  const temporary = `${path}.tmp-${process.pid}-${randomBytes(8).toString('hex')}`;
  let descriptor: number | undefined;
  try {
    descriptor = openSync(temporary, 'wx', 0o600);
    writeFileSync(descriptor, body, { encoding: 'utf8' });
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;
    renameSync(temporary, path);
    chmodSync(path, 0o600);
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
    if (existsSync(temporary)) unlinkSync(temporary);
  }
}

function readDocument(path: string): Document {
  if (!existsSync(path)) return emptyDocument();
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`mcp store path must be a regular file: ${path}`);
  if ((stat.mode & 0o077) !== 0) throw new Error(`mcp store file must not be accessible by group or others: ${path}`);
  if (stat.size > MAX_STORE_BYTES) throw new Error(`mcp store file is too large: ${path}`);
  const parsed = JSON.parse(readFileSync(path, 'utf8')) as Partial<Document>;
  if (parsed.version !== 1) throw new Error('invalid mcp store document');
  return {
    version: 1,
    clients: parsed.clients ?? {},
    codes: parsed.codes ?? {},
    grants: parsed.grants ?? {},
    accessTokens: parsed.accessTokens ?? {},
    refreshTokens: parsed.refreshTokens ?? {},
  };
}

const sha256 = (value: string) => createHash('sha256').update(value).digest('hex');
const opaqueToken = (prefix: string) => `${prefix}_${randomBytes(32).toString('base64url')}`;

export type IssuedTokens = { grantId: string; accessToken: string; refreshToken?: string; accessTokenExpiresAt: number };

export type GrantSummary = {
  grantId: string;
  hostID: string;
  clientName: string;
  redirectHost: string;
  scope: Scope[];
  offlineAccess: boolean;
  createdAt: number;
  lastUsedAt: number;
};

export class McpStore {
  private readonly path: string;
  private readonly now: () => number;
  private doc: Document;

  constructor(path: string, now: () => number = Date.now) {
    requirePrivatePath(path);
    this.path = path;
    this.now = now;
    this.doc = readDocument(path);
  }

  private persist() {
    atomicPrivateWrite(this.path, JSON.stringify(this.doc));
  }

  private pruneExpiredCodes() {
    const now = this.now();
    for (const [hash, code] of Object.entries(this.doc.codes)) {
      if (code.used || now - code.createdAt > AUTH_CODE_TTL_MS) delete this.doc.codes[hash];
    }
  }

  // --- Dynamic Client Registration (bounded fallback) ---

  registerDcrClient(redirectUris: string[]): { clientId: string } {
    const clientId = randomBytes(16).toString('hex');
    this.doc.clients[clientId] = { clientId, redirectUris, createdAt: this.now(), origin: 'dcr' };
    this.persist();
    return { clientId };
  }

  getDcrClient(clientId: string): ClientRecord | undefined {
    return this.doc.clients[clientId];
  }

  /** Expire DCR client records that were never used to complete an authorization, per the contract's bounded-fallback cap. */
  expireUnusedDcrClients(maxAgeMs: number) {
    const now = this.now();
    const usedClientIds = new Set(Object.values(this.doc.grants).map(grant => grant.clientId));
    let changed = false;
    for (const [clientId, record] of Object.entries(this.doc.clients)) {
      if (!usedClientIds.has(clientId) && now - record.createdAt > maxAgeMs) {
        delete this.doc.clients[clientId];
        changed = true;
      }
    }
    if (changed) this.persist();
  }

  // --- Authorization codes ---

  createAuthorizationCode(pending: Omit<PendingCode, 'createdAt' | 'used'>): string {
    this.pruneExpiredCodes();
    const code = opaqueToken('pdac');
    this.doc.codes[sha256(code)] = { ...pending, createdAt: this.now(), used: false };
    this.persist();
    return code;
  }

  /** Single-use: the code is consumed (deleted) whether or not the remaining checks pass. */
  consumeAuthorizationCode(code: string): PendingCode | undefined {
    const hash = sha256(code);
    const record = this.doc.codes[hash];
    if (!record) return undefined;
    delete this.doc.codes[hash];
    this.persist();
    if (record.used || this.now() - record.createdAt > AUTH_CODE_TTL_MS) return undefined;
    return record;
  }

  // --- Grants & tokens ---

  createGrant(params: {
    hostID: string;
    clientId: string;
    clientName: string;
    redirectHost: string;
    scope: Scope[];
    offlineAccess: boolean;
  }): { grantId: string; tokens: IssuedTokens } {
    const grantId = randomBytes(16).toString('hex');
    const now = this.now();
    this.doc.grants[grantId] = {
      grantId,
      hostID: params.hostID,
      clientId: params.clientId,
      clientName: params.clientName,
      redirectHost: params.redirectHost,
      scope: params.scope,
      offlineAccess: params.offlineAccess,
      createdAt: now,
      lastUsedAt: now,
      revoked: false,
    };
    const tokens = this.issueTokensUnlocked(grantId, params.offlineAccess);
    this.persist();
    return { grantId, tokens };
  }

  private issueTokensUnlocked(grantId: string, offlineAccess: boolean): IssuedTokens {
    const now = this.now();
    const accessToken = opaqueToken('pdat');
    const expiresAt = now + ACCESS_TOKEN_TTL_MS;
    this.doc.accessTokens[sha256(accessToken)] = { grantId, expiresAt };
    if (!offlineAccess) return { grantId, accessToken, accessTokenExpiresAt: expiresAt };
    const refreshToken = opaqueToken('pdrt');
    this.doc.refreshTokens[sha256(refreshToken)] = { grantId, used: false, createdAt: now };
    return { grantId, accessToken, refreshToken, accessTokenExpiresAt: expiresAt };
  }

  private grantLive(grant: GrantRecord | undefined): grant is GrantRecord {
    if (!grant || grant.revoked) return false;
    return this.now() - grant.lastUsedAt <= IDLE_GRANT_TTL_MS;
  }

  /** Verifies a bearer access token, returning its live grant, or undefined. Touches idle-expiry clock. */
  verifyAccessToken(token: string): GrantRecord | undefined {
    const record = this.doc.accessTokens[sha256(token)];
    if (!record || record.expiresAt <= this.now()) return undefined;
    const grant = this.doc.grants[record.grantId];
    if (!this.grantLive(grant)) return undefined;
    grant.lastUsedAt = this.now();
    this.persist();
    return grant;
  }

  /**
   * Refresh-token rotation with reuse detection: a token can be redeemed exactly
   * once. Redeeming an already-used (rotated-away) token revokes the whole grant.
   */
  refreshTokens(refreshToken: string): IssuedTokens | 'invalid' | 'reused_revoked' {
    const hash = sha256(refreshToken);
    const record = this.doc.refreshTokens[hash];
    if (!record) return 'invalid';
    const grant = this.doc.grants[record.grantId];
    if (record.used) {
      if (grant) grant.revoked = true;
      this.revokeGrantTokensUnlocked(record.grantId);
      this.persist();
      return 'reused_revoked';
    }
    if (!this.grantLive(grant)) return 'invalid';
    record.used = true;
    grant.lastUsedAt = this.now();
    const tokens = this.issueTokensUnlocked(record.grantId, true);
    this.persist();
    return tokens;
  }

  private revokeGrantTokensUnlocked(grantId: string) {
    for (const [hash, record] of Object.entries(this.doc.accessTokens)) if (record.grantId === grantId) delete this.doc.accessTokens[hash];
    for (const [hash, record] of Object.entries(this.doc.refreshTokens)) if (record.grantId === grantId) delete this.doc.refreshTokens[hash];
  }

  revokeGrant(grantId: string): boolean {
    const grant = this.doc.grants[grantId];
    if (!grant || grant.revoked) return false;
    grant.revoked = true;
    this.revokeGrantTokensUnlocked(grantId);
    this.persist();
    return true;
  }

  revokeGrantsForHost(hostID: string) {
    let changed = false;
    for (const grant of Object.values(this.doc.grants)) {
      if (grant.hostID === hostID && !grant.revoked) {
        grant.revoked = true;
        this.revokeGrantTokensUnlocked(grant.grantId);
        changed = true;
      }
    }
    if (changed) this.persist();
  }

  /** RFC 7009-style revoke: accepts either token type, always succeeds if found. */
  revokeToken(token: string) {
    const hash = sha256(token);
    if (this.doc.accessTokens[hash]) {
      const grantId = this.doc.accessTokens[hash].grantId;
      delete this.doc.accessTokens[hash];
      this.persist();
      return;
    }
    if (this.doc.refreshTokens[hash]) {
      const grantId = this.doc.refreshTokens[hash].grantId;
      this.revokeGrantTokensUnlocked(grantId);
      const grant = this.doc.grants[grantId];
      if (grant) grant.revoked = true;
      this.persist();
    }
  }

  getGrant(grantId: string): GrantRecord | undefined {
    const grant = this.doc.grants[grantId];
    return this.grantLive(grant) ? grant : undefined;
  }

  listGrantsForHost(hostID: string): GrantSummary[] {
    return Object.values(this.doc.grants)
      .filter(grant => grant.hostID === hostID && this.grantLive(grant))
      .map(({ grantId, hostID: host, clientName, redirectHost, scope, offlineAccess, createdAt, lastUsedAt }) => ({
        grantId, hostID: host, clientName, redirectHost, scope, offlineAccess, createdAt, lastUsedAt,
      }));
  }
}
