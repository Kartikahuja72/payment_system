require "openssl"
require "net/http"
require "json"
require "securerandom"

# ─────────────────────────────────────────────────────────────────────────────
# Simulates Razorpay webhook calls locally — no ngrok needed.
# Run: ruby scripts/test_razorpay_webhook.rb
#
# Steps:
#   1. Create a payment via POST /payments
#   2. Copy gateway_payment_id from response
#   3. Set GATEWAY_PAYMENT_ID below
#   4. Run this script — it fires payment.captured first, then refund.created
# ─────────────────────────────────────────────────────────────────────────────

WEBHOOK_SECRET     = "28f10a46eb24cd53aba07520cff021d4623bcaf3ff225637c013044594c61321"
WEBHOOK_URL        = "http://localhost:3000/webhooks/razorpay"
GATEWAY_PAYMENT_ID = "order_SyMKaR8cXz4PXY"   # ← change this to your payment's gateway_payment_id
PAYMENT_AMOUNT     = 50000                      # paise

def send_webhook(payload_hash)
  payload   = payload_hash.to_json
  signature = OpenSSL::HMAC.hexdigest("SHA256", WEBHOOK_SECRET, payload)

  uri     = URI(WEBHOOK_URL)
  http    = Net::HTTP.new(uri.host, uri.port)
  request = Net::HTTP::Post.new(uri.path)

  request["Content-Type"]          = "application/json"
  request["X-Razorpay-Signature"]  = signature
  request.body = payload

  response = http.request(request)
  puts "  Status:   #{response.code}"
  puts "  Response: #{response.body}"
  response
end

# ─── Event 1: payment.captured ────────────────────────────────────────────────
puts "\n=== Sending payment.captured ==="
puts "  Payment moves: authorized → captured"
puts "  Expected: ledger entry created, notification sent"

PAYMENT_ID = "pay_#{SecureRandom.hex(8)}"

send_webhook({
  entity:    "event",
  event:     "payment.captured",
  contains:  ["payment"],
  payload:   {
    payment: {
      entity: {
        id:          PAYMENT_ID,
        order_id:    GATEWAY_PAYMENT_ID,
        amount:      PAYMENT_AMOUNT,
        currency:    "INR",
        status:      "captured",
        method:      "card",
        captured:    true,
        created_at:  Time.now.to_i
      }
    }
  },
  created_at: Time.now.to_i
})

# ─── Verify after capture ─────────────────────────────────────────────────────
puts "\n  Wait ~5 seconds for Karafka to process, then check:"
puts "  GET http://localhost:3000/payments/<id>   → status should be 'captured'"
puts "\n  Press Enter to send refund webhook..."
STDIN.gets

# ─── Event 2: refund.created ──────────────────────────────────────────────────
puts "\n=== Sending refund.created ==="
puts "  Payment moves: captured → refunded"
puts "  Expected: ledger entry created, notification sent"

REFUND_ID = "rfnd_#{SecureRandom.hex(8)}"

send_webhook({
  entity:   "event",
  event:    "refund.created",
  contains: ["refund", "payment"],
  payload:  {
    refund: {
      entity: {
        id:         REFUND_ID,
        payment_id: PAYMENT_ID,
        order_id:   GATEWAY_PAYMENT_ID,
        amount:     PAYMENT_AMOUNT,
        currency:   "INR",
        status:     "processed",
        created_at: Time.now.to_i
      }
    },
    payment: {
      entity: {
        id:       PAYMENT_ID,
        amount:   PAYMENT_AMOUNT,
        currency: "INR",
        status:   "refunded"
      }
    }
  },
  created_at: Time.now.to_i
})

puts "\n  Wait ~5 seconds for Karafka to process, then check:"
puts "  GET http://localhost:3000/payments/<id>   → status should be 'refunded'"

# ─── Duplicate test ──────────────────────────────────────────────────────────
puts "\n=== Sending duplicate refund.created (dedup test) ==="
puts "  Same refund_id sent again — should be skipped by ProcessedRefund check"

send_webhook({
  entity:   "event",
  event:    "refund.created",
  contains: ["refund", "payment"],
  payload:  {
    refund: {
      entity: {
        id:         REFUND_ID,       # same refund_id — dedup should catch this
        payment_id: PAYMENT_ID,
        order_id:   GATEWAY_PAYMENT_ID,
        amount:     PAYMENT_AMOUNT,
        currency:   "INR",
        status:     "processed",
        created_at: Time.now.to_i
      }
    },
    payment: {
      entity: {
        id:     PAYMENT_ID,
        status: "refunded"
      }
    }
  },
  created_at: Time.now.to_i
})

puts "\n  Duplicate should be blocked — no second ledger entry, no second notification"
puts "\nDone."
