import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";
import { generateTestChain, serializeChain } from "./test/helpers/apple-chain";
import { base64Encode } from "./src/util";

export default defineConfig({
  plugins: [
    cloudflareTest(async () => {
      const migrations = await readD1Migrations(path.join(__dirname, "migrations"));
      // A throwaway Apple-shaped chain, generated per run: the Worker pins its root, tests sign with its leaf.
      const chain = await generateTestChain();
      return {
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            TEST_APPLE_CHAIN: serializeChain(chain),
            APPLE_ROOT_CERTS: base64Encode(chain.rootDer),
            ENVIRONMENT_NAME: "test",
            ALLOW_XCODE_TRANSACTIONS: "0",
            ACCEPT_SANDBOX: "1",
            // Test-only values; production secrets are set with `wrangler secret put`.
            ENTITLEMENT_TOKEN_KEY: "test-entitlement-token-key-0123456789abcdef0123456789abcdef",
            ENTITLEMENT_HASH_KEY: "test-entitlement-hash-key-0123456789abcdef0123456789abcdef",
            ADMIN_TOKEN: "test-admin-token-0123456789abcdef0123456789abcdef",
            CLOUDFLARE_TURN_KEY_ID: "k".repeat(32),
            CLOUDFLARE_TURN_KEY_API_TOKEN: "t".repeat(64),
          },
        },
      };
    }),
  ],
  test: {
    setupFiles: ["./test/setup.ts"],
    testTimeout: 20_000,
    hookTimeout: 20_000,
  },
});
