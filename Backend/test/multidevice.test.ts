import { evictDurableObject, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import type { Config } from "../src/config";
import type { RoomDO } from "../src/room";
import { randomHex, sha256Hex } from "../src/util";
import { connectClient, connectHost, open, pairing, payload64, registerMessage, testEnv, type Pairing } from "./helpers/client";

const rooms = () => testEnv.ROOM as unknown as DurableObjectNamespace<RoomDO>;
const stubFor = (room: string) => rooms().get(rooms().idFromName(room));
async function devices(count = 5): Promise<Pairing[]> {
  const primary = await pairing();
  const peers = [primary];
  for (let i = 1; i < count; i += 1) {
    const clientToken = randomHex();
    peers.push({ ...primary, clientToken, clientTokenHash: await sha256Hex(clientToken) });
  }
  return peers;
}
const registration = (peers: Pairing[]) => ({ features: ["devices.1"], clientTokenHashes: peers.map(peer => peer.clientTokenHash) });

describe("separate device trust in a stable Mac room", () => {
  it("admits each of five distinct tokens sequentially, preserving the host and opaque exchange", async () => {
    const peers = await devices();
    const primary = peers[0]!;
    const host = await connectHost(primary, registration(peers));
    expect(host.registered.features).toEqual(["devices.1"]);
    try {
      for (const peer of peers) {
        const client = await connectClient(peer);
        expect(await host.next()).toEqual({ type: "peer", online: true });
        expect(await client.next()).toEqual({ type: "peer", online: true });
        client.send({ type: "signal", payload: payload64(3) });
        expect((await host.next()).payload).toBe(payload64(3));
        client.close();
        expect(await host.next()).toEqual({ type: "peer", online: false });
      }
      expect(await stubFor(primary.room).snapshot()).toMatchObject({ hostOnline: true, clientOnline: false });
      // Notification alerts remain bound to the scalar primary; a secondary cannot overwrite it.
      expect(await stubFor(primary.room).authenticatePush(primary.room, primary.clientToken)).toBe(true);
      expect(await stubFor(primary.room).authenticatePush(primary.room, peers[1]!.clientToken)).toBe(false);
    } finally { host.close(); }
  });

  it("rejects an unknown token and a second trusted device without evicting a quiet active controller", async () => {
    const peers = await devices(2);
    const primary = peers[0]!;
    const host = await connectHost(primary, registration(peers));
    const client = await connectClient(peers[1]!);
    await host.next(); await client.next();
    await runInDurableObject(stubFor(primary.room), (instance, ctx) => {
      const internals = instance as unknown as { config: Config };
      internals.config = { ...internals.config, replaceQuietMs: 5000 };
      for (const ws of ctx.getWebSockets()) {
        const attachment = ws.deserializeAttachment() as Record<string, unknown>;
        if (attachment.role === "client" && attachment.authenticated) ws.serializeAttachment({ ...attachment, lastSeenAt: Date.now() - 60_000 });
      }
    });
    try {
      const unknown = await open();
      unknown.send({ ...registerMessage(primary, "client"), token: randomHex() });
      expect((await unknown.next()).code).toBe("host_unavailable_or_unauthorized");
      await unknown.closed;
      const busy = await open();
      busy.send(registerMessage(primary, "client"));
      expect((await busy.next()).code).toBe("already_connected");
      await busy.closed;
      expect(client.ws.readyState).toBe(WebSocket.OPEN);
      host.send({ type: "signal", payload: payload64(4) });
      expect((await client.next()).payload).toBe(payload64(4));
      expect(await stubFor(primary.room).snapshot()).toMatchObject({ hostOnline: true, clientOnline: true });
      const reconnect = await connectClient(peers[1]!);
      try {
        expect((await client.next()).code).toBe("replaced");
        expect((await client.closed).reason).toBe("replaced");
        expect(await host.next()).toEqual({ type: "peer", online: false });
        expect(await host.next()).toEqual({ type: "peer", online: true });
        expect(await reconnect.next()).toEqual({ type: "peer", online: true });
        reconnect.send({ type: "signal", payload: payload64(5) });
        expect((await host.next()).payload).toBe(payload64(5));
      } finally { reconnect.close(); }
    } finally { client.close(); host.close(); }
  });

  it("persists authorized tokens through hibernation and revokes a removed secondary on host reconnect", async () => {
    const peers = await devices(2);
    const primary = peers[0]!;
    const host = await connectHost(primary, registration(peers));
    await evictDurableObject(stubFor(primary.room));
    const secondary = await connectClient(peers[1]!);
    await secondary.next(); await host.next();
    host.close();
    expect((await secondary.closed).reason).toBe("host_disconnected");
    const replacement = await connectHost(primary, registration([primary]));
    try {
      const removed = await open();
      removed.send(registerMessage(peers[1]!, "client"));
      expect((await removed.next()).code).toBe("host_unavailable_or_unauthorized");
      await removed.closed;
      const stillTrusted = await connectClient(primary);
      expect((await replacement.next()).online).toBe(true);
      stillTrusted.close();
    } finally { replacement.close(); }
  });

  it("keeps legacy scalar registration limited to its original device", async () => {
    const peers = await devices(2);
    const host = await connectHost(peers[0]!);
    try {
      expect(host.registered.features).toBeUndefined();
      const secondary = await open();
      secondary.send(registerMessage(peers[1]!, "client"));
      expect((await secondary.next()).code).toBe("host_unavailable_or_unauthorized");
      await secondary.closed;
      const primary = await connectClient(peers[0]!);
      expect((await host.next()).online).toBe(true);
      primary.close();
    } finally { host.close(); }
  });
});
