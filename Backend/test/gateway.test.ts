import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { connectHost, open, pairing, payload64, registerMessage } from "./helpers/client";

describe("/signal gateway", () => {
  it("rejects browsers, plain GETs and query strings before any upgrade", async () => {
    expect((await SELF.fetch("https://farside.test/signal", { headers: { upgrade: "websocket", origin: "https://evil.example" } })).status).toBe(403);
    expect((await SELF.fetch("https://farside.test/signal")).status).toBe(426);
    expect((await SELF.fetch("https://farside.test/signal?room=x", { headers: { upgrade: "websocket" } })).status).toBe(404);
    expect((await SELF.fetch("https://farside.test/signal", { method: "POST", headers: { upgrade: "websocket" } })).status).toBe(404);
    expect((await SELF.fetch("https://farside.test/nope")).status).toBe(404);
  });

  it("closes a socket that never registers with authentication_timeout", async () => {
    const idle = await open();
    const message = await idle.next(6000);
    expect(message).toEqual({ type: "error", code: "authentication_timeout" });
    expect((await idle.closed).reason).toBe("authentication_timeout");
  }, 10_000);

  it("forwards frames pipelined right behind register without dropping them", async () => {
    const p = await pairing();
    const host = await connectHost(p);
    const client = await open();
    client.sendRaw(JSON.stringify(registerMessage(p, "client")));
    client.sendRaw(JSON.stringify({ type: "signal", payload: payload64(9) }));
    expect((await client.next()).type).toBe("registered");
    expect((await client.next()).type).toBe("ice");
    expect((await client.next()).online).toBe(true);
    expect((await host.next()).online).toBe(true);
    expect((await host.next()).payload).toBe(payload64(9));
  });

  it("limits upgrades per source address", async () => {
    const headers = { upgrade: "websocket", "cf-connecting-ip": "192.0.2.77" };
    const statuses: number[] = [];
    const sockets: WebSocket[] = [];
    for (let i = 0; i < 31; i++) {
      const response = await SELF.fetch("https://farside.test/signal", { headers });
      statuses.push(response.status);
      if (response.webSocket) { response.webSocket.accept(); sockets.push(response.webSocket); }
    }
    expect(statuses.slice(0, 30).every(status => status === 101)).toBe(true);
    expect(statuses[30]).toBe(429);
    for (const socket of sockets) socket.close(1000, "done");
  });
});
