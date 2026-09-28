import { resolve } from 'node:path';
import { WebStandardStreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js';
import type { HostBridge } from './bridge';
import { FrameStore } from './frames';
import { createOAuthServer } from './oauth';
import { McpStore } from './store';
import { buildMcpServer } from './tools';
import { jsonResponse, mcpSecurityHeaders, oauthError } from './util';

export type McpAppDeps = {
  origin: string;
  privateDir: string;
  now?: () => number;
  random?: () => string;
  host: HostBridge;
  fetchImpl?: typeof fetch;
};

const FRAME_ID_ROUTE = /^\/mcp-ui\/frame\/([a-f0-9]{32})$/;

export function createMcpApp(deps: McpAppDeps) {
  const now = deps.now ?? Date.now;
  const store = new McpStore(resolve(deps.privateDir, 'mcp-tokens.json'), now);
  const frames = new FrameStore();
  const oauthServer = createOAuthServer({ origin: deps.origin, store, host: deps.host, now, fetchImpl: deps.fetchImpl });

  const unsubscribeRevoke = deps.host.onGrantRevoked(({ hostID, grantId }) => {
    if (grantId) store.revokeGrant(grantId);
    else store.revokeGrantsForHost(hostID);
  });

  const bearerChallenge = () =>
    `Bearer resource_metadata="${deps.origin}/.well-known/oauth-protected-resource"`;

  async function handleMcp(request: Request): Promise<Response> {
    const auth = oauthServer.verifyBearer(request);
    if (!auth) {
      return oauthError(401, 'unauthorized', undefined, { 'WWW-Authenticate': bearerChallenge() });
    }
    // Stateless mode requires a fresh transport per request (the SDK refuses to reuse one),
    // and a Protocol instance accepts only one live transport at a time, so each request also
    // gets its own (cheap: just a handful of tool/resource registrations) McpServer instance.
    // enableJsonResponse: stateless mode plus a fresh transport-per-request means there is no
    // long-lived SSE stream to keep open across requests, so resolve with a single JSON body.
    const transport = new WebStandardStreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
    const mcpServer = buildMcpServer({ origin: deps.origin, host: deps.host, frames, now });
    await mcpServer.connect(transport);
    try {
      return await transport.handleRequest(request, {
        authInfo: {
          token: 'redacted',
          clientId: auth.clientId,
          scopes: auth.scopes,
          resource: new URL(oauthServer.resourceIdentifier()),
          extra: { grantId: auth.grantId, hostID: auth.hostID },
        },
      });
    } finally {
      await transport.close();
    }
  }

  function handleFrame(request: Request, id: string): Response {
    const auth = oauthServer.verifyBearer(request);
    if (!auth) return oauthError(401, 'unauthorized', undefined, { 'WWW-Authenticate': bearerChallenge() });
    const jpeg = frames.take(id, auth.grantId, now);
    if (!jpeg) return new Response('Not found', { status: 404, headers: mcpSecurityHeaders });
    return new Response(jpeg, {
      status: 200,
      headers: { ...mcpSecurityHeaders, 'Content-Type': 'image/jpeg', 'Content-Length': String(jpeg.byteLength) },
    });
  }

  return {
    async handle(request: Request): Promise<Response | null> {
      const url = new URL(request.url);
      const { pathname } = url;

      if (pathname === '/.well-known/oauth-protected-resource' && request.method === 'GET') {
        return jsonResponse(oauthServer.protectedResourceMetadata());
      }
      if (pathname === '/.well-known/oauth-authorization-server' && request.method === 'GET') {
        return jsonResponse(oauthServer.authorizationServerMetadata());
      }
      if (pathname === '/oauth/authorize' && request.method === 'GET') return oauthServer.authorize(request);
      if (pathname === '/oauth/authorize/poll' && request.method === 'GET') return oauthServer.authorizePoll(request);
      if (pathname === '/mcp-ui/authorize.js' && request.method === 'GET') return oauthServer.authorizeScript();
      if (pathname === '/oauth/token' && request.method === 'POST') return oauthServer.token(request);
      if (pathname === '/oauth/revoke' && request.method === 'POST') return oauthServer.revoke(request);
      if (pathname === '/oauth/register' && request.method === 'POST') return oauthServer.register(request);

      if (pathname === '/mcp') return handleMcp(request);

      const frameMatch = FRAME_ID_ROUTE.exec(pathname);
      if (frameMatch && request.method === 'GET') return handleFrame(request, frameMatch[1]);

      return null;
    },
    /** Wiring point for the parent's /browser-host handling of Mac-initiated grant management UI. */
    listGrants(hostID: string) {
      return store.listGrantsForHost(hostID);
    },
    revokeGrant(grantId: string) {
      return store.revokeGrant(grantId);
    },
    async stop() {
      unsubscribeRevoke();
    },
  };
}

export type McpApp = ReturnType<typeof createMcpApp>;
export type { HostBridge } from './bridge';
