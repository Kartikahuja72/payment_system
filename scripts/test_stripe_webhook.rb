require "openssl"
require "net/http"
require "json"
require "securerandom"

# ─────────────────────────────────────────────────────────────────────────────
# Simulates Stripe webhook calls locally — no Stripe CLI needed.
# Run: ruby scripts/test_stripe_webhook.rb
#
# Steps:
#   1. Create a payment via POST /payments with gateway: "stripe"
#   2. Copy gateway_payment_id from response (starts with pi_)
#   3. Set PAYMENT_INTENT_ID below
#   4. Run this script
#
# Stripe signature format (gem 12.x):
#   Header: Stripe-Signature: t=timestamp,v1=hmac
#   HMAC key: full secret string including "whsec_" prefix
#   HMAC input: "timestamp.raw_body"
# ─────────────────────────────────────────────────────────────────────────────

WEBHOOK_SECRET    = "whsec_d3bb8ec0481305d0b1e453fd5c2d45fb2dbe51d9ce5e7cc722345ab8d1855812"
WEBHOOK_URL       = "http://localhost:3000/webhooks/stripe"
PAYMENT_INTENT_ID = "pi_3TeGxt124oIBB3iH1eLICxYL"  # ← replace with your payment's gateway_payment_id
PAYMENT_AMOUNT    = 50000

def build_stripe_signature(payload)
  timestamp = Time.now.to_i
  hmac      = OpenSSL::HMAC.hexdigest("SHA256", WEBHOOK_SECRET, "#{timestamp}.#{payload}")
  "t=#{timestamp},v1=#{hmac}"
end

def send_webhook(payload_hash)
  payload   = payload_hash.to_json
  signature = build_stripe_signature(payload)

  uri     = URI(WEBHOOK_URL)
  http    = Net::HTTP.new(uri.host, uri.port)
  request = Net::HTTP::Post.new(uri.path)

  request["Content-Type"]    = "application/json"
  request["Stripe-Signature"] = signature
  request.body = payload

  response = http.request(request)
  puts "  Status:   #{response.code}"
  puts "  Response: #{response.body}"
  response
end

# ─── Event 1: payment_intent.succeeded ───────────────────────────────────────
puts "\n=== Sending payment_intent.succeeded ==="
puts "  Payment moves: authorized → captured"
puts "  Expected: ledger entry created, notification sent"

send_webhook({
  id:      "evt_#{SecureRandom.hex(12)}",
  object:  "event",
  type:    "payment_intent.succeeded",
  created: Time.now.to_i,
  data:    {
    object: {
      id:                   PAYMENT_INTENT_ID,
      object:               "payment_intent",
      amount:               PAYMENT_AMOUNT,
      currency:             "inr",
      status:               "succeeded",
      payment_method_types: ["card"],
      metadata:             {}
    }
  }
})

puts "\n  Wait ~5 seconds, then check:"
puts "  GET http://localhost:3000/payments/<id>   → status should be 'captured'"
puts "\n  Press Enter to send refund webhook..."
STDIN.gets

# ─── Event 2: charge.refunded ─────────────────────────────────────────────────
puts "\n=== Sending charge.refunded ==="
puts "  Expected: captured → refunded, ledger entry, notification"

CHARGE_ID = "ch_#{SecureRandom.hex(12)}"
REFUND_ID = "re_#{SecureRandom.hex(12)}"

send_webhook({
  id:      "evt_#{SecureRandom.hex(12)}",
  object:  "event",
  type:    "charge.refunded",
  created: Time.now.to_i,
  data:    {
    object: {
      id:              CHARGE_ID,
      object:          "charge",
      amount:          PAYMENT_AMOUNT,
      amount_refunded: PAYMENT_AMOUNT,
      currency:        "inr",
      payment_intent:  PAYMENT_INTENT_ID,
      refunds:         {
        data: [
          {
            id:       REFUND_ID,
            object:   "refund",
            amount:   PAYMENT_AMOUNT,
            currency: "inr",
            status:   "succeeded"
          }
        ]
      }
    }
  }
})

puts "\n  Wait ~5 seconds, then check:"
puts "  GET http://localhost:3000/payments/<id>   → status should be 'refunded'"

# ─── Duplicate test ───────────────────────────────────────────────────────────
puts "\n=== Sending duplicate charge.refunded (dedup test) ==="
puts "  Same refund_id — should be blocked by ProcessedRefund"

send_webhook({
  id:      "evt_#{SecureRandom.hex(12)}",
  object:  "event",
  type:    "charge.refunded",
  created: Time.now.to_i,
  data:    {
    object: {
      id:              CHARGE_ID,
      object:          "charge",
      amount:          PAYMENT_AMOUNT,
      amount_refunded: PAYMENT_AMOUNT,
      currency:        "inr",
      payment_intent:  PAYMENT_INTENT_ID,
      refunds:         {
        data: [
          {
            id:       REFUND_ID,    # same refund_id — dedup blocks this
            object:   "refund",
            amount:   PAYMENT_AMOUNT,
            currency: "inr",
            status:   "succeeded"
          }
        ]
      }
    }
  }
})

puts "\n  Duplicate blocked — no second ledger entry, no second notification"
puts "\nDone."


# One thing to note — race condition handled correctly
# Two Karafka threads picked up both webhooks simultaneously. Both passed the ProcessedRefund check at the same millisecond. Both tried to insert:


# Thread 1: ProcessedRefund Create → COMMIT   ✓
# Thread 2: ProcessedRefund Create → ROLLBACK ✓ (unique constraint caught it)
# This is exactly why we have the unique index on processed_refunds. The rollback on thread 2 is correct and expected — it means the dedup layer worked under concurrent load.


