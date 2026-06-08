class DailyReconciliationJob < ApplicationJob
  queue_as :reconciliation

  def perform(date_str = nil)
    reconciliation_date = date_str ? Date.parse(date_str) : Date.yesterday

    Rails.logger.info("[DailyReconciliationJob] Starting reconciliation for #{reconciliation_date}")

    %w[razorpay stripe].each do |gateway|
      reconcile_gateway(gateway, reconciliation_date)
    end

    Rails.logger.info("[DailyReconciliationJob] Reconciliation complete for #{reconciliation_date}")
  end

  private

  def reconcile_gateway(gateway, date)
    service = case gateway
              when "razorpay" then RazorpayReconciliationService.new(date)
              when "stripe"   then StripeReconciliationService.new(date)
              end

    gateway_records = service.fetch_settlements

    report = ReconciliationReport.find_or_create_by!(
      gateway:     gateway,
      report_date: date
    ) do |r|
      r.raw_data   = gateway_records
      r.fetched_at = Time.current
      r.status     = "pending"
    end

    mismatches = ReconciliationMismatchDetectorService.new(
      gateway:         gateway,
      date:            date,
      gateway_records: gateway_records
    ).detect

    mismatches.each do |mismatch|
      create_or_update_mismatch(mismatch)
    end

    report.update!(status: "processed")
    Rails.logger.info("[DailyReconciliationJob] #{gateway}: #{mismatches.size} mismatches found for #{date}")
  rescue StandardError => e
    Rails.logger.error("[DailyReconciliationJob] Failed for #{gateway} on #{date}: #{e.message}")
    ReconciliationReport.find_by(gateway: gateway, report_date: date)&.update!(status: "failed")
  end

  def create_or_update_mismatch(mismatch)
    record = ReconciliationMismatch.find_or_initialize_by(
      payment_id:    mismatch[:payment_id],
      mismatch_type: mismatch[:type],
      gateway:       mismatch[:gateway]
    )

    return if record.persisted? && record.resolved? # already resolved by pending verification checker job which will run every 15 min 

    record.update!(
      our_value:     mismatch[:our_value].to_s,
      gateway_value: mismatch[:gateway_value].to_s,
      status:        "open",
      notes:         mismatch[:notes]
    )

    # Auto-fixable: push to reconciliation.required topic
    if mismatch[:auto_fixable]
      KafkaProducer.publish(
        topic:         "reconciliation.required",
        payload:       {
          payment_id:    mismatch[:payment_id],
          gateway:       mismatch[:gateway],
          reason:        mismatch[:type],
          gateway_value: mismatch[:gateway_value],
          trace_id:      Payment.find(mismatch[:payment_id]).trace_id,
          event_id:      SecureRandom.uuid
        },
        partition_key: mismatch[:payment_id]
      )
    end
  end
end
