# Boat Binder

**The digital home for boat ownership.**

Boat Binder is a mobile-first Rails SaaS MVP for vessel ownership records, maintenance history, reminders, documents, owner notes, and client-ready service reports. It is built for boat owners who need one reliable place for vessel details and for captains or service teams who need a clean operational view of what has happened, what needs attention, and what should be shared with an owner.

## Current Capabilities

- Owner, captain, and admin roles with scoped account access.
- Vessel records backed internally by the generic `Asset` model.
- Primary vessel photos, owner/account details, contacts, and account time zones.
- Binder documents with upload validation.
- Binder notes, reminders, and vessel status signals.
- Service visits with engine readings, inspection checks, battery checks, follow-up items, report previews, and summary emails.
- Mailgun SMTP-backed transactional email for password resets, account invitations, and service visit summaries.
- Stripe webhook receipt foundation and local subscription-domain records.

Boat Binder is still an MVP. Stripe Checkout, billing portal, subscription enforcement, public signup, AI-powered document search, and maintenance-insight features are roadmap items rather than implemented customer-facing features.

## Build Week Demo

- Live demo: [https://boat-binder.com](https://boat-binder.com)
- Demo access uses a fictional owner account with two vessels, service history, reminders, notes, and document records.
- Login credentials are provided privately with the Build Week submission.

The demo contains no real customer or vessel data.

## Tech Stack

- Ruby and Ruby on Rails 8.1
- PostgreSQL
- Hotwire/Turbo and Stimulus
- Tailwind CSS
- Active Storage
- Action Mailer with Mailgun SMTP
- Stripe Ruby SDK for verified webhook receipt
- Heroku deployment
- GitHub Actions CI
- Minitest and system tests
- RuboCop, Bundler Audit, Brakeman
- GitHub Advanced Security / CodeQL review

## Quick Local Setup

Prerequisites: Ruby matching `.ruby-version`, Bundler, PostgreSQL, and libvips.

```sh
git clone https://github.com/reneenordholm/boat-binder.git
cd boat-binder
bundle install
bin/rails db:prepare
bin/dev
```

`bin/dev` runs Rails and Tailwind watchers through `Procfile.dev`. The app defaults to port 3000 unless `PORT` is set. You can also run `bin/rails server`.

## Tests And Security Checks

```sh
bin/rails test
bin/rails test:system
bin/rubocop
bin/brakeman --no-pager
bin/bundler-audit
bin/importmap audit
```

The `bin/bundler-audit` wrapper updates the local ruby-advisory-db before scanning so local vulnerability checks match CI more closely.

## Built With OpenAI

Boat Binder was built with human product direction and review, with OpenAI tools used as collaborators throughout the process.

Codex worked directly with this Rails repository as an engineering collaborator. It inspected existing code, implemented scoped GitHub issues, generated and updated tests, refactored models/controllers/views/services, remediated security findings, investigated CI failures, updated documentation, and prepared pull-request branches.

GPT-5.6 was used meaningfully during product and engineering development, but Boat Binder does not currently include a customer-facing GPT-5.6 feature. It helped with product discovery, roadmap decisions, subscription and billing architecture, Stripe webhook security and idempotency design, threat-model discussions, CI and dependency-advisory analysis, manual QA planning, interpretation of Copilot findings, detailed implementation specifications for Codex, and Build Week demo/submission planning.

Concrete workflow examples:

- GPT-5.6 helped define the subscription-domain requirements, access policy, edge cases, and tests; Codex implemented the local subscription foundation.
- GPT-5.6 helped reason through Stripe webhook verification, idempotency, retry behavior, and sensitive-log filtering; Codex made the repository changes and tests.
- GPT-5.6 helped analyze CI failures and dependency advisories; Codex applied focused lockfile/security patches.
- GPT-5.6 helped shape the subscription plan catalog and Stripe-ready configuration boundaries; Codex implemented the catalog and coverage.
- GPT-5.6 helped define the Build Week demo-account setup, safety requirements, and QA plan; Codex built the repeatable seed workflow.

Human judgment remained responsible for product direction, architecture decisions, review, manual testing, deployment, and final approval.

Planned GPT-5.6 feature: a Vessel Ownership Brief that synthesizes reminders, service history, inspection findings, engine hours, and follow-up items into a concise owner summary. This is roadmap functionality, not part of the running application today.

## Detailed Documentation

- [Configuration](docs/configuration.md)
- [Deployment Architecture Review](docs/deployment-architecture.md)
- [Production Email](docs/email.md)
- [Stripe Foundation](docs/stripe.md)
