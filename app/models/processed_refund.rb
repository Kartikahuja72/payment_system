class ProcessedRefund < ApplicationRecord
  belongs_to :payment
  validates :refund_id, :source, presence: true
  validates :refund_id, uniqueness: { scope: :source }
end

#  This table ensures each gateway refund ID is processed exactly once. 
