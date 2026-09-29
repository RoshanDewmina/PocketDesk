#!/usr/bin/env bun
// Owner tool: fetches Apple's root certificates from apple.com over HTTPS, checks each is a
// self-signed certificate our verifier can parse, prints its SHA-256 fingerprint and validity,
// and prints the value for the APPLE_ROOT_CERTS secret. Nothing is written unless --write-dev-vars.
//   bun scripts/apple-roots.ts            (G3 only, the chain StoreKit uses today)
//   bun scripts/apple-roots.ts --with-g2  (also pin Apple Root CA - G2)
import { parseCertificate, verifySignedBy } from "../src/apple/x509";
import { base64Encode, bytesToHex } from "../src/util";

const sources = [
  { name: "Apple Root CA - G3", url: "https://www.apple.com/certificateauthority/AppleRootCA-G3.cer" },
  ...(Bun.argv.includes("--with-g2") ? [{ name: "Apple Root CA - G2", url: "https://www.apple.com/certificateauthority/AppleRootCA-G2.cer" }] : []),
];

const pins: string[] = [];
for (const source of sources) {
  const response = await fetch(source.url);
  if (!response.ok) throw new Error(`${source.name}: HTTP ${response.status}`);
  const der = new Uint8Array(await response.arrayBuffer());
  if (der.length > 4096) throw new Error(`${source.name}: unexpectedly large (${der.length} bytes)`);
  const cert = parseCertificate(der);
  const selfSigned = await verifySignedBy(cert, cert);
  if (!selfSigned) throw new Error(`${source.name}: not self-signed or unsupported algorithm`);
  const fingerprint = bytesToHex(new Uint8Array(await crypto.subtle.digest("SHA-256", der))).match(/.{2}/g)!.join(":").toUpperCase();
  console.log(`${source.name}`);
  console.log(`  source      ${source.url}`);
  console.log(`  key         ${cert.publicKeyAlgorithm.kind === "ec" ? `EC ${cert.publicKeyAlgorithm.curve}` : "RSA"}`);
  console.log(`  valid       ${new Date(cert.notBefore).toISOString()} → ${new Date(cert.notAfter).toISOString()}`);
  console.log(`  sha256      ${fingerprint}`);
  console.log(`  compare the fingerprint with the one shown when you open the .cer in Keychain Access before trusting it`);
  pins.push(base64Encode(der));
}

const value = pins.join(",");
console.log("\nAPPLE_ROOT_CERTS value (paste when prompted by `bunx wrangler secret put APPLE_ROOT_CERTS --env <env>`):\n");
console.log(value);

if (Bun.argv.includes("--write-dev-vars")) {
  const path = new URL("../.dev.vars", import.meta.url);
  const current = await Bun.file(path).text().catch(() => "");
  const next = current.match(/^APPLE_ROOT_CERTS=.*$/m)
    ? current.replace(/^APPLE_ROOT_CERTS=.*$/m, `APPLE_ROOT_CERTS=${value}`)
    : `${current.trimEnd()}\nAPPLE_ROOT_CERTS=${value}\n`;
  await Bun.write(path, next);
  console.log("\nwrote APPLE_ROOT_CERTS to .dev.vars");
}
