module LedgerBalance
  # Balance for a single payment
  def self.for_payment(payment_id)
    entries = LedgerEntry.where(payment_id: payment_id)

    {
      payment_id:     payment_id,
      total_debited:  entries.where(direction: "debit").sum(:amount),
      total_credited: entries.where(direction: "credit").sum(:amount),
      balanced:       LedgerEntry.balanced_for?(payment_id),
      by_account:     balance_by_account(entries),
      by_entry_type:  balance_by_entry_type(entries)
    }
  end

  # Net balance for an account type across all payments
  def self.for_account(account_type)
    entries  = LedgerEntry.where(account_type: account_type)
    debits   = entries.where(direction: "debit").sum(:amount)
    credits  = entries.where(direction: "credit").sum(:amount)

    {
      account_type: account_type,
      debits:       debits,
      credits:      credits,
      net:          credits - debits  # positive = net inflow to this account
    }
  end

  def self.balance_by_account(entries)
    LedgerEntry::ACCOUNT_TYPES.each_with_object({}) do |account, hash|
      account_entries = entries.where(account_type: account)
      hash[account] = {
        debits:  account_entries.where(direction: "debit").sum(:amount),
        credits: account_entries.where(direction: "credit").sum(:amount)
      }
    end
  end

  def self.balance_by_entry_type(entries)
    LedgerEntry::ENTRY_TYPES.each_with_object({}) do |type, hash|
      type_entries = entries.where(entry_type: type)
      next if type_entries.empty?

      hash[type] = type_entries.where(direction: "debit").sum(:amount)
    end
  end
end
