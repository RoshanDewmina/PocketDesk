/**
 * The beta email waitlist (functions/api/waitlist.ts, D1 `farside-waitlist`). Off since 1 Oct 2026: the site has
 * no sign-up form and the endpoint answers 410 to everyone. Turning it back on needs a mailing address in the
 * consent wording first (CASL), plus the form itself, which was removed from the pages.
 * site.config.ts re-exports this as `config.waitlist.enabled`; it lives here so the Pages Function can read it.
 */
export const WAITLIST_ENABLED: boolean = false;
