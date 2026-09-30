import { describe, expect, test } from "bun:test";
import { GuestService, guestCanonical, grantFields, validGuestGrant, type GuestGrant, type GuestOwner } from "../../Backend/src/guest";
import { base64Encode, randomHex, sha256Hex } from "../../Backend/src/util";

async function keys() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  return { pair, publicKey: base64Encode(new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey))) };
}
async function sign(fields: string[], pair: CryptoKeyPair) {
  return base64Encode(new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, guestCanonical(fields))));
}
async function harness() {
  let now = 100_000, live: GuestOwner | undefined = { socket: {}, client: {}, epoch: "a".repeat(32), expiresAt: 700_000 };
  const owner = live, ownerMessages: any[] = [], guestMessages: any[] = [], closed: object[] = [], revoked: any[] = [];
  let issue: () => Promise<any[]> = async () => [{ urls: ["turn:fixture.invalid"], username: "fixture", credential: "fabricated" }], issues = 0;
  const service = new GuestService({ now: () => now, owner: async () => live,
    sendOwner: (_, guest) => ownerMessages.push(guest), sendGuest: (socket, message) => guestMessages.push({ socket, ...message }),
    closeGuest: socket => closed.push(socket), issue: async () => { issues++; return issue(); }, revoke: servers => revoked.push(servers) });
  async function invitation() {
    const host = await keys(), guest = await keys(), secret = randomHex(), grantID = randomHex(), socket = {};
    const create = { operation: "invite", grantID, inviteHash: await sha256Hex(secret), publicKey: host.publicKey,
      hostID: randomHex(), ownerSessionID: randomHex(), scopeEpoch: "1", geometryEpoch: "2", scopeKind: "window", origin: "https://fixture.invalid", mode: "view", expiresAt: now + 120_000 };
    expect(await service.ownerMessage(owner.socket, create)).toBe(true);
    const nonce = randomHex(), request = { type: "guestRequest", version: 1, room: "b".repeat(64), origin: create.origin, grantID, secret, publicKey: guest.publicKey, agreementKey: guest.publicKey, nonce,
      signature: await sign(["request", create.origin, "b".repeat(64), grantID, guest.publicKey, guest.publicKey, nonce], guest.pair) };
    await service.request(socket, request);
    const pending = ownerMessages.find(x => x.operation === "pending" && x.grantID === grantID);
    expect(pending).toBeDefined(); expect(issues).toBe(0);
    const ticket = randomHex();
    const grant: GuestGrant = { version: 1, hostID: create.hostID, grantID, ownerSessionID: create.ownerSessionID,
      scopeEpoch: "1", geometryEpoch: "2", scopeKind: "window", mode: "view", requestID: pending.requestID,
      recipientPublicKey: guest.publicKey, recipientAgreementKey: guest.publicKey, hostAgreementKey: host.publicKey,
      recipientNonce: nonce, hostNonce: randomHex(), origin: create.origin, issuedAt: now, expiresAt: now + 600_000, ticketHash: await sha256Hex(ticket) };
    const approve = { operation: "approve", grantID, requestID: pending.requestID, grant, ticket, signature: await sign(grantFields(grant), host.pair) };
    return { host, guest, create, grant, approve, ticket, socket, request };
  }
  async function approve(i: Awaited<ReturnType<typeof invitation>>) {
    expect(await service.ownerMessage(owner.socket, i.approve)).toBe(true);
    const a = guestMessages.find(x => x.guest.operation === "approved" && x.guest.grant.grantID === i.grant.grantID).guest;
    return { operation: "redeem", ticket: i.ticket, sessionID: a.sessionID, signature: await sign(["redeem", i.ticket, a.sessionID, i.grant.hostNonce], i.guest.pair) };
  }
  return { service, owner, ownerMessages, guestMessages, closed, revoked, invitation, approve,
    issues: () => issues, setIssue: (next: typeof issue) => { issue = next; }, stopOwner: () => { live = undefined; },
    replaceOwner: () => { live = { ...owner, socket: {} }; }, advance: (ms: number) => { now += ms; } };
}

describe("exact production GuestService with injected owner/provider", () => {
  test("service proof requires exact active session and variant, and fresh current owner", async () => {
    const h = await harness(), i = await h.invitation(), redeem = await h.approve(i);
    await h.service.guestMessage(i.socket, redeem);
    const check = {operation:"check",grantID:i.grant.grantID,sessionID:redeem.sessionID,nonce:randomHex()};
    const before = h.ownerMessages.length;
    expect(await h.service.ownerMessage(h.owner.socket,{...check,ticket:i.ticket})).toBe(false);
    expect(await h.service.ownerMessage(h.owner.socket,{...check,sessionID:randomHex()})).toBe(false);
    expect(await h.service.ownerMessage({},check)).toBe(false);
    expect(h.ownerMessages.length).toBe(before);
    expect(await h.service.ownerMessage(h.owner.socket,check)).toBe(true);
    expect(h.ownerMessages.at(-1)).toEqual({...check,operation:"alive",expiresAt:i.grant.expiresAt});
    h.stopOwner(); expect(await h.service.ownerMessage(h.owner.socket,{...check,nonce:randomHex()})).toBe(false);
    expect(h.ownerMessages.filter(x=>x.operation==="alive").length).toBe(1);
  });
  test("requires exact owner socket; opening/replaying request never grants ICE or owner slot", async () => {
    const h = await harness(), i = await h.invitation();
    expect(await h.service.ownerMessage({}, i.approve)).toBe(false);
    expect(h.issues()).toBe(0); expect(h.guestMessages.length).toBe(0);
    await h.service.request({}, i.request); expect(h.closed.length).toBe(1); expect(h.issues()).toBe(0);
  });
  test("rejects recipient/epoch/mode changes even when malicious owner re-signs them", async () => {
    const h = await harness(), i = await h.invitation();
    for (const mutation of [{ scopeEpoch: "3" }, { geometryEpoch: "3" }, { recipientPublicKey: i.host.publicKey }, { mode: "control" }]) {
      const grant = { ...i.grant, ...mutation };
      expect(await h.service.ownerMessage(h.owner.socket, { ...i.approve, grant, signature: await sign(grantFields(grant), i.host.pair) })).toBe(false);
    }
    expect(h.issues()).toBe(0);
  });
  test("consumes ticket before provider await and discards delayed credentials after revoke", async () => {
    const h = await harness(), i = await h.invitation(), redeem = await h.approve(i);
    let release!: (v: any[]) => void;
    h.setIssue(() => new Promise(resolve => { release = resolve; }));
    const pending = h.service.guestMessage(i.socket, redeem);
    for (let n = 0; n < 50 && !release; n++) await new Promise(resolve => setTimeout(resolve, 1));
    expect(h.issues()).toBe(1);
    await h.service.guestMessage(i.socket, redeem); // replay while issuing terminally ends only this guest
    release([{ urls: ["turn:fixture.invalid"], username: "late", credential: "fabricated" }]); await pending;
    expect(h.issues()).toBe(1); expect(h.revoked.length).toBe(1);
    expect(h.guestMessages.some(x => x.guest.operation === "ready")).toBe(false);
  });
  test("owner replacement during delayed issuance rejects old callback", async () => {
    const h = await harness(), i = await h.invitation(), redeem = await h.approve(i);
    let release!: (v: any[]) => void; h.setIssue(() => new Promise(resolve => { release = resolve; }));
    const pending = h.service.guestMessage(i.socket, redeem);
    for (let n = 0; n < 50 && !release; n++) await new Promise(resolve => setTimeout(resolve, 1));
    h.replaceOwner(); release([{ urls: ["turn:fixture.invalid"], username: "late", credential: "fabricated" }]); await pending;
    expect(h.revoked.length).toBe(1); expect(h.guestMessages.some(x => x.guest.operation === "ready")).toBe(false);
  });
  test("two parallel approvals cannot exceed two active guests", async () => {
    const h = await harness(), first = await h.invitation(); await h.approve(first);
    const second = await h.invitation(), third = await h.invitation();
    const result = await Promise.all([h.service.ownerMessage(h.owner.socket, second.approve), h.service.ownerMessage(h.owner.socket, third.approve)]);
    expect(result.filter(Boolean).length).toBe(1);
  });
  test("expired pending ticket and lost paid owner fail closed before provider", async () => {
    const h = await harness(), i = await h.invitation(), redeem = await h.approve(i);
    h.advance(30_001); await h.service.guestMessage(i.socket, redeem); expect(h.issues()).toBe(0); expect(h.closed.length).toBe(1);
    const other = await harness(), j = await other.invitation(); other.stopOwner(); await other.service.audit();
    expect(other.closed.length).toBe(1); expect(other.issues()).toBe(0);
  });
  test("strict grant numbers and capability prevent wildcard/legacy authority", async () => {
    const h = await harness(), i = await h.invitation();
    expect(validGuestGrant(i.grant, 100_000)).toBe(true);
    for (const mutation of [{ scopeEpoch: "01" }, { scopeEpoch: "18446744073709551616" }, { mode: "interactive" }, { expiresAt: 99_999 }, { ownerKey: "secret" }, { origin: "https://fixture.invalid/path" }]) expect(validGuestGrant({ ...i.grant, ...mutation }, 100_000)).toBe(false);
  });
});
