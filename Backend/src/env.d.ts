// Server-only secrets are configured outside wrangler vars. Keep this declaration stable
// when regenerating Worker bindings with `wrangler types --strict-vars false`.
interface __BaseEnv_Env {
	ENTITLEMENT_TOKEN_KEY: string;
	ENTITLEMENT_HASH_KEY: string;
	ADMIN_TOKEN: string;
	CLOUDFLARE_TURN_KEY_ID: string;
	CLOUDFLARE_TURN_KEY_API_TOKEN: string;
	APPLE_ROOT_CERTS: string;
	APPLE_IAP_ISSUER_ID: string;
	APPLE_IAP_KEY_ID: string;
	APPLE_IAP_PRIVATE_KEY: string;
	APNS_TEAM_ID?: string;
	APNS_KEY_ID?: string;
	APNS_PRIVATE_KEY?: string;
}
