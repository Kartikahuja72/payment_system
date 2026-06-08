module PaymentGateway # Gateway Interface
  def authorize(payment)
    raise NotImplementedError, "#{self.class}#authorize must be implemented"
  end

  def capture(payment)
    raise NotImplementedError, "#{self.class}#capture must be implemented"
  end

  def refund(payment)
    raise NotImplementedError, "#{self.class}#refund must be implemented"
  end

  def void(payment)
    raise NotImplementedError, "#{self.class}#void must be implemented"
  end
end
