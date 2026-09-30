# Commerce preparation and unmetered lifetime decision

Status: source prepared; offer economics decision pending. No checkout, provider, portal or deployment change was performed. This record supersedes the historical D3 “no lifetime at launch” recommendation for current implementation scope: full lifetime and founder requirements remain active. A founder subscription or undisclosed usage limit does not satisfy the lifetime requirement.

## Current coherent product

The prepared iPhone product uses localized StoreKit subscription prices and eligible configured introductory terms, with verified local access free and remote access requiring service-confirmed billing plus independent pairing/current route authority. Restoring billing cannot pair a Mac, obtain a control token or establish a route. Monthly CA$7.99, yearly CA$59.99, a configured eligible seven-day trial and rounded-down 37% yearly savings match the StoreKit fixture and prepared website. Actual storefront price and eligibility win; mixed currencies, non-one-month/year durations, invalid prices and unknown trial units cannot produce comparison claims. `pricesFinal` and service readiness remain false until live acceptance.

The current shipping preparation is IAP. A web-first product is a separate conditional distribution decision: Apple 3.1.3(f) permits a free stand-alone companion of a paid web tool under its conditions, including no in-app purchase or external purchase calls to action. Apple 3.1.3(b) addresses multiplatform services and corresponding IAP availability. This is a policy reading, not an Apple eligibility determination. Do not mix a web checkout CTA into this IAP app or use regional exceptions without explicit territory review. Re-evaluate the complete binary/site/reviewer story if choosing web-first. [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

## Full lifetime and founder offer preparation

Both offers remain required preparation candidates. Intended entitlement: a one-time lifetime purchase with unmetered permitted remote use, independent owner pairing/control/route proof and no hidden hours/bitrate/relay caps. A founding cohort may receive a distinct one-time price and cohort acknowledgement, while keeping the same full lifetime access. Cohort size, price, refund/support reserve, service continuity obligation and successor/shutdown remedy remain explicit unresolved decisions. None is replaced by a recurring founder plan. No lifetime StoreKit product ID or live offer is activated before those decisions and verification/restore/revocation contracts are approved.

`Scripts/commerce-economics.py` models this obligation without metering it away. It accepts scenario FX and commission, uses aggregate provider-charged outbound Mbps (including overhead), usage hours and relay fraction, and calculates 10/20/40-year and perpetual liability. Run:

```sh
python3 Scripts/commerce-economics.py --cad-per-usd 1.35 --commission .15
python3 Scripts/test-commerce-economics.py
```

1.35CAD/USD is an editable sensitivity input, not a current exchange quote.15%/30% are fee scenarios; Small Business approval is not established. Apple describes reduced 15% for qualifying approved participants. [Apple Small Business Program](https://developer.apple.com/app-store/small-business-program/)

Verified unit assumption: Cloudflare TURN charges USD 0.05/GB of edge-to-client outbound traffic including TURN overhead. The1000 GB free tier is shared across Realtime SFU/TURN and is not a per-owner lifetime subsidy; model marginal cost without it. STUN is free. [Cloudflare TURN FAQ](https://developers.cloudflare.com/realtime/turn/faq/)

Workload quantities are unmeasured scenarios, not product measurements. `COMMERCE-SENSITIVITY-SCENARIO.csv` contains the15%/1.35 case. Light 4 Mbps × 4 h/month × 20% relay costsUSD 0.072/month; regular 8 Mbps × 20 h × 50% costsUSD1.80/month; heavy 16 Mbps × 80 h × 100% costsUSD28.80/month. Heavy ten-year relay cost alone isUSD 3456, exceeding the illustrative CA$199 lifetime net USD 125.30. The illustrative price is not recommended or offered. A positive perpetual cost has unbounded undiscounted liability; a 5% discount scenario is a financing assumption, not a guarantee or permission to end access. Lifetime heavy-tail economics remain unresolved even when mean cohort usage appears attractive.

The model excludes actual support, signaling, storage, taxes, refunds, fraud, acquisition, maintenance and future provider price changes unless entered as scenarios. Zero support cost means “excluded”, not “verified free”. There is no validated usage distribution or survivorship estimate. Required decision evidence: measured aggregate egress/relay share by route, billed provider agreement, fee/tax treatment, support cost, retention/tail and reserve stress cases. Preserve unmetered lifetime access while solving funding, price/cohort/reserve and continuity obligations. If the obligation cannot be responsibly funded, report that feasibility failure and keep the requirement open; do not silently substitute a capped or subscription offer.

## Gates

Source arithmetic/localization tests and fixture prices are separate from live StoreKit purchase/restore/refund, service verification, App Review eligibility, real provider billing, equalized storefront pricing and physical local/WAN acceptance. Those gates remain open. Lifetime/founder activation and web-first selection remain pending economics/owner decisions after concrete evidence, not an operational action in this source lane.
