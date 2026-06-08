class LedgerEntrySerializer < ActiveModel::Serializer
  attributes :id, :entry_type, :account_type, :direction, :amount, :currency, :reference_id, :trace_id, :created_at
end
