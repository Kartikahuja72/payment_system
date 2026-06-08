module PaymentLock
  # Lock TTL — if the worker crashes while holding the lock,
  # Redis auto-expires it after 30 seconds so no payment gets stuck forever
  LOCK_TTL_MS = 30_000

  class PaymentLockError < StandardError; end

  # Acquire a Redis distributed lock for a payment.
  # Uses SET NX PX — atomic: set ONLY IF key does not exist, with expiry.
  # Returns true if acquired, false if another worker already holds the lock.
  def self.acquire(payment_id)
    $redis.set(lock_key(payment_id), 1, nx: true, px: LOCK_TTL_MS)
  end

  def self.release(payment_id)
    $redis.del(lock_key(payment_id))
  end

  # Acquires the lock, yields, then always releases — even on crash.
  # Raises PaymentLockError if the lock is already held by another worker.
  def self.with_lock(payment_id)
    acquired = acquire(payment_id)

    unless acquired
      raise PaymentLockError, "Payment #{payment_id} is already being processed by another worker"
    end

    yield
  ensure
    release(payment_id) if acquired
  end

  def self.lock_key(payment_id)
    "lock:payment:#{payment_id}"
  end
  private_class_method :lock_key
end

# Lock_version catches conflicts at write time — after both workers have already read the payment, called the gateway, done their work. By then it is too late to prevent double gateway calls.
# PaymentLock prevents two workers from even starting to process the same payment simultaneously.

# Redis SET NX PX — the atomic operation

# NX — set only if the key does Not eXist
# PX 30000 — expire after 30,000 milliseconds (30 seconds)
# Returns true if the key was set (lock acquired)
# Returns nil/false if the key already existed (lock held by someone else)

# This is atomic — no race condition between checking and setting. In regular code you would write:


# if $redis.get(key).nil?   # check
#   $redis.set(key, 1)      # set — ANOTHER WORKER CAN SLIP IN HERE
# end
# That has a race condition between check and set. SET NX does both atomically in one command — the Redis server either sets it or doesn't, no in-between state possible.

# ensure runs whether the block succeeds or raises an exception. This guarantees the lock is always released — even if the block crashes halfway through. Without ensure, a crash inside the block would leave the lock held until TTL expires.
# if acquired in the ensure — only release if we actually acquired it. If acquire returned false and we raised PaymentLockError, we never held the lock so we must not call release.