import { randomBytes } from 'node:crypto';
import type { HostBridge } from './bridge';
import { fetchClientMetadataDocument, isCimdClientId } from './cimd';
import { renderAuthorizePage, renderAuthorizeScript } from './authorize-page';
import { McpStore, type Scope } from './store';
import {
  isValidCodeChallenge,
  jsonResponse,
  mcpSecurityHeaders,
  oauthError,
  PerMinuteLimiter,
  randomConfirmationCode,
  readBodyCapped,
  verifyPkceS256,
} from './util';

const AUTHORIZE_APPROVAL_TIMEOUT_MS = 120_000;
const MAX_PENDING_AUTHORIZATIONS = 32;
const DCR_RATE_LIMIT_PER_MINUTE = 10;
const DCR_UNUSED_CLIENT_MAX_AGE_MS = 24 * 60 * 60 * 1000;
const MAX_TOKEN_BODY_BYTES = 8 * 1024;
const KNOWN_SCOPES: Scope[] = ['desktop.access', 'screen.inspect'];

type PendingAuthorize = {
  requestId: string;
  clientId: string;
  clientName: string;
  redirectUri: string;
  redirectHost: string;
  state?: string;
  codeChallenge: string;
  resource: string;
  scope: Scope[];
  offlineAccess: boolean;
  status: 'pending' | 'approved' | 'denied' | 'offline' | 'timeout';
  redirect?: string;
  controller: AbortController;
  createdAt: number;
};

export type OAuthConfig = {
  origin: string;
  store: McpStore;
  host: HostBridge;
  now?: () => number;
  fetchImpl?: typeof fetch;
};

function resourceIdentifier(origin: string) {
  return `${origin}/mcp`;
}

function parseScopes(raw: string | null): { scope: Scope[]; offlineAccess: boolean } | undefined {
  const tokens = (raw ?? 'desktop.access').split(/\s+/).filter(Boolean);
  if (tokens.length === 0 || tokens.length > 4) return undefined;
  const offlineAccess = tokens.includes('offline_access');
  const scope = tokens.filter((t): t is Scope => (KNOWN_SCOPES as string[]).includes(t));
  if (scope.length === 0) return undefined;
  if (tokens.some(t => t !== 'offline_access' && !(KNOWN_SCOPES as string[]).includes(t))) return undefined;
  return { scope: [...new Set(scope)], offlineAccess };
}

function isValidRedirectUri(value: string): boolean {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && !url.username && !url.password && !url.hash;
  } catch {
    return false;
  }
}

export function createOAuthServer(config: OAuthConfig) {
  const now = config.now ?? Date.now;
  const fetchImpl = config.fetchImpl ?? fetch;
  const pending = new Map<string, PendingAuthorize>();
  const dcrLimiter = new PerMinuteLimiter(DCR_RATE_LIMIT_PER_MINUTE, now);

  function sweepPending() {
    for (const [id, record] of pending) {
      if (record.status !== 'pending' && now() - record.createdAt > 5 * 60_000) pending.delete(id);
    }
  }

  async function resolveClient(clientId: string): Promise<{ redirectUris: string[]; clientName: string } | undefined> {
    if (isCimdClientId(clientId)) {
      try {
        const document = await fetchClientMetadataDocument(clientId, now, fetchImpl);
        return { redirectUris: document.redirect_uris, clientName: document.client_name ?? new URL(clientId).hostname };
      } catch {
        return undefined;
      }
    }
    const record = config.store.getDcrClient(clientId);
    if (!record) return undefined;
    return { redirectUris: record.redirectUris, clientName: 'Registered MCP client' };
  }

  function protectedResourceMetadata() {
    return {
      resource: resourceIdentifier(config.origin),
      authorization_servers: [config.origin],
      bearer_methods_supported: ['header'],
      scopes_supported: KNOWN_SCOPES,
    };
  }

  function authorizationServerMetadata() {
    return {
      issuer: config.origin,
      authorization_endpoint: `${config.origin}/oauth/authorize`,
      token_endpoint: `${config.origin}/oauth/token`,
      registration_endpoint: `${config.origin}/oauth/register`,
      revocation_endpoint: `${config.origin}/oauth/revoke`,
      response_types_supported: ['code'],
      grant_types_supported: ['authorization_code', 'refresh_token'],
      code_challenge_methods_supported: ['S256'],
      token_endpoint_auth_methods_supported: ['none'],
      client_id_metadata_document_supported: true,
      scopes_supported: [...KNOWN_SCOPES, 'offline_access'],
    };
  }

  async function authorize(request: Request): Promise<Response> {
    sweepPending();
    const url = new URL(request.url);
    const params = url.searchParams;
    const responseType = params.get('response_type');
    const clientId = params.get('client_id');
    const redirectUri = params.get('redirect_uri');
    const codeChallenge = params.get('code_challenge');
    const codeChallengeMethod = params.get('code_challenge_method');
    const resource = params.get('resource');
    const state = params.get('state') ?? undefined;

    if (responseType !== 'code' || !clientId || !redirectUri || !isValidRedirectUri(redirectUri)) {
      return oauthError(400, 'invalid_request');
    }
    if (codeChallengeMethod !== 'S256' || !isValidCodeChallenge(codeChallenge)) {
      return oauthError(400, 'invalid_request', 'PKCE S256 code_challenge is required');
    }
    if (resource !== resourceIdentifier(config.origin)) return oauthError(400, 'invalid_target');
    const scopes = parseScopes(params.get('scope'));
    if (!scopes) return oauthError(400, 'invalid_scope');

    const client = await resolveClient(clientId);
    if (!client || !client.redirectUris.includes(redirectUri)) {
      return oauthError(400, 'invalid_request', 'redirect_uri does not match the client record');
    }
    if (pending.size >= MAX_PENDING_AUTHORIZATIONS) return oauthError(503, 'temporarily_unavailable');

    const requestId = randomBytes(16).toString('hex');
    const redirectHost = new URL(redirectUri).host;
    const confirmationCode = randomConfirmationCode();
    const controller = new AbortController();
    const record: PendingAuthorize = {
      requestId,
      clientId,
      clientName: client.clientName,
      redirectUri,
      redirectHost,
      state,
      codeChallenge: codeChallenge!,
      resource,
      scope: scopes.scope,
      offlineAccess: scopes.offlineAccess,
      status: 'pending',
      controller,
      createdAt: now(),
    };
    pending.set(requestId, record);

    const timeoutTimer = setTimeout(() => controller.abort(), AUTHORIZE_APPROVAL_TIMEOUT_MS);
    config.host
      .requestAuthorization({ clientName: client.clientName, redirectHost, code: confirmationCode, signal: controller.signal })
      .then(result => {
        clearTimeout(timeoutTimer);
        const current = pending.get(requestId);
        if (!current || current.status !== 'pending') return;
        if (result.decision !== 'approved' || !result.hostID) {
          current.status = result.decision;
          const errorTarget = new URL(redirectUri);
          errorTarget.searchParams.set('error', 'access_denied');
          if (state) errorTarget.searchParams.set('state', state);
          current.redirect = errorTarget.toString();
          return;
        }
        const code = config.store.createAuthorizationCode({
          hostID: result.hostID,
          clientId,
          clientName: client.clientName,
          redirectUri,
          redirectHost,
          codeChallenge: codeChallenge!,
          resource,
          scope: scopes.scope,
          offlineAccess: scopes.offlineAccess,
        });
        const target = new URL(redirectUri);
        target.searchParams.set('code', code);
        if (state) target.searchParams.set('state', state);
        current.status = 'approved';
        current.redirect = target.toString();
      })
      .catch(() => {
        clearTimeout(timeoutTimer);
        const current = pending.get(requestId);
        if (current && current.status === 'pending') current.status = 'offline';
      });

    return new Response(renderAuthorizePage({ requestId, clientName: client.clientName, redirectHost, code: confirmationCode }), {
      status: 200,
      headers: { ...mcpSecurityHeaders, 'Content-Type': 'text/html; charset=utf-8' },
    });
  }

  function authorizePoll(request: Request): Response {
    const requestId = new URL(request.url).searchParams.get('request_id');
    const record = requestId ? pending.get(requestId) : undefined;
    if (!record) return jsonResponse({ status: 'timeout' });
    if (record.status !== 'pending') return jsonResponse({ status: record.status, redirect: record.redirect });
    if (now() - record.createdAt > AUTHORIZE_APPROVAL_TIMEOUT_MS) return jsonResponse({ status: 'timeout' });
    return jsonResponse({ status: 'pending' });
  }

  function authorizeScript(): Response {
    return new Response(renderAuthorizeScript(), {
      status: 200,
      headers: { ...mcpSecurityHeaders, 'Content-Type': 'text/javascript; charset=utf-8' },
    });
  }

  async function readFormBody(request: Request): Promise<URLSearchParams | undefined> {
    const contentType = request.headers.get('content-type')?.split(';', 1)[0].trim().toLowerCase();
    let bytes: Uint8Array;
    try {
      bytes = await readBodyCapped(request, MAX_TOKEN_BODY_BYTES);
    } catch {
      return undefined;
    }
    const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    if (contentType === 'application/json') {
      try {
        const parsed = JSON.parse(text) as Record<string, unknown>;
        const params = new URLSearchParams();
        for (const [key, value] of Object.entries(parsed)) if (typeof value === 'string') params.set(key, value);
        return params;
      } catch {
        return undefined;
      }
    }
    if (contentType !== 'application/x-www-form-urlencoded') return undefined;
    return new URLSearchParams(text);
  }

  async function token(request: Request): Promise<Response> {
    const body = await readFormBody(request);
    if (!body) return oauthError(400, 'invalid_request');
    const grantType = body.get('grant_type');

    if (grantType === 'authorization_code') {
      const code = body.get('code');
      const redirectUri = body.get('redirect_uri');
      const clientId = body.get('client_id');
      const codeVerifier = body.get('code_verifier');
      const resource = body.get('resource');
      if (!code || !redirectUri || !clientId || !codeVerifier) return oauthError(400, 'invalid_request');
      const pendingCode = config.store.consumeAuthorizationCode(code);
      if (!pendingCode) return oauthError(400, 'invalid_grant');
      if (pendingCode.clientId !== clientId || pendingCode.redirectUri !== redirectUri) return oauthError(400, 'invalid_grant');
      if (resource !== null && resource !== pendingCode.resource) return oauthError(400, 'invalid_target');
      if (!verifyPkceS256(codeVerifier, pendingCode.codeChallenge)) return oauthError(400, 'invalid_grant');

      const { tokens } = config.store.createGrant({
        hostID: pendingCode.hostID,
        clientId: pendingCode.clientId,
        clientName: pendingCode.clientName,
        redirectHost: pendingCode.redirectHost,
        scope: pendingCode.scope,
        offlineAccess: pendingCode.offlineAccess,
      });
      return jsonResponse({
        access_token: tokens.accessToken,
        token_type: 'Bearer',
        expires_in: Math.floor((tokens.accessTokenExpiresAt - now()) / 1000),
        scope: pendingCode.scope.join(' '),
        ...(tokens.refreshToken ? { refresh_token: tokens.refreshToken } : {}),
      });
    }

    if (grantType === 'refresh_token') {
      const refreshToken = body.get('refresh_token');
      if (!refreshToken) return oauthError(400, 'invalid_request');
      const result = config.store.refreshTokens(refreshToken);
      if (result === 'invalid' || result === 'reused_revoked') return oauthError(400, 'invalid_grant');
      const grant = config.store.getGrant(result.grantId);
      if (!grant) return oauthError(400, 'invalid_grant');
      return jsonResponse({
        access_token: result.accessToken,
        token_type: 'Bearer',
        expires_in: Math.floor((result.accessTokenExpiresAt - now()) / 1000),
        scope: grant.scope.join(' '),
        refresh_token: result.refreshToken,
      });
    }

    return oauthError(400, 'unsupported_grant_type');
  }

  async function revoke(request: Request): Promise<Response> {
    const body = await readFormBody(request);
    const tokenValue = body?.get('token');
    if (tokenValue) config.store.revokeToken(tokenValue);
    return new Response(null, { status: 200, headers: mcpSecurityHeaders });
  }

  async function register(request: Request): Promise<Response> {
    if (!dcrLimiter.tryConsume()) return oauthError(429, 'temporarily_unavailable', 'registration rate limit exceeded');
    config.store.expireUnusedDcrClients(DCR_UNUSED_CLIENT_MAX_AGE_MS);
    let bytes: Uint8Array;
    try {
      bytes = await readBodyCapped(request, MAX_TOKEN_BODY_BYTES);
    } catch {
      return oauthError(413, 'invalid_client_metadata');
    }
    let body: unknown;
    try {
      body = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
    } catch {
      return oauthError(400, 'invalid_client_metadata');
    }
    if (typeof body !== 'object' || body === null) return oauthError(400, 'invalid_client_metadata');
    const record = body as Record<string, unknown>;
    const redirectUris = record.redirect_uris;
    if (!Array.isArray(redirectUris) || redirectUris.length === 0 || redirectUris.length > 8 ||
        !redirectUris.every(uri => typeof uri === 'string' && isValidRedirectUri(uri))) {
      return oauthError(400, 'invalid_redirect_uri');
    }
    if (record.token_endpoint_auth_method !== undefined && record.token_endpoint_auth_method !== 'none') {
      return oauthError(400, 'invalid_client_metadata', 'only the none auth method is supported');
    }
    const { clientId } = config.store.registerDcrClient(redirectUris);
    return jsonResponse(
      { client_id: clientId, redirect_uris: redirectUris, token_endpoint_auth_method: 'none', grant_types: ['authorization_code', 'refresh_token'] },
      { status: 201 },
    );
  }

  function verifyBearer(request: Request): { grantId: string; hostID: string; scopes: Scope[]; clientId: string } | undefined {
    const header = request.headers.get('authorization');
    if (!header?.startsWith('Bearer ')) return undefined;
    const token = header.slice('Bearer '.length).trim();
    if (!token) return undefined;
    const grant = config.store.verifyAccessToken(token);
    if (!grant) return undefined;
    return { grantId: grant.grantId, hostID: grant.hostID, scopes: grant.scope, clientId: grant.clientId };
  }

  return {
    protectedResourceMetadata,
    authorizationServerMetadata,
    authorize,
    authorizePoll,
    authorizeScript,
    token,
    revoke,
    register,
    verifyBearer,
    resourceIdentifier: () => resourceIdentifier(config.origin),
  };
}

export type OAuthServer = ReturnType<typeof createOAuthServer>;
