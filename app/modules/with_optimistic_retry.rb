module WithOptimisticRetry
  MAX_RETRIES = 3

  # Wraps a block that updates a payment with retry logic on StaleObjectError.
  # Rails raises StaleObjectError when lock_version mismatch is detected
  # (another worker updated the row between our read and our write).
  # We re-read the fresh record and retry up to MAX_RETRIES times.
  def with_lock_retry
    retries = 0
    begin
      yield
    rescue ActiveRecord::StaleObjectError => e
      retries += 1
      Rails.logger.warn("[WithOptimisticRetry] StaleObjectError on attempt #{retries}: #{e.message}")

      if retries < MAX_RETRIES
        retry
      else
        Rails.logger.error("[WithOptimisticRetry] Max retries (#{MAX_RETRIES}) exceeded — giving up")
        raise
      end
    end
  end
end


# retry in Ruby jumps back to the nearest begin and re-executes the block. On each retry, the block re-reads the payment from DB with the current lock_version. If another worker won the first conflict, the retry reads the fresh state and continues from there.
