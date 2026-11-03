# Public Homepage Analytics

Boat Binder uses Google Analytics 4 only on the production public homepage. The integration is
disabled unless `GOOGLE_ANALYTICS_MEASUREMENT_ID` contains a valid `G-...` measurement ID, the Rails
environment is production, and the request host is exactly `boat-binder.com` or
`www.boat-binder.com`.

## Privacy boundary

The browser sets GA4 consent defaults for analytics and advertising storage to `denied` before it
loads the Google tag. Google Signals, advertising personalization, advertising data, and URL
passthrough are also disabled. This provides cookieless measurement and does not create a Google
User-ID or attach Boat Binder customer, account, vessel, document, authentication, verification,
invitation, or billing identifiers.

The explicit `page_view` sends a homepage URL containing only valid values for `utm_source`,
`utm_medium`, `utm_campaign`, `utm_content`, and `utm_term`. All other query parameters and the URL
fragment are removed. Referrers are reduced to their origin, so their paths and query strings are
not transmitted. The Google tag script request also uses a no-referrer policy.

The signup link performs a normal full-page navigation so the public-homepage tag does not remain
active on `/signup`. Reaching `/signup` cannot be measured safely with the current client-only,
homepage-only boundary: doing so would require loading GA4 on the application layout or adding a
new server-side analytics flow. That funnel step is therefore deferred; `start_free_trial_click`
measures intent without expanding analytics into signup or authenticated pages.

If cookie-based analytics is proposed later, consent requirements and regional behavior must be
decided separately before changing `analytics_storage` from `denied`. No consent interface is
introduced by this implementation.

## Event and campaign naming

The single custom event is `start_free_trial_click`. It has no custom parameters.

Use lowercase snake case for UTM values. Keep values stable and avoid names, email addresses,
customer identifiers, vessel details, or other personal or sensitive data.

| Channel | `utm_source` | `utm_medium` | Example `utm_campaign` |
| --- | --- | --- | --- |
| Instagram | `instagram` | `social` | `launch_2026` |
| Printed flyer or QR code | `print` | `qr_code` | `launch_2026` |
| Personal website | `renee_website` | `referral` | `boat_binder` |
| Hayes Yacht Company | `hayes_yacht_company` | `referral` | `boat_binder` |
| Referral partner | stable partner slug, such as `partner_name` | `referral` | `boat_binder` |

Use `utm_content` only to distinguish placements within the same campaign. Reserve `utm_term` for
paid-search keywords if paid search is introduced later.

## GA4 property setup

Use a dedicated Boat Binder web data stream. Keep Google Signals and advertising personalization
disabled in the GA4 property, and disable Enhanced Measurement events so the property receives only
the explicit homepage `page_view` and `start_free_trial_click` events from this integration.

Configure these standard reports without creating a separate dashboard:

1. **Landing Pages:** Reports > Engagement > Landing page. Use Landing page + query string as the
   primary dimension and add Session source / medium or Session campaign as a secondary dimension.
2. **Traffic Acquisition:** Reports > Acquisition > Traffic acquisition. Use Session source / medium
   as the primary dimension and Session campaign for campaign comparisons.
3. **Events:** Reports > Engagement > Events. Confirm `page_view` and `start_free_trial_click`; select
   the custom event to review its count over time.

Cookieless consent mode can limit or model user/session-level reporting. Event counts and the
sanitized campaign/referral fields remain the intended acceptance signals for this initial scope.

## Manual acceptance

Use an owner-approved production verification window and a non-customer browser session:

1. Open the production homepage once and confirm one `page_view` in Realtime or DebugView.
2. Open a URL using the documented UTM convention and confirm source, medium, and campaign values.
3. Click **Start Free Trial** once and confirm one `start_free_trial_click` event and normal signup
   navigation.
4. In browser network tools, confirm GA4 requests contain only the sanitized homepage URL, referrer
   origin, fixed event names, measurement metadata, and ordinary device/network metadata. Confirm
   there are no names, emails, account/vessel/document data, tokens, Stripe IDs, or unapproved query
   parameters.
5. Confirm no Google tag or collection request appears on staging `/marketing-preview`, `/signup`,
   sign-in, verification, password-reset, billing, or authenticated pages.
6. Block `googletagmanager.com` and `google-analytics.com`; confirm the homepage renders and the CTA
   still reaches signup normally.
7. Confirm the homepage content, navigation, pricing, layout, and interactions are otherwise
   unchanged.
