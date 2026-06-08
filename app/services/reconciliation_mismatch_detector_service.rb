class ReconciliationMismatchDetectorService
  def initialize(gateway:, date:, gateway_records:)
    @gateway         = gateway
    @date            = date
    @gateway_records = gateway_records
  end

  def detect
    mismatches = []

    db_payments     = fetch_db_payments
    gateway_map     = build_gateway_map

    # ── Check 1: payments in DB vs gateway ──────────────────────────────────
    db_payments.each do |payment|
      gateway_record = gateway_map[payment.gateway_payment_id]

      if gateway_record.nil?
        # Payment exists in DB but gateway has no record
        mismatches << {
          payment_id:    payment.id,
          type:          "missing_in_gateway",
          gateway:       @gateway,
          our_value:     payment.status,
          gateway_value: "not_found",
          auto_fixable:  false,
          notes:         "Payment #{payment.id} exists in DB but not found in gateway settlement"
        }
        next
      end

      # ── Check 2: status mismatch ───────────────────────────────────────────
      if status_mismatch?(payment, gateway_record)
        auto_fix = can_auto_fix?(payment.status, gateway_record[:status])
        mismatches << {
          payment_id:    payment.id,
          type:          "status_mismatch",
          gateway:       @gateway,
          our_value:     payment.status,
          gateway_value: gateway_record[:status],
          auto_fixable:  auto_fix,
          notes:         "DB: #{payment.status}, Gateway: #{gateway_record[:status]}"
        }
      end

      # ── Check 3: amount mismatch ───────────────────────────────────────────
      if gateway_record[:amount] && gateway_record[:amount] != payment.amount
        mismatches << {
          payment_id:    payment.id,
          type:          "amount_mismatch",
          gateway:       @gateway,
          our_value:     payment.amount.to_s,
          gateway_value: gateway_record[:amount].to_s,
          auto_fixable:  false,
          notes:         "DB amount: #{payment.amount}, Gateway amount: #{gateway_record[:amount]}"
        }
      end
    end

    # ── Check 4: payments at gateway not in DB ─────────────────────────────
    db_gateway_ids = db_payments.map(&:gateway_payment_id).compact.to_set

    @gateway_records.each do |record|
      next if db_gateway_ids.include?(record[:gateway_payment_id])
      next unless record[:status] == "captured"

      # Gateway has a captured payment we have no record of — critical
      mismatches << {
        payment_id:    0,  # no DB payment_id — use 0 as sentinel
        type:          "missing_in_db",
        gateway:       @gateway,
        our_value:     "not_found",
        gateway_value: "#{record[:status]}/#{record[:amount]}",
        auto_fixable:  false,
        notes:         "Gateway has captured payment #{record[:gateway_payment_id]} with no DB record"
      }
    end

    mismatches
  end

  private

  def fetch_db_payments
    Payment
      .where(gateway: @gateway)
      .where("DATE(created_at) = ?", @date)
      .where.not(gateway_payment_id: nil)
  end

  def build_gateway_map
    @gateway_records.each_with_object({}) do |record, map|
      map[record[:gateway_payment_id]] = record
    end
  end

  def status_mismatch?(payment, gateway_record)
    return false if gateway_record[:status].blank?

    our_status = normalize_our_status(payment.status)
    our_status != gateway_record[:status]
  end

  def normalize_our_status(status)
    case status
    when "captured", "settled" then "captured"
    when "authorized"          then "authorized"
    when "failed"              then "failed"
    when "refunded"            then "refunded"
    else status
    end
  end

  # Only safe to auto-fix when gateway shows success and we show failed
  # Never auto-fix the reverse — could re-charge a customer
  def can_auto_fix?(our_status, gateway_status)
    our_status == "failed" && gateway_status == "captured"
  end
end
