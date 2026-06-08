class LedgerEntryService
  def initialize(payment:, amount:, currency:, trace_id:, reference_id:)
    @payment      = payment
    @amount       = amount
    @currency     = currency
    @trace_id     = trace_id
    @reference_id = reference_id
  end

  # authorization: customer_wallet (debit) + platform_holding (credit)
  # Money is reserved — customer's wallet decreases, platform holds it
  def record_authorization
    create_pair(
      entry_type: "authorization",
      debit_account:  "customer_wallet",
      credit_account: "platform_holding"
    )
  end

  # capture: platform_holding (debit) + platform_revenue (credit)
  # Money actually moves — platform releases hold, earns as revenue
  def record_capture
    create_pair(
      entry_type: "capture",
      debit_account:  "platform_holding",
      credit_account: "platform_revenue"
    )
  end

  # refund: platform_revenue (debit) + customer_wallet (credit)
  # Money reversed — platform gives back, customer's wallet restored
  def record_refund
    create_pair(
      entry_type: "refund",
      debit_account:  "platform_revenue",
      credit_account: "customer_wallet"
    )
  end

  private

  def create_pair(entry_type:, debit_account:, credit_account:)
    ActiveRecord::Base.transaction do
      debit = LedgerEntry.create!(
        payment:      @payment,
        entry_type:   entry_type,
        account_type: debit_account,
        direction:    "debit",
        amount:       @amount,
        currency:     @currency,
        reference_id: "#{@reference_id}_debit",
        trace_id:     @trace_id
      )

      credit = LedgerEntry.create!(
        payment:      @payment,
        entry_type:   entry_type,
        account_type: credit_account,
        direction:    "credit",
        amount:       @amount,
        currency:     @currency,
        reference_id: "#{@reference_id}_credit",
        trace_id:     @trace_id
      )

      # Invariant check — debit and credit must always equal
      # This should never fail but if it does, roll back immediately
      unless debit.amount == credit.amount
        raise "Ledger imbalance detected for payment #{@payment.id} — #{entry_type}"
      end

      Rails.logger.info("[LedgerEntryService] #{entry_type} | payment=#{@payment.id} | #{debit_account} -#{@amount} | #{credit_account} +#{@amount} | trace_id=#{@trace_id}")

      [debit, credit]
    end
  end
end
