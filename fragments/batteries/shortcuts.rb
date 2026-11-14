class MochiShortcuts
  # Returns a mount-owned cleanup token. Successful registration does not
  # invoke the callback; matched keys and registration errors do.
  def self.register(key, callback, options = {})
    Mochi.host_async("shortcuts", "register", [key, options], callback)
  end

  def self.cancel(token)
    Mochi.host_async("shortcuts", "cancel", [token], "")
  end
end
