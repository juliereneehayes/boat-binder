# Stripe Foundation

Boat Binder uses the official `stripe` Ruby gem for verified webhook receipt. Local `Subscription` records remain the app source of truth for access and UI behavior; normal app requests do not call Stripe to decide access.

## Subscription Plan Catalog

`Billing::SubscriptionPlanCatalog` is the local, immutable source for customer-facing plan metadata.
The initial `self_managed` application plan has two billing options:

- `self_managed_monthly`: $14 per month with 7-day trial metadata
- `self_managed_annual`: $154 per year (one month free) with 7-day trial metadata

Stripe Products and Prices are created outside Boat Binder in Stripe. Configure their Price IDs with:

- `STRIPE_SELF_MANAGED_MONTHLY_PRICE_ID`
- `STRIPE_SELF_MANAGED_ANNUAL_PRICE_ID`

Use test-mode Price IDs in development and staging. Configure live-mode IDs separately before launch.
Catalog loading and lookup read local configuration only and never call Stripe. Checkout uses these
trusted options; the browser submits only an option key and never a Stripe Price ID.

Webhook endpoint:

```text
POST https://app.boat-binder.com/webhooks/stripe
```

The endpoint verifies the raw request body with `Stripe::Webhook.construct_event`, stores event metadata in `billing_webhook_events`, and uses a unique `[provider, external_event_id]` index for idempotency. Full raw payloads, API keys, and signing secrets are not stored.

## Checkout Architecture

Authenticated owner editors with exactly one active client account can choose either Self Managed
billing option at `/billing/checkout`. Boat Binder resolves the account from the authenticated
membership and resolves the Stripe Price ID from the server-side catalog. Client-supplied Account,
Price, Customer, or Subscription identifiers are not used.

`Billing::StripeCheckoutSessionCreator` creates or reuses the local Account's Stripe Customer and
creates a Stripe-hosted Checkout Session in `subscription` mode. It applies the catalog's trial
duration, always collects a payment method for post-trial billing, and sends server-generated success
and cancellation URLs. Customer creation uses a stable idempotency key. The success and cancellation
pages are display-only and never change local subscription state.

Checkout metadata contains a purpose-specific signed Account reference and stable Boat Binder option
key. Webhook synchronization does not trust metadata alone: it resolves the persisted local
Subscription through the Stripe Customer or Subscription identifier, rejects cross-account
mismatches, and verifies the event's Price against the catalog.

Verified events actively processed in this phase:

- `checkout.session.completed` associates the Stripe Subscription identifier with the Account's
  already-persisted Stripe Customer association. It does not infer or grant `trialing` status.
- `customer.subscription.created`
- `customer.subscription.updated`

Subscription lifecycle events map Stripe's signed status and timestamps into the existing local
`Subscription`. The Price in the event determines the stable Boat Binder plan. No follow-up Stripe
request is made to decide application access.

Still deferred and recorded as ignored:

- `customer.subscription.deleted`
- `invoice.paid`
- `invoice.payment_failed`
- `invoice.payment_succeeded`
- unknown event types

Receipts that were already marked `ignored` before these Checkout handlers shipped remain completed
and are not replayed automatically. Checkout was not available before this implementation, so no
production Checkout receipts are expected to require migration. A verified event that fails with an
unexpected internal error remains retryable; an event with an invalid Account/Customer/Subscription
association is safely recorded as ignored without mutating another Account.

## Local Stripe CLI Testing

1. Install and authenticate the Stripe CLI using Stripe's official instructions.
2. Start Rails locally:

   ```sh
   bin/rails server
   ```

3. Forward Stripe events to the local webhook endpoint:

   ```sh
   stripe listen --forward-to localhost:3000/webhooks/stripe
   ```

4. Copy the temporary CLI signing secret printed by `stripe listen` into `STRIPE_WEBHOOK_SECRET` for the Rails process you are testing. The CLI signing secret is different from the production Dashboard endpoint secret.
5. Trigger a harmless event:

   ```sh
   stripe trigger customer.subscription.updated
   ```

6. Confirm the request returns 2xx and a `BillingWebhookEvent` row is recorded with provider `stripe`, the external event ID, event type, livemode flag, and the expected status. A standalone CLI subscription event without a Boat Binder Customer association is safely ignored.

## Staging Checkout Validation

Use Stripe sandbox keys and test-mode Price IDs only.

1. Configure `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`,
   `STRIPE_SELF_MANAGED_MONTHLY_PRICE_ID`, and
   `STRIPE_SELF_MANAGED_ANNUAL_PRICE_ID` on staging.
2. Configure the staging endpoint as
   `https://staging.boat-binder.com/webhooks/stripe` for the three actively processed event types
   listed above. Keep the Stripe CLI signing secret separate from the Dashboard-managed staging
   endpoint secret.
3. Sign in as a fictional owner with one active `editor` membership and open
   `/billing/checkout`.
4. Choose monthly, confirm Stripe Checkout displays the configured monthly test Price, and complete
   Checkout with a Stripe test payment method.
5. Confirm the Checkout Subscription has a 7-day trial and a payment method for post-trial billing.
6. Confirm `checkout.session.completed` and `customer.subscription.created` return 2xx and create
   one receipt per Stripe event ID.
7. Confirm the correct local Subscription has provider `stripe`, plan `self_managed`, status
   `trialing`, matching Customer/Subscription identifiers, trial end, period end, and synchronization
   timestamp.
8. Refresh the success page and confirm it performs no billing mutation.
9. Repeat with annual and verify the annual test Price is used.
10. Cancel a fresh Checkout Session and confirm the local subscription remains unchanged.
11. Redeliver a processed event and confirm the receipt and local synchronization remain idempotent.
12. Attempt an unknown option, extra Price/Customer/Account parameters, a second eligible Account,
    and mismatched signed event metadata; confirm no cross-account mutation occurs.

Do not use production customer data or live-mode Stripe keys for these checks. This PR does not deploy
or configure staging.

## Production Stripe Setup

In Stripe Dashboard, create an HTTPS webhook endpoint for:

```text
https://app.boat-binder.com/webhooks/stripe
```

When this phase is intentionally deployed, select:

- `checkout.session.completed`
- `customer.subscription.created`
- `customer.subscription.updated`
- `customer.subscription.deleted`
- `invoice.paid`
- `invoice.payment_failed`
- `invoice.payment_succeeded`

The first three are actively processed. The remaining events are retained for safe deferred receipt.
Store the Dashboard endpoint signing secret in `STRIPE_WEBHOOK_SECRET`. Verify delivery from Stripe
Dashboard after deployment before considering production webhook setup complete. Test-mode and
live-mode deliveries are distinguished by the stored `livemode` flag.

Boat Binder recognizes both `invoice.paid` and `invoice.payment_succeeded` as deferred
successful-invoice events. They remain intentionally ignored until the later billing lifecycle phase.
Billing Portal, post-Checkout cancellation/reactivation, invoice synchronization, access enforcement,
public signup, entitlement enforcement, and production live-mode setup remain out of scope.
