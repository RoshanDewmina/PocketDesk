# Farside Apple setup receipt — 30 September 2026

Status: **In progress; awaiting user input and individual action approvals.**

Target: Farside: Remote Desktop, App Apple ID `6817532560`, SKU `farside-ios`, iOS bundle `com.roshan.PocketDesk.Remote`, version 1.0 in Prepare for Submission. Mac companion bundle: `com.roshan.PocketDesk.RemoteHost` (Developer ID distribution).

This checkpoint contains no personal, banking, tax, or contact details. Unsaved form preparation is not a completed setup action.

| Task | State | Verified result or remaining requirement |
|---|---|---|
| 1. Updated agreements | Done | Developer account shows the Program License Agreement issued 18 August 2026 and accepted 28 September 2026. Apple identifies Attachment 14 as part of that update, effective 1 October 2026. Free Apps Agreement is Active. The only pending agreement shown in Business is Paid Apps Agreement, New. No new acceptance was performed in this session. |
| 2. Paid Apps Agreement, legal entity, tax, banking | Blocked / needs user | Live Business page shows Paid Apps Agreement Pending User Info, effective 30 September 2026 through 30 May 2027. Bank account, Canadian GST/HST Form 506, and U.S. Tax Questionnaire remain required. User does not have Canadian Business Number/RT; Canadian form cannot be completed in the current flow. Apple's published guidance requires a GST/HST number for Canada-based developers; resolution requires registration or clarification from Apple for an unregistered developer. No registration or support message sent. User completed the U.S. routing questionnaire; both resulting U.S. forms still show Missing Tax Info. W-8BEN is open, with autofilled identity information needing verification and no agent edits or submission. The prior legal address remains displayed, so the prepared address update is not confirmed saved. |
| 3. EU DSA trader declaration | Needs user | Trader wizard was explored and a public support email draft prepared. That unsaved tab has closed; resume the wizard and have the user enter public mailbox address and phone. Apple states P.O. boxes are accepted. Declaration is not submitted or verified. |
| 4. Age rating | Done | User explicitly approved Save, which was clicked. App Information now displays 4+ for 172 countries or regions, AL for Brazil, ALL for Korea, and 00+ for Vietnam. All applicable answers are No/None; age-category override is Not Applicable and optional URL is blank. |
| 5. Persistent Content Capture request | Needs user decision | Historical unsaved draft contained the Mac companion name, exact Mac bundle, functionality answers, and remote-access justification; its tab has closed and must be reconstructed. Apple marks Website, App Store URL, and App Apple ID mandatory. No paired iOS reference was substituted into the required fields. No request submitted. |
| 6. Subscriptions | Needs verification | Paid Apps Agreement has advanced to Pending User Info in the user's screenshot. Verify the signing prerequisite when browser control resumes. No subscription group, products, prices, trials, purchase options, or billing grace settings have been created or changed in this session. |
| 7. Sandbox tester | Needs user | No testers listed when checked. An unsaved New Tester form was prepared with a synthetic Farside Sandbox label and Canada region, but that tab has closed. Reopen the form; user must enter email, password, and password confirmation, then approve Create. No tester created. |

## Age-rating answers saved with user approval

- **No:** Parental Controls; Age Assurance; Unrestricted Web Access; User-Generated Content; Social Media; Social Media Disabled for Users Under 13; Messaging and Chat; Advertising; Health or Wellness Topics; Gambling; Loot Boxes.
- **None:** Profanity or Crude Humor; Horror/Fear Themes; Alcohol, Tobacco, or Drug Use or References; Medical or Treatment Information; Mature or Suggestive Themes; Sexual Content or Nudity; Graphic Sexual Content and Nudity; Cartoon or Fantasy Violence; Realistic Violence; Prolonged Graphic or Sadistic Realistic Violence; Guns or Other Weapons; Simulated Gambling; Contests.
- Calculated rating: **4+**. Age-category override: **Not Applicable**. Optional age-suitability URL: blank.
- Saved regional display: 4+ in 172 countries or regions; Brazil AL; Korea ALL; Vietnam 00+.

## Historical entitlement draft, not submitted or persisted

- App Name: `Farside (Mac companion)`.
- Bundle ID: `com.roshan.PocketDesk.RemoteHost`.
- Primary functionality is remote interaction with authorized devices: **Yes**.
- Remote content functionality: **Screen sharing and remote control**.
- Initiates interaction with authorized devices that may be inaccessible to the owner: **Yes**.
- Justification explains explicit device pairing and Screen Recording/Accessibility consent before departure, owner-initiated sessions from the paired iPhone/iPad while away, recurring capture reapproval interrupting unattended access, and the requested entitlement's use by the Developer ID Mac companion. It expressly identifies the iOS client as the paired client and does not request an entitlement for its bundle.
- Website, App Store URL, and App Apple ID need resolution before submission. No placeholder URL or fabricated Mac App Apple ID entered.
- Entitlement acknowledgment unchecked; Submit not clicked.

## Product identifier precheck

The user-specified identifiers exactly match `RemotePhone/Anywhere/AnywhereEntitlement.swift:6-7` and `StoreKitTesting/FarsideAnywhere.storekit:53,83`:

- `com.roshan.PocketDesk.remote.yearly`
- `com.roshan.PocketDesk.remote.monthly`

This is a source/fixture precheck, not evidence that the products exist in App Store Connect. Subscription creation requires confirmation that the Paid Apps Agreement is signed or Active.

## Timing and next gates

- Live page shows Paid Apps Agreement Pending User Info. No processing duration is shown. Legal-entity update completion remains unverified; no tax, DSA, entitlement request, or tester creation submission has been performed by the agent.
- The user reports Apple's legal-entity update guidance allows up to two weeks. This duration has not yet been displayed or independently verified in the current legal-entity wizard.
- Every Create, Save, Submit, Sign, and Accept click requires a fresh user approval of the specific action. The user granted a narrow exception for entry of the supplied legal address. Other sensitive entries remain user-owned; the home address must never be used for the public DSA declaration.
- After tester creation is verified, sign in on the iPhone under Settings > Developer > Sandbox Apple Account.
- No purchase, app-review submission, Family Sharing enablement, deletion, or post-creation price change was performed.

## Sources

- Signed-in Apple Developer account agreement history and App Store Connect Business, App Information, and Sandbox pages inspected in the browser during this session.
- [Apple's updated license announcement, 18 August 2026](https://developer.apple.com/news/?id=0cgo95n6).
- [Persistent Content Capture request form](https://developer.apple.com/contact/request/persistent-content-capture/).
- [Apple tax-information requirements](https://developer.apple.com/help/app-store-connect/manage-tax-information/provide-tax-information).
- [CRA registration thresholds](https://www.canada.ca/en/revenue-agency/services/tax/businesses/topics/gst-hst-businesses/when-register-charge.html): small-supplier registration rules are separate from Apple's onboarding requirements.

Update this checkpoint as each approved action is executed and its resulting status is verified.

## Latest U.S. tax checkpoint

- User completed the routing questionnaire. Apple now lists U.S. Certificate of Foreign Status of Beneficial Owner and U.S. Form W-8BEN; both still show Missing Tax Info and no submitted date.
- Both forms were inspected without edits, certification, or submission. W-8BEN is open for review and user input.
- User confirmed that autofilled citizenship is incorrect. The field is disabled; permanent residence still reflects the prior legal-entity information and is not directly editable in the inspected form. No tax certification or treaty claim should be submitted with unverified or incorrect information.
- Foreign-status certificate requires declarations concerning beneficial ownership, U.S. employees, and U.S. revenue-producing equipment or assets. These declarations have not been confirmed or selected by the agent.
- Paid Apps Agreement remains Pending User Info; no Active status or processing duration is shown.
- Followed Apple's support route: Reports and Payments > Tax and Banking Setup > Contact Finance. Subject Tax and category Tax information submissions selected. Message field remains blank; support request requires authorization and has not been sent. A draft will ask for the locked-field correction route and guidance for an individual without GST/HST identifiers, without claiming a tax-residency determination.

## Website billing alternative assessed — no migration performed

- User asked whether website payments through Stripe could reduce setup paperwork. This is an assessment, not an implemented change or a confirmed Apple exemption.
- Apple's guideline 3.1.3(f) allows a free companion to a paid web-based tool without IAP when there is no in-app purchase or outside-purchase call to action. Farside's fit is unconfirmed; a general multiplatform feature-unlock model under 3.1.3(b) still requires IAP availability. The remote-desktop guideline is not a blanket exemption for selling Farside's own functionality.
- Proposed model for evaluation: sell the Anywhere service through the website/Mac setup, retain free local-network use, and make the iOS client a free companion with no checkout or purchase steering for the conservative worldwide design. The paid service must genuinely fit the exception; renaming a feature unlock is insufficient.
- Ordinary Stripe payments leave the developer as merchant of record with tax responsibility. Stripe Managed Payments is a separate merchant-of-record offering that handles covered transaction taxes; Canada is a supported business location, but account/product eligibility still requires review. Published fee is 3.5% in addition to payment-processing fees, with subscription Billing charges separate.
- Free distribution without IAP can avoid Apple's paid-sales setup as a monetization prerequisite, subject to actual model approval and the account's current contract state. It does not remove developer agreements, App Review, EU DSA trader requirements, age-rating metadata, Mac distribution/capture requirements, payment-provider verification or the developer's own tax obligations.
- Current source still uses StoreKit and server-enforced subscription access. A website migration needs checkout, customer-to-device/account binding, verified payment webhooks, and server entitlement changes; no such implementation, Stripe activation, price change, agreement acceptance, or support request has occurred.
- Sources: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), [free and paid agreements](https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements/), [Stripe merchant-of-record distinction](https://stripe.com/resources/more/merchant-of-record), [Managed Payments eligibility](https://docs.stripe.com/payments/managed-payments/eligibility), [Managed Payments pricing](https://support.stripe.com/questions/managed-payments-pricing), [Canada verification](https://support.stripe.com/questions/2024-updates-to-canada-verification-requirements-faqs), [DSA requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements).
- User authorized checking both eligibility paths. Detailed findings and exact unsent Apple inquiry are saved in [website billing eligibility](WEBSITE-BILLING-ELIGIBILITY-2026-09-30.md). Apple inquiry is filled and awaits approval of Send message; Stripe is at sign-in awaiting user access. No external inquiry has been sent and no provider-specific eligibility approval has been received.
