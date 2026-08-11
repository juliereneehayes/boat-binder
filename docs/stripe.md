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
Catalog loading and lookup read local configuration only and never call Stripe. Checkout, trial
application, customer and subscription creation, billing portal access, lifecycle synchronization,
access enforcement, and entitlement enforcement remain deferred.

Webhook endpoint:

```text
POST https://app.boat-binder.com/webhooks/stripe
```

The endpoint verifies the raw request body with `Stripe::Webhook.construct_event`, stores event metadata in `billing_webhook_events`, and uses a unique `[provider, external_event_id]` index for idempotency. Full raw payloads, API keys, and signing secrets are not stored.

Current Stripe behavior intentionally records and ignores verified subscription and invoice events. Subscription lifecycle synchronization, Checkout, billing portal, Stripe Customer creation, access enforcement, invoice sync, and billing UI are deferred.

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

6. Confirm the request returns 2xx and a `BillingWebhookEvent` row is recorded with provider `stripe`, the external event ID, event type, livemode flag, and status `ignored`.

## Production Stripe Setup

In Stripe Dashboard, create an HTTPS webhook endpoint for:

```text
https://app.boat-binder.com/webhooks/stripe
```

Select the initial events this phase is ready to receive and ignore safely:

- `checkout.session.completed`
- `customer.subscription.created`
- `customer.subscription.updated`
- `customer.subscription.deleted`
- `invoice.paid`
- `invoice.payment_failed`
- `invoice.payment_succeeded`

Store the Dashboard endpoint signing secret in `STRIPE_WEBHOOK_SECRET`. Verify delivery from Stripe Dashboard after deployment before considering production webhook setup complete. Test-mode and live-mode deliveries are distinguished by the stored `livemode` flag.

Boat Binder recognizes both `invoice.paid` and `invoice.payment_succeeded` as deferred successful-invoice events in this phase. They are recorded and intentionally ignored until subscription lifecycle synchronization is implemented.
