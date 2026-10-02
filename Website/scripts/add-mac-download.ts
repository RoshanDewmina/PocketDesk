// Copies the notarized Farside for Mac DMG into dist/ at config.launch.macDownloadUrl, after checking its size
// and SHA-256 against site.config.ts. The DMG stays out of git; run this after every build, before deploying.
//   bun scripts/add-mac-download.ts /path/to/Farside-for-Mac-1.0-20261002.3.dmg

import { mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { config } from "../site.config";
import { DIST } from "./build";

const src = process.argv[2];
const { macDownloadUrl: url, macSha256: sha, macBytes: bytes } = config.launch;
if (!src) throw new Error("usage: bun scripts/add-mac-download.ts <path to the DMG>");
if (!url || !url.startsWith("/downloads/") || !sha || !bytes) throw new Error("site.config.ts launch.macDownloadUrl (/downloads/…), macSha256 and macBytes must be set");

const file = Bun.file(src);
if (!(await file.exists())) throw new Error(`no such file: ${src}`);
const data = await file.arrayBuffer();
const actual = new Bun.CryptoHasher("sha256").update(data).digest("hex");
if (data.byteLength !== bytes) throw new Error(`size ${data.byteLength} ≠ launch.macBytes ${bytes}`);
if (actual !== sha) throw new Error(`SHA-256 ${actual} ≠ launch.macSha256 ${sha}`);
if (data.byteLength > 25 * 1024 * 1024) throw new Error("Cloudflare Pages serves files up to 25 MiB");

const out = join(DIST, url);
await mkdir(dirname(out), { recursive: true });
await Bun.write(out, data);
console.log(`added ${url} (${data.byteLength} bytes, sha256 ${actual})`);
