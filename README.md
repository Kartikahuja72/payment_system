# Payment System

A production-grade payment processing backend built with **Ruby on Rails 8**, **Apache Kafka**, **MySQL 8**, and **Redis 7**. Supports Razorpay and Stripe as payment gateways with full event-driven architecture, saga pattern, reconciliation engine, ledger accounting, and email notifications.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Tech Stack](#tech-stack)
- [Features](#features)
- [Payment Flow](#payment-flow)
- [Saga Pattern](#saga-pattern)
- [Database Schema](#database-schema)
- [Kafka Topics](#kafka-topics)
- [API Endpoints](#api-endpoints)
- [Project Structure](#project-structure)
- [Prerequisites](#prerequisites)
- [Local Setup](#local-setup)
- [Environment Variables](#environment-variables)
- [Running the System](#running-the-system)
- [Testing](#testing)
- [Webhook Setup](#webhook-setup)
- [Key Design Patterns](#key-design-patterns)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                          Rails API                              │
│                                                                 │
│  POST /payments ──► CreatePaymentService ──► OutboxEvent        │
│  POST /webhooks/razorpay ──► WebhooksController                 │
│  POST /webhooks/stripe   ──► WebhooksController                 │
└──────────────┬──────────────────────────────────────────────────┘
               │
               ▼
┌──────────────────────────┐
│  Resque + Resque         │   OutboxWorkerJob polls outbox_events
│  Scheduler               │   every 5 seconds and publishes to
│  (Redis-backed)          │   Kafka via WaterDrop producer
└──────────────┬───────────┘
               │
               ▼
┌──────────────────────────────────────────────────────────────────┐
│                         Apache Kafka                             │
│                                                                  │
│  payment.created → payment.processing → payment.authorized       │
│  payment.captured → invoice.create → notification.send           │
│  payment.failed  → inventory.release (compensating tx)           │
│  payment.refund  → ledger.entry.created + notification.send      │
│  reconciliation.required → reconciliation engine                 │
│  deadletter.payment → DeadLetterConsumer                         │
└──────────────┬───────────────────────────────────────────────────┘
               │
               ▼
┌──────────────────────────┐
│  Karafka Consumers       │   One consumer per topic,
│  (multi-threaded,        │   idempotent via processed_events
│   6 partitions each)     │   state machine via state_machines gem
└──────────────────────────┘
```

**Key design decisions:**

- **Outbox Pattern** — payment.created and inventory.reserve are written to `outbox_events` in the same DB transaction as the payment row. The outbox worker publishes them to Kafka asynchronously. This guarantees no message is lost even if Kafka is down at write time.
- **Idempotency** — every consumer checks `processed_events` before acting. Duplicate Kafka messages are silently dropped.
- **Optimistic Locking** — `lock_version` on payments prevents concurrent state-machine transitions from corrupting data.
- **Saga Pattern (choreography)** — `saga_transactions` tracks the multi-step payment flow. Each consumer advances the saga when it completes its step.
- **Dead Letter Queue** — after 5 retries, failed messages are routed to `deadletter.payment` and persisted to `dead_letter_events` for investigation.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Framework | Ruby on Rails 8.0 (API-only) |
| Database | MySQL 8 |
| Cache / Queue backend | Redis 7 |
| Message broker | Apache Kafka (KRaft mode, no Zookeeper) |
| Kafka consumer framework | Karafka 2.4 |
| Kafka producer | WaterDrop (bundled with Karafka) |
| Background jobs | Resque + Resque Scheduler |
| Payment gateways | Razorpay 3.x, Stripe 12.x |
| State machine | state_machines-activerecord |
| Serialization | ActiveModelSerializers |
| Email | ActionMailer + SMTP (Gmail) |
| Environment variables | dotenv-rails |

---

## Features

### Phase 1 — Core Payment API
- Create payment with idempotency key
- Trace ID middleware (every request gets a unique `X-Trace-Id`)
- Idempotency middleware (same key = same response, no double charge)
- Payment state machine: `created → processing → authorized → captured → refunded / failed`
- Optimistic locking on all state transitions

### Phase 2 — Kafka Event Pipeline
- Outbox pattern for atomic message publishing
- Resque scheduler polls outbox every 5 seconds
- Each payment state change publishes a Kafka event
- Karafka consumers process events and advance the state machine

### Phase 3 — Webhook Ingestion
- Razorpay webhook endpoint with HMAC-SHA256 signature validation
- Stripe webhook endpoint with Stripe-Signature header validation
- `gateway_webhook_logs` — raw webhook payload stored before processing
- `processed_webhooks` — idempotency guard (same event_id never processed twice)
- `processed_refunds` — idempotency guard for refund events specifically

### Phase 4 — Gateway Abstraction
- `PaymentGateway` base class with uniform interface
- `RazorpayGateway` — authorize, capture, refund
- `StripeGateway` — authorize, capture, refund
- `GatewayResponse` — normalised response object (success?, gateway_payment_id, error)
- `GatewayErrorClassifierService` — classifies errors as retryable vs permanent
- `GatewayRetryEngineService` — exponential backoff with max retries

### Phase 5 — Ledger and Accounting
- Double-entry bookkeeping: every payment creates a debit + credit pair
- Entry types: `authorization`, `capture`, `refund`
- Account types: `customer_wallet`, `platform_revenue`, `platform_holding`
- `LedgerEntry.balanced_for?(payment_id)` — verifies debit total == credit total
- Immutable ledger (no updates, no deletes)

### Phase 6 — Reconciliation Engine
- `RazorpayReconciliationService` — fetches Razorpay settlement report
- `StripeReconciliationService` — fetches Stripe balance transactions
- `ReconciliationMismatchDetectorService` — detects 4 mismatch types:
  - `amount_mismatch` — our amount does not match gateway amount
  - `status_mismatch` — our status does not match gateway status
  - `missing_locally` — gateway has payment we do not
  - `missing_at_gateway` — we have payment gateway does not
- `ReconciliationMismatch.resolve!` — marks mismatch resolved with notes
- `DailyReconciliationJob` — runs every day via Resque Scheduler
- `PendingVerificationCheckerJob` — catches payments stuck in `processing` for more than 30 minutes

### Phase 7 — Dead Letter Queue
- `deadletter.payment` Kafka topic — no DLQ on the DLQ itself (would loop forever)
- `DeadLetterConsumer` — persists failed messages to `dead_letter_events`
- All other topics: `max_retries: 5` before routing to DLQ

### Phase 8 — Saga Pattern + Notifications + Invoices
- `SagaTransaction` model tracks the full payment lifecycle per payment
- Choreography-based saga (no central orchestrator): each consumer updates saga state
- Compensating transactions: `PaymentFailedConsumer` publishes `inventory.release` to roll back reservation
- `InvoiceGeneratorService` — idempotent invoice creation (INV-YYYYMMDD-XXXXXXXX format)
- `PaymentMailer` — 4 email types:
  - Payment confirmed (on capture)
  - Payment failed (on failure)
  - Refund processed (on refund)
  - Invoice generated (on invoice creation)
- Real SMTP via Gmail app password — credentials in `.env` only

---

## Payment Flow

```
1. POST /payments
   └─► CreatePaymentService
       ├─ Payment.create! (status: created)
       ├─ SagaTransaction.create! (step: inventory_reserve)
       ├─ OutboxEvent: payment.created        ─┐ same DB transaction
       └─ OutboxEvent: inventory.reserve      ─┘

2. OutboxWorkerJob (every 5s via Resque Scheduler)
   └─► Publishes outbox_events → Kafka

3. InventoryReserveConsumer (inventory.reserve)
   └─► Simulates inventory check → advance saga to payment_processing

4. PaymentCreatedConsumer (payment.created)
   └─► Calls gateway.authorize → publishes payment.processing

5. PaymentProcessingConsumer (payment.processing)
   └─► Updates payment.gateway_payment_id → publishes payment.authorized

6. PaymentAuthorizedConsumer (payment.authorized)
   ├─► advance saga to payment_authorized
   └─► publishes ledger.entry.created (authorization)

7. POST /webhooks/razorpay OR /webhooks/stripe
   └─► WebhookReceivedConsumer (payment.webhook.received)
       └─► On payment.captured:
           ├─ payment.capture! (state machine)
           ├─ advance saga to payment_captured
           ├─ publishes ledger.entry.created (capture)
           ├─ publishes notification.send (payment_captured)
           └─ publishes invoice.create

8. InvoiceConsumer (invoice.create)
   ├─► InvoiceGeneratorService → Invoice.create!
   ├─► advance saga to invoice_creation
   ├─► sends invoice email
   └─► saga.complete!

9. NotificationConsumer (notification.send)
   └─► PaymentMailer.payment_captured_email → deliver_now

10. LedgerEntryConsumer (ledger.entry.created)
    └─► LedgerEntryService.create_pair (debit + credit)
```

**On failure:**
```
PaymentFailedConsumer
├─ payment.fail! (state machine)
├─ saga.start_compensation!
├─ publishes inventory.release (compensating transaction)
├─ saga.fail!
└─ publishes notification.send (payment_failed)
```

---

## Saga Pattern

Each payment has one `SagaTransaction` row. Steps in order:

```
inventory_reserve
  → payment_processing
    → payment_authorized
      → payment_captured
        → invoice_creation
          → completed
```

Statuses:
- `running` — saga is in progress
- `compensating` — a failure was detected, rolling back
- `failed` — compensation complete, saga is dead
- `completed` — all steps finished successfully

The `steps_completed` JSON array grows as each step finishes. You can always see exactly where a saga stopped if something goes wrong.

---

## Database Schema

| Table | Purpose |
|---|---|
| `payments` | Core payment record with state machine |
| `payment_events` | Immutable audit log of every state transition |
| `outbox_events` | Transactional outbox — pending Kafka messages |
| `processed_events` | Idempotency guard for Kafka consumers |
| `gateway_webhook_logs` | Raw webhook payload archive |
| `processed_webhooks` | Idempotency guard for webhooks |
| `processed_refunds` | Idempotency guard for refund webhooks |
| `ledger_entries` | Double-entry bookkeeping (immutable) |
| `reconciliation_reports` | Daily gateway settlement snapshots |
| `reconciliation_mismatches` | Detected discrepancies between us and gateway |
| `saga_transactions` | Tracks multi-step saga state per payment |
| `invoices` | Generated invoices (one per payment) |
| `dead_letter_events` | Failed Kafka messages after max retries |

---

## Kafka Topics

All topics: **6 partitions**, **replication factor 1** (local dev), messages keyed by `payment_id` for ordering guarantee per payment.

| Topic | Consumer | Purpose |
|---|---|---|
| `payment.created` | PaymentCreatedConsumer | Triggers gateway authorize call |
| `payment.processing` | PaymentProcessingConsumer | Stores gateway_payment_id |
| `payment.authorized` | PaymentAuthorizedConsumer | Records authorization in ledger, advances saga |
| `payment.failed` | PaymentFailedConsumer | Fails payment, triggers compensation |
| `payment.refund` | PaymentRefundConsumer | Transitions payment to refunded, sends email |
| `payment.webhook.received` | WebhookReceivedConsumer | Routes Razorpay/Stripe webhooks |
| `ledger.entry.created` | LedgerEntryConsumer | Creates double-entry ledger pair |
| `notification.send` | NotificationConsumer | Sends transactional emails |
| `reconciliation.required` | ReconciliationConsumer | Runs reconciliation for a gateway+date |
| `inventory.reserve` | InventoryReserveConsumer | Saga step 1 — reserve inventory |
| `invoice.create` | InvoiceConsumer | Generates invoice, sends invoice email, completes saga |
| `deadletter.payment` | DeadLetterConsumer | Persists failed messages (no DLQ on this topic) |

---

## API Endpoints

### Create Payment

```
POST /payments
Content-Type: application/json
Idempotency-Key: <unique-key>

{
  "order_id": "ORD-001",
  "amount": 50000,
  "currency": "INR",
  "gateway": "razorpay",
  "payment_method": "card",
  "email": "customer@example.com"
}
```

Response:
```json
{
  "id": 1,
  "order_id": "ORD-001",
  "amount": 50000,
  "currency": "INR",
  "status": "created",
  "gateway": "razorpay",
  "email": "customer@example.com",
  "trace_id": "abc-123"
}
```

> Amount is in the smallest currency unit (paise for INR, cents for USD). 50000 = INR 500.

### Get Payment

```
GET /payments/:id
```

### Refund Payment

```
POST /payments/:id/refund
```

### Webhooks

```
POST /webhooks/razorpay   — Razorpay webhook (HMAC-SHA256 validated)
POST /webhooks/stripe     — Stripe webhook (Stripe-Signature validated)
```

### Health Check

```
GET /up
```

---

## Project Structure

```
payment_system/
├── app/
│   ├── consumers/                    # Karafka consumers (one per Kafka topic)
│   │   ├── application_consumer.rb       # Base: idempotency + mark_as_consumed!
│   │   ├── payment_created_consumer.rb
│   │   ├── payment_processing_consumer.rb
│   │   ├── payment_authorized_consumer.rb
│   │   ├── payment_failed_consumer.rb
│   │   ├── payment_refund_consumer.rb
│   │   ├── webhook_received_consumer.rb
│   │   ├── ledger_entry_consumer.rb
│   │   ├── notification_consumer.rb
│   │   ├── reconciliation_consumer.rb
│   │   ├── inventory_reserve_consumer.rb
│   │   ├── invoice_consumer.rb
│   │   └── dead_letter_consumer.rb
│   ├── controllers/
│   │   ├── payments_controller.rb
│   │   └── webhooks_controller.rb
│   ├── gateways/                     # Payment gateway adapters
│   │   ├── payment_gateway.rb            # Abstract base class
│   │   ├── razorpay_gateway.rb
│   │   ├── stripe_gateway.rb
│   │   └── gateway_response.rb
│   ├── jobs/                         # Resque background jobs
│   │   ├── outbox_worker_job.rb          # Polls outbox → publishes to Kafka
│   │   ├── daily_reconciliation_job.rb
│   │   ├── pending_verification_checker_job.rb
│   │   └── retry_payment_processing_job.rb
│   ├── mailers/
│   │   ├── application_mailer.rb
│   │   └── payment_mailer.rb         # captured / failed / refund / invoice emails
│   ├── middleware/
│   │   ├── idempotency_middleware.rb     # Blocks duplicate requests
│   │   └── trace_id_middleware.rb        # Injects X-Trace-Id on every request
│   ├── models/
│   │   ├── payment.rb                    # State machine + optimistic lock
│   │   ├── saga_transaction.rb           # Saga state tracker
│   │   ├── invoice.rb
│   │   ├── ledger_entry.rb
│   │   ├── outbox_event.rb
│   │   ├── reconciliation_report.rb
│   │   ├── reconciliation_mismatch.rb
│   │   └── dead_letter_event.rb
│   ├── modules/
│   │   ├── ledger_balance.rb             # Balance query helpers
│   │   ├── payment_lock.rb               # Redis distributed lock
│   │   └── with_optimistic_retry.rb      # Retry on StaleObjectError
│   ├── producers/
│   │   └── kafka_producer.rb             # WaterDrop wrapper
│   ├── serializers/                  # ActiveModelSerializers
│   ├── services/
│   │   ├── create_payment_service.rb
│   │   ├── invoice_generator_service.rb
│   │   ├── ledger_entry_service.rb
│   │   ├── process_refund_service.rb
│   │   ├── razorpay_reconciliation_service.rb
│   │   ├── stripe_reconciliation_service.rb
│   │   ├── reconciliation_mismatch_detector_service.rb
│   │   ├── gateway_error_classifier_service.rb
│   │   └── gateway_retry_engine_service.rb
│   ├── validators/
│   │   ├── razorpay_webhook_validator.rb   # HMAC-SHA256 signature check
│   │   └── stripe_webhook_validator.rb     # Stripe-Signature check
│   └── views/payment_mailer/         # Email HTML templates
├── config/
│   ├── routes.rb
│   ├── resque_schedule.yml           # Recurring job schedule
│   └── environments/development.rb   # SMTP config
├── db/
│   ├── schema.rb
│   └── migrate/                      # 12 migrations
├── karafka.rb                        # All Kafka topic → consumer mappings
├── scripts/
│   ├── test_razorpay_webhook.rb      # Integration test for Razorpay flow
│   ├── test_stripe_webhook.rb        # Integration test for Stripe flow
│   └── test_reconciliation.rb        # Integration test for reconciliation engine
└── .env.example                      # Copy to .env and fill in credentials
```

---

## Prerequisites

Make sure the following are installed on your machine before setup:

- **Ruby 3.3+** (check `.ruby-version` for exact version)
- **MySQL 8**
- **Redis 7**
- **Docker** (for running Kafka locally)
- **Bundler** (`gem install bundler`)

---

## Local Setup

### Step 1 — Clone the repository

```bash
git clone git@github.com:Kartikahuja72/payment_system.git
cd payment_system
```

### Step 2 — Install Ruby dependencies

```bash
bundle install
```

### Step 3 — Set up environment variables

```bash
cp .env.example .env
```

Open `.env` and fill in all values. See the [Environment Variables](#environment-variables) section for what each one means.

### Step 4 — Create and migrate the database

Make sure MySQL is running, then:

```bash
bundle exec rails db:create
bundle exec rails db:migrate
```

This creates two databases:
- `payment_system_development`
- `payment_system_test`

### Step 5 — Start Redis

```bash
redis-server
```

Or if using a system service:

```bash
sudo systemctl start redis
```

### Step 6 — Start Kafka (Docker, KRaft mode — no Zookeeper required)

```bash
docker run -d \
  --name kafka \
  -p 9092:9092 \
  -e KAFKA_NODE_ID=1 \
  -e KAFKA_PROCESS_ROLES=broker,controller \
  -e KAFKA_LISTENERS=PLAINTEXT://:9092,CONTROLLER://:9093 \
  -e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://localhost:9092 \
  -e KAFKA_CONTROLLER_QUORUM_VOTERS=1@localhost:9093 \
  -e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER \
  -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT \
  -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 \
  -e KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1 \
  -e KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 \
  -e KAFKA_AUTO_CREATE_TOPICS_ENABLE=true \
  apache/kafka:latest
```

Wait 10 seconds for Kafka to fully boot, then create all topics:

```bash
sleep 10
bundle exec karafka topics migrate
```

Verify topics were created with 6 partitions each:

```bash
bundle exec karafka topics list
```

Alternatively, verify directly with Kafka CLI:

```bash
docker exec kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --list
```

### Step 7 — Gmail App Password (for email notifications)

Email notifications use real SMTP (not a mock). To set this up:

1. Go to your Google Account → Security → 2-Step Verification → App passwords
2. Create a new App Password for "Mail"
3. Copy the 16-character password into `.env` as `SMTP_PASSWORD`

> 2-Step Verification must be enabled on your Google account for App Passwords to work.

---

## Environment Variables

Copy `.env.example` to `.env` and fill in all values. The `.env` file is in `.gitignore` — it is never committed.

```env
# Razorpay credentials — get from https://dashboard.razorpay.com/app/keys
RAZORPAY_KEY_ID=rzp_test_your_key_id_here
RAZORPAY_KEY_SECRET=your_razorpay_secret_here
RAZORPAY_WEBHOOK_SECRET=your_razorpay_webhook_secret_here

# Stripe credentials — get from https://dashboard.stripe.com/apikeys
STRIPE_SECRET_KEY=sk_test_your_stripe_secret_here
STRIPE_WEBHOOK_SECRET=whsec_your_stripe_webhook_secret_here

# Kafka broker address (default for local Docker)
KAFKA_BROKERS=localhost:9092

# Redis URL (default for local Redis)
REDIS_URL=redis://localhost:6379/0

# Email — the From address on all outgoing emails
MAILER_FROM=noreply@yourcompany.com

# SMTP settings — Gmail example (use an App Password, not your account password)
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_DOMAIN=gmail.com
SMTP_USERNAME=your_email@gmail.com
SMTP_PASSWORD=your_16_char_app_password
```

---

## Running the System

You need **4 terminal windows** open simultaneously for the full system to work.

### Terminal 1 — Rails API server

```bash
bundle exec rails server
```

API available at `http://localhost:3000`.

### Terminal 2 — Resque worker (outbox → Kafka)

```bash
QUEUE=outbox bundle exec rake resque:work
```

Processes `OutboxWorkerJob` — picks up pending `outbox_events` rows and publishes them to Kafka using WaterDrop.

### Terminal 3 — Resque Scheduler

```bash
bundle exec rake resque:scheduler
```

Enqueues the outbox worker every 5 seconds. Also triggers `DailyReconciliationJob` and `PendingVerificationCheckerJob` on their configured schedules (see `config/resque_schedule.yml`).

### Terminal 4 — Karafka consumer server

```bash
bundle exec karafka server
```

Starts all 12 Kafka consumers. Karafka runs with `concurrency: 5` threads and processes messages from all 12 topics concurrently.

---

## Testing

### Razorpay end-to-end flow

Simulates the full Razorpay lifecycle without needing a public URL or tunnel.

```bash
ruby scripts/test_razorpay_webhook.rb
```

What this script does:
1. Creates a payment via `POST /payments`
2. Sends a `payment.authorized` webhook to `/webhooks/razorpay`
3. Sends a `payment.captured` webhook to `/webhooks/razorpay`
4. Sends a `refund.created` webhook to `/webhooks/razorpay`
5. Checks payment status at each step

### Stripe end-to-end flow

```bash
ruby scripts/test_stripe_webhook.rb
```

What this script does:
1. Creates a payment via `POST /payments` (gateway: stripe)
2. Sends a `payment_intent.succeeded` webhook to `/webhooks/stripe`
3. Sends a `charge.refunded` webhook to `/webhooks/stripe`
4. Checks payment status at each step

### Reconciliation engine

```bash
bundle exec rails runner scripts/test_reconciliation.rb
```

What this script does:
1. Tests `PendingVerificationCheckerJob` — finds payments stuck in processing > 30 minutes
2. Tests `ReconciliationMismatchDetectorService` — detects all 4 mismatch types
3. Tests `ReconciliationMismatch.resolve!` — marks mismatches as resolved
4. Tests `ReconciliationReport` idempotency — same gateway+date never fetched twice
5. Tests `ReconciliationConsumer` — inline simulation of Kafka event handling

---

## Webhook Setup

### Razorpay

**Development (no public URL needed):**

The test script (`scripts/test_razorpay_webhook.rb`) sends webhooks directly to `localhost:3000`. No tunnel required.

**Production:**

1. Go to Razorpay Dashboard → Settings → Webhooks
2. Add URL: `https://yourdomain.com/webhooks/razorpay`
3. Select events: `payment.authorized`, `payment.captured`, `refund.created`
4. Copy the webhook secret and set it as `RAZORPAY_WEBHOOK_SECRET` in `.env`

### Stripe

**Development (using Stripe CLI — no public URL needed):**

The Stripe CLI forwards Stripe events directly to your local server.

Option 1 — install Stripe CLI natively:

```bash
# Ubuntu/Debian
sudo dpkg -i stripe-cli.deb

stripe login
stripe listen --forward-to localhost:3000/webhooks/stripe
```

Option 2 — run via Docker:

```bash
docker pull stripe/stripe-cli

docker run --rm -it stripe/stripe-cli login

docker run --rm -it --network host stripe/stripe-cli listen \
  --forward-to localhost:3000/webhooks/stripe
```

The CLI prints a webhook signing secret (`whsec_...`) when it starts. Set this as `STRIPE_WEBHOOK_SECRET` in `.env`.

Then run the Stripe test:

```bash
ruby scripts/test_stripe_webhook.rb
```

**Production:**

1. Go to Stripe Dashboard → Developers → Webhooks
2. Add endpoint: `https://yourdomain.com/webhooks/stripe`
3. Select events: `payment_intent.succeeded`, `payment_intent.payment_failed`, `charge.refunded`
4. Copy the signing secret and set it as `STRIPE_WEBHOOK_SECRET` in `.env`

---

## Key Design Patterns

### Outbox Pattern
Prevents the dual-write problem. Payment creation and Kafka publish happen atomically — both write to MySQL in the same transaction. If Kafka is temporarily down, `outbox_events` accumulates and the outbox worker catches up when Kafka recovers. No payment is ever silently dropped.

### Idempotent Consumers
Every Kafka consumer inherits from `ApplicationConsumer` which:
1. Checks `processed_events` before calling `process(payload)` — skips if already seen
2. Calls `mark_as_consumed!` (Karafka offset commit) after processing
3. Writes to `processed_events` to prevent future replay

Any Kafka message can be delivered multiple times safely with no side effects.

### Saga Pattern (Choreography)
No central orchestrator. Each consumer knows its step and updates `SagaTransaction` when done. The saga tracks `steps_completed` (JSON array) and `current_step` so you can look at one database row and know exactly where any payment's journey stopped.

### Compensating Transactions
When `PaymentFailedConsumer` runs, it publishes `inventory.release` to roll back the inventory reservation. This is a fire-and-forget event for the inventory microservice. The saga transitions to `compensating` then `failed` status, recording the failure reason in `metadata`.

### Double-Entry Ledger
Every money movement creates two `ledger_entries` (debit + credit) in the same transaction. `LedgerEntry.balanced_for?(payment_id)` verifies total debits equal total credits for any payment — a financial integrity check that can be run at any time.

### Idempotency Keys
`POST /payments` requires an `Idempotency-Key` header. The middleware intercepts duplicate requests and returns the original response without re-processing. This prevents double charges when clients retry on network failure.

### Optimistic Locking
The `payments` table has a `lock_version` column. Any concurrent state-machine transition (e.g. two consumers both trying to capture the same payment) will raise `ActiveRecord::StaleObjectError` on the second writer. The `WithOptimisticRetry` module handles retrying these safely.

---

## Concurrency and Locking

Three distinct locking mechanisms are used depending on the threat model.

### 1. Optimistic Locking — `lock_version` column

**Where:** Every state-machine transition on `Payment` (authorize, capture, fail, refund, etc.)

**How it works:** Rails automatically adds `lock_version` to every `UPDATE`:

```sql
-- What you write in Ruby:
payment.capture!

-- What Rails actually runs:
UPDATE payments
SET status = 'captured', lock_version = lock_version + 1
WHERE id = 6 AND lock_version = 3   ← only succeeds if nobody else updated first
```

If two workers both read `lock_version = 3` and both try to write, only one succeeds. The second gets `0 rows affected` and Rails raises `ActiveRecord::StaleObjectError`.

**Recovery:** `WithOptimisticRetry` (`app/modules/with_optimistic_retry.rb`) catches the error, re-reads the fresh record, and retries up to 3 times:

```ruby
module WithOptimisticRetry
  MAX_RETRIES = 3

  def with_lock_retry
    retries = 0
    begin
      yield
    rescue ActiveRecord::StaleObjectError
      retries += 1
      retry if retries < MAX_RETRIES
      raise
    end
  end
end
```

**The problem it solves:** Two Kafka consumers (e.g. a webhook consumer and a retry worker) reading the same payment simultaneously. Without `lock_version`, whoever writes last silently wins — a payment could end up `failed` even though the gateway said success.

**lock_version progression for a normal payment:**
```
Payment.create!           → lock_version: 0
payment.start_processing! → lock_version: 1
payment.authorize!        → lock_version: 2
payment.update!(          → lock_version: 3  (gateway_payment_id set)
  gateway_payment_id: ...
)
payment.capture!          → lock_version: 4
payment.refund!           → lock_version: 5
```

---

### 2. Pessimistic Locking — `SELECT FOR UPDATE`

**Where:** `ProcessRefundService` (`app/services/process_refund_service.rb`)

**How it works:** Before checking whether a payment is refundable, the service acquires a row-level exclusive lock at the database level:

```ruby
@payment = Payment.lock("FOR UPDATE").find(@payment.id)
```

This translates to:
```sql
SELECT * FROM payments WHERE id = ? FOR UPDATE
```

MySQL locks the row for the duration of the current transaction. Any other connection attempting `FOR UPDATE` on the same row is blocked at the DB level until the first transaction commits or rolls back.

**The problem it solves:** Two simultaneous refund requests (different idempotency keys) for the same captured payment:

```
Without FOR UPDATE:
  Request A: payment.captured? → true  (no lock, reads freely)
  Request B: payment.captured? → true  (no lock, reads freely)
  Both call gateway.refund() → customer refunded TWICE

With FOR UPDATE:
  Request A: SELECT ... FOR UPDATE → row LOCKED
  Request B: SELECT ... FOR UPDATE → WAITS at MySQL level
  Request A: gateway.refund() → payment.refund! → COMMIT → row unlocked
  Request B: row unlocked → reads status='refunded' → captured? false → error returned
```

**Why not use optimistic locking here?** Optimistic locking catches the conflict at write time — after both workers have already called the gateway. By then the second refund has already been sent. `FOR UPDATE` prevents both workers from even reaching the gateway call.

---

### 3. Redis Distributed Lock — `SET NX PX`

**Where:** `PaymentLock` module (`app/modules/payment_lock.rb`)

**How it works:** Uses Redis atomic `SET NX PX` to acquire a per-payment mutex across all processes and machines:

```ruby
module PaymentLock
  LOCK_TTL_MS = 30_000   # auto-expires after 30s if worker crashes

  def self.acquire(payment_id)
    $redis.set("lock:payment:#{payment_id}", 1, nx: true, px: LOCK_TTL_MS)
    # NX — set ONLY if key does Not eXist (atomic check-and-set)
    # PX — expire after 30,000ms (crash safety)
    # Returns true if acquired, nil if already held
  end

  def self.with_lock(payment_id)
    acquired = acquire(payment_id)
    raise PaymentLockError unless acquired
    yield
  ensure
    release(payment_id) if acquired  # always release, even on crash
  end
end
```

**Why `SET NX PX` and not a regular check-then-set?**

```ruby
# WRONG — race condition between check and set:
if $redis.get(key).nil?    # Worker A and B both pass this
  $redis.set(key, 1)       # Both set it — lock acquired by BOTH
end

# CORRECT — atomic:
$redis.set(key, 1, nx: true)  # Only ONE wins, the other gets nil
```

The Redis server executes `SET NX` as one indivisible operation. There is no window between "check if key exists" and "set the key" where a second worker can slip in.

**The 30-second TTL:** If a worker crashes while holding the lock, Redis automatically expires the key after 30 seconds. Without TTL, a crashed worker would hold the lock forever and all further processing of that payment would be blocked.

**The `ensure` block:** Guarantees the lock is always released even if the block raises an exception — no manual cleanup needed.

---

### When each lock is used

| Scenario | Lock Used | Why |
|---|---|---|
| Two Kafka consumers racing to update the same payment state | Optimistic (`lock_version`) | Lightweight, no DB round-trip on the happy path |
| Two HTTP refund requests arriving simultaneously | Pessimistic (`FOR UPDATE`) | Must block at read time — optimistic is too late (gateway already called) |
| Two workers competing to process the same payment event | Redis `SET NX PX` | Cross-process mutex, not limited to DB transactions |
