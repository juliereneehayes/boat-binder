# Configuration

Core local boot usually works without production credentials. The variables below enable optional production-like behavior.

## Application Host

- `APP_HOST` - host used in production email links, such as `app.boat-binder.com`.

## Rails Application Secrets

- `SECRET_KEY_BASE` - required in production and stored as a Heroku config var.

Production intentionally does not use `RAILS_MASTER_KEY`, and `config/credentials.yml.enc` is no
longer part of the production secret model. Do not restore the retired signing secret or master key
as fallbacks. If Rails encrypted credentials are introduced again, they must use a new, independent
master key and must not reuse retired production secrets.

## SMTP / Mailgun

- `SMTP_ADDRESS`
- `SMTP_PORT`
- `SMTP_DOMAIN`
- `SMTP_USERNAME`
- `SMTP_PASSWORD`
- `MAIL_FROM`

These are required before production transactional email can actually deliver.

## Stripe

- `STRIPE_SECRET_KEY` - secret API key for Stripe-dependent operations.
- `STRIPE_PUBLISHABLE_KEY` - publishable key reserved for future client-side billing flows.
- `STRIPE_WEBHOOK_SECRET` - signing secret for `/webhooks/stripe`.
- `STRIPE_SELF_MANAGED_MONTHLY_PRICE_ID` - Stripe Price ID for the Self Managed monthly option.
- `STRIPE_SELF_MANAGED_ANNUAL_PRICE_ID` - Stripe Price ID for the Self Managed annual option.

Production Stripe values are stored in Heroku environment/config vars. The initializer prefers those
environment values and retains its existing Rails-credentials fallback for environments that may use
encrypted credentials in the future. Do not commit real keys. The app can boot without Stripe secrets
for development/test workflows that do not invoke Stripe; webhook verification fails safely until
`STRIPE_WEBHOOK_SECRET` is configured.

## Build Week Demo

- `BUILD_WEEK_DEMO_EMAIL` - optional login email. Local default: `demo@boat-binder.com`.
- `BUILD_WEEK_DEMO_PASSWORD` - required in production. Development/test default: `boat-binder-build-week-demo`.

The demo runner never prints the password. Do not expose the production demo password in committed documentation.

## Active Storage Image Processing Security

Boat Binder uses the Rails 8.1 default Vips variant processor. `image_processing` supplies
`ruby-vips`, while the native libvips library is installed by the runtime rather than Bundler.

Rails and Active Storage 8.1.3.1 remediate
[GHSA-xr9x-r78c-5hrm](https://github.com/rails/rails/security/advisories/GHSA-xr9x-r78c-5hrm)
(`CVE-2026-66066`) by disabling untrusted libvips operations. The patched release requires
`ruby-vips` 2.2.1 or later and native libvips 8.13 or later.

Boat Binder's permitted image formats (JPEG, PNG, and WebP) remain supported. The release changes
variant processing and analysis for unfuzzed formats that Boat Binder does not accept; attachment
uploads, downloads, document storage, and the S3 service behavior are otherwise unchanged.

The production native version cannot be confirmed from this repository. Verify it after deployment:

```sh
heroku run 'bundle exec ruby -rvips -e "puts Vips.version_string"' --app boat-binder
```

After deploying and confirming the patched runtime, rotate application secrets accessible to the
production process as directed by the advisory. This includes Rails signing/encryption secrets and
credentials for the database, Active Storage, email, Stripe, and other connected services. Do not
retain potentially exposed values as fallbacks.
