import { fetchMock } from "cloudflare:test";

export type TurnMock = {
  issued: string[];
  revoked: string[];
  generateCalls: number;
  failNext: (count: number) => void;
  reset: () => void;
};

/** Mocks Cloudflare's TURN credential API for the whole test file. Call `install()` in beforeAll. */
export function installTurnMock(): TurnMock {
  const state: TurnMock = {
    issued: [], revoked: [], generateCalls: 0,
    failNext: count => { failures = count; },
    reset: () => { state.issued.length = 0; state.revoked.length = 0; state.generateCalls = 0; failures = 0; },
  };
  let failures = 0;
  fetchMock.activate();
  fetchMock.disableNetConnect();
  const origin = fetchMock.get("https://rtc.live.cloudflare.com");
  origin.intercept({ method: "POST", path: /\/v1\/turn\/keys\/k{32}\/credentials\/generate-ice-servers$/ }).reply(options => {
    state.generateCalls += 1;
    if (failures > 0) { failures -= 1; return { statusCode: 500, data: "provider down" }; }
    const authorization = (options.headers as Record<string, string> | undefined)?.authorization;
    if (authorization !== `Bearer ${"t".repeat(64)}`) return { statusCode: 401, data: "bad token" };
    const username = `user-${state.issued.length + 1}`;
    state.issued.push(username);
    return {
      statusCode: 201,
      data: { iceServers: [
        { urls: ["stun:stun.cloudflare.com:3478"] },
        { urls: ["turn:turn.cloudflare.com:3478?transport=udp", "turns:turn.cloudflare.com:443?transport=tcp"], username, credential: `credential-${username}` },
      ] },
      responseOptions: { headers: { "content-type": "application/json" } },
    };
  }).persist();
  origin.intercept({ method: "POST", path: /\/v1\/turn\/keys\/k{32}\/credentials\/([^/]+)\/revoke$/ }).reply(options => {
    const match = /credentials\/([^/]+)\/revoke$/.exec(options.path);
    state.revoked.push(decodeURIComponent(match![1]!));
    return { statusCode: 204, data: "" };
  }).persist();
  return state;
}
