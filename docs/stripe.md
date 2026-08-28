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

An option's `enabled` value controls whether it is available for a new Checkout. A known disabled
option remains valid for reconciliation of an already-issued Checkout Session or existing Stripe
subscription. Price mappings referenced by outstanding Stripe lifecycle events must therefore remain
configured and recognizable even after an option is no longer offered for new purchase. Unknown
option keys and Price IDs continue to fail closed.

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

`Billing::StripeCheckoutSessionCreator` creates or reuses a Stripe Customer and records only pending
correlation state in `BillingCheckoutAttempt`. A pending attempt contains the authorized Account,
stable option key, Stripe Customer and Checkout Session identifiers, an opaque idempotency key, and a
small lifecycle status. It does not contain payment data or raw Stripe payloads. Starting Checkout
does not mutate the Account's authoritative `Subscription`.

The database permits only one active (`creating`, `open`, `replacing`, or `submitted`) attempt per
Account. Every Checkout and webhook transition uses the same lock order: Account, then Subscription,
then Checkout attempt. Mutable records are requeried after those locks are acquired. Stripe Customer
and Checkout Session create/retrieve/expire calls happen outside database transactions; their results
are committed only after the same lock order is reacquired and authoritative state is checked again.
A per-attempt Stripe idempotency key protects Session creation retries.

A repeated request for the same option retrieves and reuses the open Session. A request for another
option first marks the old attempt `replacing`, keeping it inside the one-active-attempt constraint,
then expires the old Stripe Session before marking its attempt `replaced` and reserving a new one.
Stripe-reported expired Sessions are marked `expired` and no longer block a new attempt. Terminal
attempts cannot transition back to an active state. If a verified webhook wins a race, a stale
Checkout request observes the freshly locked `completed` attempt or Stripe-backed Subscription and
stops without creating or reviving a Session. Browser success and cancellation pages are display-only;
canceling the page leaves both the open attempt and the authoritative local Subscription unchanged,
so the same Session can still be resumed until Stripe expires it or a different option replaces it.

Checkout metadata contains purpose-specific signed Account and Checkout-attempt references plus the
stable Boat Binder option key. Webhook synchronization requires those signed references and also
cross-checks the Stripe Customer, Subscription, Session, Price, and local Account associations. The
signed references are additional correlation defenses, not replacements for identifier checks.

## Billing Portal First Slice

An authenticated active Owner with exactly one active Editor membership for an active client Account
can create a fresh Stripe Billing Portal session through `POST /billing/portal`. Boat Binder resolves
the Account and its verified Stripe Customer association server-side. It permits only verified Self
Managed `current_entitlement` and `payment_recovery_pending` lifecycle phases; Read-only members,
ambiguous Account relationships, unsupported phases, plans, providers, and unverified records fail
closed.

Set `STRIPE_BILLING_PORTAL_CONFIGURATION_ID` to an explicit configuration created for the current
Stripe environment. Staging uses a test-mode configuration with `STRIPE_LIVEMODE=false`; production
uses a separate live-mode configuration with `STRIPE_LIVEMODE=true`. The approved configuration
should enable payment-method and invoice recovery plus cancellation at period end and its supported
reversal. Keep plan switching, quantity changes, promotion codes, and trial behavior disabled.

Portal sessions are created only after the authorized POST. Ordinary rendering and authorization do
not call Stripe. Boat Binder sends its configured application root URL as the return destination and
validates the returned Customer, Portal configuration, livemode, return URL, and HTTPS
`billing.stripe.com` session destination before redirecting. It does not log or persist the short-lived
Portal URL.

Returning from Portal is informational. It does not mark an invoice paid, clear cancellation, alter
the local Subscription, restore entitlement, or create billing records. Authenticated canonical
webhooks remain authoritative.

### Staging Portal Validation

1. In the Stripe test environment, create and save a dedicated Portal configuration. Enable payment
   method updates, invoice history/payment recovery, and cancellation at period end. Keep plan and
   quantity changes and promotion codes disabled.
2. Configure staging with that test configuration ID, Stripe test credentials, and
   `STRIPE_LIVEMODE=false`. Do not reuse the production configuration.
3. Sign in as a fictional active Owner with one active Editor membership and a verified Self Managed
   subscription. Confirm **Manage billing** opens Stripe's hosted Portal.
4. Repeat for active, trialing, scheduled-cancellation, and `past_due` fixtures. Confirm Read-only,
   inactive, unsupported, and multi-Account users cannot create a session.
5. For payment recovery, verify whether the subscription has its own default payment method. A Portal
   update sets the Customer invoice default, which may not replace a subscription-level default.
6. Confirm the intended payment method is applied to the outstanding invoice and explicitly trigger
   or wait for the configured invoice payment/retry. A changed payment method or successful Portal
   return is not evidence that payment succeeded.
7. Confirm verified invoice/subscription webhooks synchronize the canonical Stripe status before
   Boat Binder restores write entitlement.
8. Schedule cancellation and confirm paid-through access remains current through the verified period
   end. Reverse it in Portal while Stripe supports reversal, then confirm the resulting canonical
   webhook clears the local scheduled-cancellation state.

These Stripe Dashboard and end-to-end recovery checks remain operator-run external validation; the
automated suite stubs Stripe and does not prove deployed Portal configuration or invoice behavior.

Verified events actively processed:

- `checkout.session.completed` verifies the pending attempt, then associates its Stripe Customer and
  Subscription identifiers with the authoritative local `Subscription`. It does not infer or grant
  `trialing` status.
- `customer.subscription.created`
- `customer.subscription.updated`
- `customer.subscription.deleted`
- `customer.subscription.paused`
- `customer.subscription.resumed`
- `invoice.paid`
- `invoice.payment_failed`

`invoice.payment_succeeded` remains intentionally acknowledged and ignored. Stripe can emit it
alongside `invoice.paid`; Boat Binder uses `invoice.paid` as its single successful-invoice and
renewal signal so two independent success paths cannot race or duplicate reconciliation. Unknown
events are also acknowledged and recorded as ignored.

The authoritative local `Subscription` changes only when a verified event passes all correlation and
identifier checks; no webhook delivery order is assumed. Subscription lifecycle handlers resolve the
signed historical Checkout attempt, then acquire an Account-scoped PostgreSQL session advisory lock.
While that advisory lock remains held, they validate the signed event under the Account ->
Subscription -> Checkout attempt row-lock order, release the row locks and transaction, retrieve the
current Subscription from Stripe, and reacquire the same row-lock order. The freshly locked local
state and canonical Stripe object are both revalidated before Stripe's current status, Price, and
timestamps are committed locally.

Invoice events use Stripe's current `invoice.parent.subscription_details` shape. Boat Binder requires
the subscription metadata snapshot's signed Account and Checkout-attempt references and stable option
key, then cross-checks the invoice Customer and Subscription against the historical attempt and the
already-associated local Stripe subscription. Canonical Subscription retrieval supplies the current
status and proves the configured Price and metadata again. A mismatched Customer, Subscription,
Account, option, Price, or signed reference fails closed without mutation. Invoice payloads are not
stored as an invoice ledger.

`invoice.paid` therefore updates the existing local Subscription for renewals rather than creating a
new record. `invoice.payment_failed` does not blindly set `past_due`; it retrieves the canonical
Subscription and records whatever legitimate Stripe lifecycle state currently applies. The same
canonical rule governs recovery from `past_due`, scheduled cancellation and reversal, terminal
deletion, actual paused subscriptions, and resume events. Paused payment collection is distinct from
an actual Stripe Subscription status of `paused`.

Canonical Stripe statuses map locally as follows:

| Stripe status | Local status |
| --- | --- |
| `trialing` | `trialing` |
| `active` | `active` |
| `past_due` | `past_due` |
| `canceled` | `canceled` |
| `incomplete` | `suspended` |
| `unpaid` | `suspended` |
| `paused` | `suspended` |
| `incomplete_expired` | `expired` |

An unsupported future canonical Stripe status is conservatively synchronized to local `suspended`
and emits a minimized `unsupported_subscription_status` operational warning. The receipt is processed
because Boat Binder deliberately reconciles to a non-entitled fallback rather than retaining a prior
access-eligible state. Terminal cancellation retains the local Subscription, Stripe identifiers,
Account, vessels, documents, and service history. Application access consequences remain deferred to
the subscription-enforcement phase.

Canonical retrieval alone is not sufficient when two distinct lifecycle workers can retrieve
different snapshots concurrently. The advisory lock serializes the complete retrieve-and-commit
sequence for one Account across Rails threads, processes, and dynos that share PostgreSQL. Its stable
64-bit key is derived from the versioned `boat_binder:stripe_account_reconciliation:v1` namespace and
the local Account ID; no Stripe or customer identifier is used. Different Accounts use different
keys and reconcile independently. The lock is session-level rather than transaction-level, so Boat
Binder retains one checked-out database connection while waiting on Stripe but does not hold an open
database transaction or row lock during that network request.

Lock acquisition uses bounded `pg_try_advisory_lock` polling with a five-second timeout. A timeout,
Stripe API failure, or unexpected commit failure releases the advisory lock in `ensure`, leaves the
webhook receipt failed and retryable, and returns a non-2xx response. Same-execution-context nested
calls reuse the outer lock scope so advisory acquisitions and releases remain balanced.

Stripe does not guarantee webhook delivery order, `Event.created` has second-level resolution, and
Stripe does not document Event IDs as chronological ordering keys. Boat Binder therefore does not
infer lifecycle chronology from event timestamps or Event ID ordering. Every distinct verified
subscription lifecycle event reconciles from Stripe's current Subscription state; duplicate event IDs
remain idempotent through `BillingWebhookEvent`. A Stripe API failure remains a failed, retryable
receipt and does not become a successfully ignored association error. No normal application request
uses this retrieval path or queries Stripe to determine access.

This follows Stripe's guidance to [retrieve current objects when webhook ordering
matters](https://docs.stripe.com/webhooks#event-ordering), the documented integer Unix timestamp for
[`Event.created`](https://docs.stripe.com/api/events/object#event_object-created), and the official
[`Subscription.retrieve`](https://docs.stripe.com/api/subscriptions/retrieve) API. Canonical retrieval
runs before the webhook receipt transaction; the Account advisory lock remains held while receipt
serialization and the final Account -> Subscription -> Checkout attempt lock/revalidation happen
afterward.

`STRIPE_LIVEMODE` explicitly separates environments: configure `false` for development/staging test
keys and `true` for production live keys. A mode-mismatched event is acknowledged as an ignored
association failure before lifecycle retrieval or mutation. Missing or invalid mode configuration is
a technical failure, not a business-association failure.

Receipts marked processed or ignored are idempotently acknowledged on redelivery. A Stripe API,
database, advisory-lock, or unexpected internal failure marks the receipt failed, returns non-2xx,
and remains retryable. An invalid business association is safely recorded as ignored with a minimized
diagnostic code. Logs contain event ID, event type, livemode, and result only; Boat Binder does not
persist raw webhook bodies or log payment payloads.

Receipts completed as ignored before an event type became active are not replayed automatically.
Fresh lifecycle events reconcile current canonical state; operators should validate Phase 5 with new
test-mode events rather than attempting to reuse an already-completed Event ID.

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

1. Configure `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_LIVEMODE=false`,
   `STRIPE_SELF_MANAGED_MONTHLY_PRICE_ID`, and
   `STRIPE_SELF_MANAGED_ANNUAL_PRICE_ID` on staging.
2. Configure the staging endpoint as
   `https://staging.boat-binder.com/webhooks/stripe` for all actively processed event types listed
   above. Keep the Stripe CLI signing secret separate from the Dashboard-managed staging endpoint
   secret.
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
10. Cancel a fresh Checkout page and confirm the local subscription remains unchanged. Retry the same
    option and confirm Boat Binder reuses the open Session rather than creating a second one.
11. Choose the other billing option and confirm the previous open Session is expired before the new
    Session is created.
12. Redeliver a processed event and confirm the receipt and local synchronization remain idempotent.
13. Deliver lifecycle events out of order and confirm each reconciliation converges on the current
    Stripe Subscription state without reverting the local Subscription.
14. Attempt an unknown option, extra Price/Customer/Account parameters, a second eligible Account,
    and mismatched signed event metadata; confirm no cross-account mutation occurs.
15. Exercise renewal, payment failure/recovery, scheduled cancellation/reversal, final cancellation,
    and pause/resume in Stripe test mode. Confirm each event converges on Stripe's current Subscription
    state and preserves one local Subscription record.
16. Send or redeliver a live-mode fixture only through an isolated test harness and confirm staging
    records it as ignored without retrieval or mutation. Never use live customer data for this check.

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
- `customer.subscription.paused`
- `customer.subscription.resumed`
- `invoice.paid`
- `invoice.payment_failed`
- `invoice.payment_succeeded`

All listed events except `invoice.payment_succeeded` are actively processed.
`invoice.payment_succeeded` is retained as an intentionally ignored duplicate success signal. Store
the Dashboard endpoint signing secret in `STRIPE_WEBHOOK_SECRET`, configure `STRIPE_LIVEMODE=true`,
and use live Price IDs only in production. Verify delivery from Stripe Dashboard after deployment
before considering production webhook setup complete. Staging uses its own endpoint secret, test
keys and Prices, and `STRIPE_LIVEMODE=false`; the two environments must not share Stripe configuration.

Broader Billing Portal features, terminal-subscription replacement, full Account Billing UI,
invoice-history storage/UI, customer payment-failure emails, and public signup remain out of scope.
