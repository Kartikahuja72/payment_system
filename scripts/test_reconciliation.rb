# scripts/test_reconciliation.rb
# Run with: bundle exec rails runner scripts/test_reconciliation.rb
#
# What this tests:
#   1. PendingVerificationCheckerJob  — detects stuck payments, creates mismatch, publishes to Kafka
#   2. ReconciliationMismatchDetectorService — all 4 mismatch types + auto_fixable logic
#   3. ReconciliationMismatch resolve! lifecycle
#   4. ReconciliationReport idempotency (the guard inside DailyReconciliationJob)
#   5. ReconciliationConsumer inline simulation (no Kafka needed)
#
# Prerequisites: Rails server does NOT need to be running. Kafka does NOT need to be running
# (Kafka publishes are wrapped in rescue so the rest of the test continues).
# MySQL must be running.

ERRORS = []

def section(title)
  puts "\n" + ("─" * 64)
  puts "  #{title}"
  puts "─" * 64
end

def ok(msg)
  puts "  [PASS] #{msg}"
end

def fail_test(msg)
  puts "  [FAIL] #{msg}"
  ERRORS << msg
end

def info(msg)
  puts "  [INFO] #{msg}"
end

def unique_suffix
  SecureRandom.hex(4)
end

puts "\n" + ("=" * 64)
puts "  RECONCILIATION ENGINE TEST SUITE"
puts "  #{Time.current}"
puts "=" * 64

# ─────────────────────────────────────────────────────────────────────────────
# TEST 1: PendingVerificationCheckerJob
#
# Creates a payment stuck in `pending_verification` for 20 minutes,
# runs the job, and verifies the mismatch record is created.
# ─────────────────────────────────────────────────────────────────────────────
section "TEST 1: PendingVerificationCheckerJob — stuck payment detection"

sfx = unique_suffix

stuck_payment = Payment.create!(
  order_id:        "order_stuck_#{sfx}",
  amount:          50000,
  currency:        "INR",
  gateway:         "razorpay",
  payment_method:  "card",
  idempotency_key: "idem_stuck_#{sfx}",
  trace_id:        SecureRandom.uuid
)

# Bypass state machine — set status and timestamp directly so the job finds it
stuck_payment.update_columns(
  status:     "pending_verification",
  updated_at: 20.minutes.ago
)

ok "Created payment id=#{stuck_payment.id} | status=pending_verification | updated_at=20min ago"

info "Running PendingVerificationCheckerJob inline..."

begin
  PendingVerificationCheckerJob.new.perform
rescue => e
  # Kafka publish may fail if broker not running — that's OK for this test
  info "Kafka publish raised #{e.class}: #{e.message.truncate(80)} (expected if Kafka is down)"
end

mismatch = ReconciliationMismatch.find_by(
  payment_id:    stuck_payment.id,
  mismatch_type: "pending_verification"
)

if mismatch
  ok "ReconciliationMismatch created:"
  ok "  status=#{mismatch.status} | our_value=#{mismatch.our_value} | gateway_value=#{mismatch.gateway_value}"
  ok "  notes=#{mismatch.notes}"
else
  fail_test "ReconciliationMismatch NOT created by PendingVerificationCheckerJob"
end

info "If Kafka is running, ReconciliationConsumer will pick up the message."
info "poll_gateway_status will fail (fake gateway_payment_id) → manual_review flag."

# ─────────────────────────────────────────────────────────────────────────────
# TEST 2: ReconciliationMismatchDetectorService — all 4 mismatch types
#
# Creates 4 DB payments covering every detection case, runs the service with
# synthetic gateway data, and asserts each mismatch is detected correctly.
# ─────────────────────────────────────────────────────────────────────────────
section "TEST 2: ReconciliationMismatchDetectorService — 4 mismatch types"

today = Date.today

# Payment A — everything matches, should produce NO mismatch
sfx_a = unique_suffix
p_clean = Payment.create!(
  order_id:           "order_clean_#{sfx_a}",
  amount:             10000,
  currency:           "INR",
  gateway:            "razorpay",
  payment_method:     "card",
  gateway_payment_id: "order_clean_gw_#{sfx_a}",
  idempotency_key:    "idem_clean_#{sfx_a}",
  trace_id:           SecureRandom.uuid
)
p_clean.update_columns(status: "captured", created_at: today.beginning_of_day + 1.hour)

# Payment B — we say failed, gateway says captured → status_mismatch (auto_fixable=true)
sfx_b = unique_suffix
p_status = Payment.create!(
  order_id:           "order_status_#{sfx_b}",
  amount:             20000,
  currency:           "INR",
  gateway:            "razorpay",
  payment_method:     "card",
  gateway_payment_id: "order_status_gw_#{sfx_b}",
  idempotency_key:    "idem_status_#{sfx_b}",
  trace_id:           SecureRandom.uuid
)
p_status.update_columns(status: "failed", created_at: today.beginning_of_day + 2.hours)

# Payment C — DB amount=30000, gateway amount=29000 → amount_mismatch (auto_fixable=false)
sfx_c = unique_suffix
p_amount = Payment.create!(
  order_id:           "order_amount_#{sfx_c}",
  amount:             30000,
  currency:           "INR",
  gateway:            "razorpay",
  payment_method:     "card",
  gateway_payment_id: "order_amount_gw_#{sfx_c}",
  idempotency_key:    "idem_amount_#{sfx_c}",
  trace_id:           SecureRandom.uuid
)
p_amount.update_columns(status: "captured", created_at: today.beginning_of_day + 3.hours)

# Payment D — DB has it, gateway does NOT → missing_in_gateway (auto_fixable=false)
sfx_d = unique_suffix
p_missing_gw = Payment.create!(
  order_id:           "order_missinggw_#{sfx_d}",
  amount:             40000,
  currency:           "INR",
  gateway:            "razorpay",
  payment_method:     "card",
  gateway_payment_id: "order_missinggw_gw_#{sfx_d}",
  idempotency_key:    "idem_missinggw_#{sfx_d}",
  trace_id:           SecureRandom.uuid
)
p_missing_gw.update_columns(status: "captured", created_at: today.beginning_of_day + 4.hours)

ok "Created 4 test payments (ids: #{p_clean.id}, #{p_status.id}, #{p_amount.id}, #{p_missing_gw.id})"

# Synthetic gateway records — p_missing_gw deliberately absent
gateway_records = [
  { gateway_payment_id: p_clean.gateway_payment_id,     status: "captured", amount: 10000 }, # match
  { gateway_payment_id: p_status.gateway_payment_id,    status: "captured", amount: 20000 }, # status mismatch
  { gateway_payment_id: p_amount.gateway_payment_id,    status: "captured", amount: 29000 }, # amount mismatch
  # p_missing_gw is NOT in gateway → missing_in_gateway
  { gateway_payment_id: "order_ghost_#{unique_suffix}",  status: "captured", amount: 55000 }, # missing_in_db
]

service = ReconciliationMismatchDetectorService.new(
  gateway:         "razorpay",
  date:            today,
  gateway_records: gateway_records
)

mismatches = service.detect
info "Detected #{mismatches.length} mismatch(es) (expected 3):"

# missing_in_gateway
mm_missing_gw = mismatches.find { |m| m[:type] == "missing_in_gateway" }
if mm_missing_gw
  ok "missing_in_gateway | payment=#{mm_missing_gw[:payment_id]} | our=#{mm_missing_gw[:our_value]} | gw=#{mm_missing_gw[:gateway_value]} | auto_fixable=#{mm_missing_gw[:auto_fixable]}"
  fail_test "missing_in_gateway should NOT be auto_fixable" if mm_missing_gw[:auto_fixable]
else
  fail_test "missing_in_gateway NOT detected"
end

# status_mismatch
mm_status = mismatches.find { |m| m[:type] == "status_mismatch" }
if mm_status
  ok "status_mismatch | payment=#{mm_status[:payment_id]} | our=#{mm_status[:our_value]} | gw=#{mm_status[:gateway_value]} | auto_fixable=#{mm_status[:auto_fixable]}"
  unless mm_status[:auto_fixable]
    fail_test "status_mismatch (our=failed, gw=captured) SHOULD be auto_fixable"
  end
else
  fail_test "status_mismatch NOT detected"
end

# amount_mismatch
mm_amount = mismatches.find { |m| m[:type] == "amount_mismatch" }
if mm_amount
  ok "amount_mismatch | payment=#{mm_amount[:payment_id]} | our=#{mm_amount[:our_value]} | gw=#{mm_amount[:gateway_value]} | auto_fixable=#{mm_amount[:auto_fixable]}"
  fail_test "amount_mismatch should NOT be auto_fixable" if mm_amount[:auto_fixable]
else
  fail_test "amount_mismatch NOT detected"
end

# missing_in_db
mm_missing_db = mismatches.find { |m| m[:type] == "missing_in_db" }
if mm_missing_db
  ok "missing_in_db | payment_id=#{mm_missing_db[:payment_id]} (0=sentinel) | gw=#{mm_missing_db[:gateway_value]} | auto_fixable=#{mm_missing_db[:auto_fixable]}"
  fail_test "missing_in_db sentinel payment_id should be 0" unless mm_missing_db[:payment_id] == 0
  fail_test "missing_in_db should NOT be auto_fixable" if mm_missing_db[:auto_fixable]
else
  fail_test "missing_in_db NOT detected"
end

# Clean match should produce NO mismatch for p_clean
clean_mismatches = mismatches.select { |m| m[:payment_id] == p_clean.id }
if clean_mismatches.empty?
  ok "Clean payment (id=#{p_clean.id}) correctly produced 0 mismatches"
else
  fail_test "Clean payment produced unexpected mismatches: #{clean_mismatches.map { |m| m[:type] }.join(', ')}"
end

# ─────────────────────────────────────────────────────────────────────────────
# TEST 3: ReconciliationMismatch resolve! lifecycle
# ─────────────────────────────────────────────────────────────────────────────
section "TEST 3: ReconciliationMismatch.resolve! lifecycle"

mismatch_record = ReconciliationMismatch.create!(
  payment_id:    p_status.id,
  mismatch_type: "status_mismatch",
  gateway:       "razorpay",
  our_value:     "failed",
  gateway_value: "captured",
  status:        "open"
)
ok "Created mismatch: id=#{mismatch_record.id}, status=#{mismatch_record.status}"

mismatch_record.resolve!(notes: "Auto-resolved: gateway confirmed capture")
mismatch_record.reload

if mismatch_record.status == "resolved" && mismatch_record.resolved_at.present?
  ok "resolve! → status=resolved, resolved_at=#{mismatch_record.resolved_at.strftime('%H:%M:%S')}"
else
  fail_test "resolve! failed: status=#{mismatch_record.status}, resolved_at=#{mismatch_record.resolved_at.inspect}"
end

# Test flag_for_manual_review! as well
mismatch_manual = ReconciliationMismatch.create!(
  payment_id:    p_amount.id,
  mismatch_type: "amount_mismatch",
  gateway:       "razorpay",
  our_value:     "30000",
  gateway_value: "29000",
  status:        "open"
)

mismatch_manual.flag_for_manual_review!(notes: "Investigate fee deduction discrepancy")
mismatch_manual.reload

if mismatch_manual.status == "manual_review"
  ok "flag_for_manual_review! → status=manual_review, notes=#{mismatch_manual.notes}"
else
  fail_test "flag_for_manual_review! failed: status=#{mismatch_manual.status}"
end

# ─────────────────────────────────────────────────────────────────────────────
# TEST 4: ReconciliationReport idempotency
#
# DailyReconciliationJob uses find_or_create_by! to be idempotent.
# Running the job twice for the same date must not create duplicate reports.
# ─────────────────────────────────────────────────────────────────────────────
section "TEST 4: ReconciliationReport — idempotency (DailyReconciliationJob guard)"

test_date = Date.today - 2  # use 2 days ago to avoid conflicts with real data

report1 = ReconciliationReport.find_or_create_by!(
  gateway:     "razorpay",
  report_date: test_date
) do |r|
  r.status     = "pending"
  r.fetched_at = Time.current
  r.raw_data   = { test: true, run: 1 }.to_json
end

ok "First call: report id=#{report1.id}, status=#{report1.status}"

# Second call with same gateway+report_date → must return same record, not create a new one
report2 = ReconciliationReport.find_or_create_by!(
  gateway:     "razorpay",
  report_date: test_date
) do |r|
  # This block should NOT run because the record already exists
  r.status     = "pending"
  r.fetched_at = Time.current
  r.raw_data   = { test: true, run: 2 }.to_json
end

if report1.id == report2.id
  ok "Idempotent: second find_or_create_by! returned same record (id=#{report1.id})"
else
  fail_test "NOT idempotent: duplicate report created! ids=#{report1.id}, #{report2.id}"
end

# Confirm raw_data was NOT overwritten (run: 1 should still be there)
raw = JSON.parse(report2.raw_data)
if raw["run"] == 1
  ok "raw_data untouched: block did not re-run on existing record"
else
  fail_test "raw_data was overwritten: run=#{raw['run']} (expected 1)"
end

# ─────────────────────────────────────────────────────────────────────────────
# TEST 5: ReconciliationConsumer — inline simulation (no Kafka needed)
#
# Directly instantiates the consumer and calls the private methods via send.
# Simulates what happens when the consumer receives a reconciliation message.
# ─────────────────────────────────────────────────────────────────────────────
section "TEST 5: ReconciliationConsumer — inline simulation"

consumer = ReconciliationConsumer.new

# ── 5a: handle_status_mismatch — gateway says captured, we say failed ────────
sfx_e = unique_suffix
p_recover = Payment.create!(
  order_id:           "order_recover_#{sfx_e}",
  amount:             15000,
  currency:           "INR",
  gateway:            "razorpay",
  payment_method:     "card",
  gateway_payment_id: "order_recover_gw_#{sfx_e}",
  idempotency_key:    "idem_recover_#{sfx_e}",
  trace_id:           SecureRandom.uuid
)
p_recover.update_columns(status: "failed")

ok "Before reconciliation: payment id=#{p_recover.id}, status=#{p_recover.status}"

begin
  consumer.send(:handle_status_mismatch, p_recover, "captured")
  p_recover.reload
  if p_recover.status == "captured"
    ok "handle_status_mismatch: payment recovered failed→captured via reconcile_success!"
  else
    fail_test "handle_status_mismatch: payment still in #{p_recover.status}"
  end
rescue => e
  fail_test "handle_status_mismatch raised #{e.class}: #{e.message}"
end

# ── 5b: handle_status_mismatch — gateway says captured, we say captured ───────
# Should do nothing (our status is not failed so no auto-fix)
sfx_f = unique_suffix
p_already_ok = Payment.create!(
  order_id:           "order_alreadyok_#{sfx_f}",
  amount:             15000,
  currency:           "INR",
  gateway:            "razorpay",
  payment_method:     "card",
  gateway_payment_id: "order_alreadyok_gw_#{sfx_f}",
  idempotency_key:    "idem_alreadyok_#{sfx_f}",
  trace_id:           SecureRandom.uuid
)
p_already_ok.update_columns(status: "captured")

before_lock_version = p_already_ok.lock_version

begin
  consumer.send(:handle_status_mismatch, p_already_ok, "captured")
  p_already_ok.reload
  if p_already_ok.lock_version == before_lock_version
    ok "handle_status_mismatch: no-op when our status already matches (lock_version unchanged)"
  else
    fail_test "handle_status_mismatch: payment was modified when it shouldn't have been"
  end
rescue => e
  fail_test "handle_status_mismatch (no-op path) raised #{e.class}: #{e.message}"
end

# ── 5c: missing_in_db sentinel — payment_id 0 skips processing ───────────────
info "Testing payment_id=0 sentinel skip..."
payload_sentinel = { "payment_id" => 0, "reason" => "missing_in_db", "gateway" => "razorpay" }
begin
  consumer.send(:process, payload_sentinel)
  ok "payment_id=0 sentinel correctly skipped (no RecordNotFound raised)"
rescue ActiveRecord::RecordNotFound
  fail_test "payment_id=0 sentinel should be skipped before Payment.find — RecordNotFound raised"
rescue => e
  fail_test "payment_id=0 sentinel raised unexpected #{e.class}: #{e.message}"
end

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
section "SUMMARY"

puts ""
puts "  Payments created during test:"
puts "    id=#{stuck_payment.id}   — pending_verification (stuck payment, Test 1)"
puts "    id=#{p_clean.id}         — captured (clean match, Test 2)"
puts "    id=#{p_status.id}        — failed (status mismatch, Test 2)"
puts "    id=#{p_amount.id}        — captured (amount mismatch, Test 2)"
puts "    id=#{p_missing_gw.id}    — captured (missing in gateway, Test 2)"
puts "    id=#{p_recover.id}       — recovered failed→captured (Test 5a)"
puts ""
puts "  Expected log lines (if Kafka is running):"
puts "    [PendingVerificationCheckerJob] Found 1 stuck payments"
puts "    [PendingVerificationCheckerJob] Queued reconciliation for payment #{stuck_payment.id}"
puts "    [ReconciliationConsumer] Processing payment #{stuck_payment.id} | reason=pending_verification"
puts "    [ReconciliationConsumer] Failed to poll gateway for payment #{stuck_payment.id}"
puts "    [ReconciliationConsumer] Payment #{stuck_payment.id} still inconclusive — flagged for manual review"
puts ""

if ERRORS.empty?
  puts "  ✓ ALL TESTS PASSED"
else
  puts "  #{ERRORS.length} TEST(S) FAILED:"
  ERRORS.each { |e| puts "    ✗ #{e}" }
end

puts "\n" + ("=" * 64)
