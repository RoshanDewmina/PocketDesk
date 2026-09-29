import { vi } from "vitest";

export type TurnMock = {
  issued: string[];
  revoked: string[];
  generateCalls: number;
  revokeCalls: number;
  failNext: (count: number) => void;
  failRevokeNext: (count: number) => void;
  reset: () => void;
};

const TURN_ORIGIN = "https://rtc.live.cloudflare.com";
const KEY_PATH = `/v1/turn/keys/${"k".repeat(32)}/credentials/`;

/**
 * Mocks Cloudflare's TURN credential API for the whole test file by spying on the global fetch
 * (the Vitest 4 integration no longer ships `fetchMock`). Call once in `beforeAll`.
 */
export function installTurnMock(): TurnMock {
  let failures = 0;
  let revokeFailures = 0;
  const state: TurnMock = {
    issued: [], revoked: [], generateCalls: 0, revokeCalls: 0,
    failNext: count => { failures = count; },
    failRevokeNext: count => { revokeFailures = count; },
    reset: () => { state.issued.length = 0; state.revoked.length = 0; state.generateCalls = 0; state.revokeCalls = 0; failures = 0; revokeFailures = 0; },
  };
  const original = globalThis.fetch;
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input as RequestInfo, init);
    const url = new URL(request.url);
    if (url.origin !== TURN_ORIGIN) return original(input as RequestInfo, init);
    if (request.method !== "POST" || !url.pathname.startsWith(KEY_PATH)) return new Response("not found", { status: 404 });
    if (request.headers.get("authorization") !== `Bearer ${"t".repeat(64)}`) return new Response("bad token", { status: 401 });
    const rest = url.pathname.slice(KEY_PATH.length);
    if (rest === "generate-ice-servers") {
      state.generateCalls += 1;
      if (failures > 0) { failures -= 1; return new Response("provider down", { status: 500 }); }
      const username = `user-${state.issued.length + 1}`;
      state.issued.push(username);
      return Response.json({ iceServers: [
        { urls: ["stun:stun.cloudflare.com:3478"] },
        { urls: ["turn:turn.cloudflare.com:3478?transport=udp", "turns:turn.cloudflare.com:443?transport=tcp"], username, credential: `credential-${username}` },
      ] }, { status: 201 });
    }
    const revoke = /^([^/]+)\/revoke$/.exec(rest);
    if (revoke) {
      state.revokeCalls += 1;
      if (revokeFailures > 0) { revokeFailures -= 1; return new Response("provider down", { status: 500 }); }
      state.revoked.push(decodeURIComponent(revoke[1]!));
      return new Response(null, { status: 204 });
    }
    return new Response("not found", { status: 404 });
  });
  return state;
}
