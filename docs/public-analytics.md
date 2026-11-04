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
invitation, or billing identifiers. Cookieless pings still send ordinary request and device
information to Google, such as timestamps, browser user-agent details, the sanitized referrer, and
network information used for basic measurement and modeling.

The explicit `page_view` sends a homepage URL containing only valid values for `utm_source`,
`utm_medium`, `utm_campaign`, `utm_content`, and `utm_term`. All other query parameters and the URL
fragment are removed. Referrers are reduced to their origin, so their paths and query strings are
not transmitted. The Google tag script request also uses a no-referrer policy.

Turbo Drive is disabled on the analytics-enabled marketing page, so every navigation away uses a
normal full-page load and the public-homepage tag cannot remain active on `/signup` or application
pages. A browser-history return restored from the back-forward cache records one new homepage
pageview; repeated Stimulus initialization in the same page does not. Reaching `/signup` cannot be
measured safely with the current client-only, homepage-only boundary: doing so would require loading
GA4 on the application layout or adding a new server-side analytics flow. That funnel step is
therefore deferred; `start_free_trial_click` measures intent without expanding analytics into signup
or authenticated pages.

If cookie-based analytics is proposed later, consent requirements and regional behavior must be
decided separately before changing `analytics_storage` from `denied`. No consent interface is
introduced by this implementation.

## Event and campaign naming

The single custom event is `start_free_trial_click`. It has no custom parameters.

Use lowercase snake case for UTM values, with only letters, numbers, and single underscores between
segments, up to 50 characters. Values with spaces, punctuation, uppercase letters, or more than 50
characters are discarded. Keep values stable and never use names, email addresses, customer
identifiers, vessel details, tokens, or other personal or sensitive data.

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
disabled in the GA4 property. In the web stream's Enhanced Measurement settings, disable all
automatic events, including browser-history page changes, so the property receives only the
explicit homepage `page_view` and `start_free_trial_click` events from this integration. Set event
data retention to the shortest available period (2 months) and turn off reset-on-new-activity.

Configure these standard reports without creating a separate dashboard:

1. **Landing Pages:** Reports > Engagement > Landing page. Use Landing page + query string as the
   primary dimension and add Session source / medium or Session campaign as a secondary dimension.
2. **Traffic Acquisition:** Reports > Acquisition > Traffic acquisition. Use Session source / medium
   as the primary dimension and Session campaign for campaign comparisons.
3. **Events:** Reports > Engagement > Events. Confirm `page_view` and `start_free_trial_click`; select
   the custom event to review its count over time.

Cookieless consent mode can limit or model user/session-level reporting. Event counts and the
sanitized campaign/referral fields remain the intended acceptance signals for this initial scope.
Copy the `G-...` measurement ID exactly as shown in the GA4 web stream; the application rejects
lowercase or mixed-case variants rather than transforming the configured identifier.

## Manual acceptance

Use an owner-approved production verification window and a non-customer browser session:

1. Confirm Enhanced Measurement events are off, Google Signals and advertising personalization are
   off, and event-data retention is 2 months with reset-on-new-activity off.
2. Open the production homepage once and confirm one `page_view` in Realtime or DebugView. Navigate
   away and return, then confirm exactly one additional homepage pageview.
3. Open a URL using the documented UTM convention and confirm source, medium, campaign, and the
   referral source in Realtime and the standard acquisition reports.
4. Click **Start Free Trial** once and confirm one `start_free_trial_click` event and normal signup
   navigation.
5. In browser network tools, confirm GA4 requests contain only the sanitized homepage URL, referrer
   origin, fixed event names, consent/measurement metadata, and ordinary request/device/network
   metadata. Confirm there are no names, emails, account/vessel/document data, tokens, Stripe IDs,
   or unapproved query parameters.
6. Confirm no Google tag, retained tag script, or collection request appears on staging
   `/marketing-preview`, `/signup`, sign-in, verification, password-reset, billing, or authenticated
   pages.
7. Block `googletagmanager.com` and `google-analytics.com`; confirm the homepage renders and the CTA
   still reaches signup normally.
8. Confirm the homepage content, navigation, pricing, layout, and interactions are otherwise
   unchanged.

For an ordinary primary activation, the CTA queues the event and keeps the homepage active for a
fixed 300 ms before navigating. Missing or failed analytics never blocks navigation. Modifier
clicks, middle clicks, downloads, and links with a non-default target keep their native browser
behavior without an analytics-driven delay. The 300 ms delay can still apply when the Google tag is
blocked because the local `gtag` queue is available. This is best-effort delivery: keeping the page
active improves the opportunity to start transmission but does not prove GA4 ingested the event.
Browser Back restoration resets the CTA immediately, while an interrupted or canceled navigation
recovers after approximately two seconds without delaying the initial navigation attempt.
