# frozen_string_literal: true

module ConvertSdk
  # A frozen singleton sentinel — the SDK's public contract for a *business miss*.
  #
  # Bucketing and feature decisions that find no answer (no data, not enough
  # data, no variation decided) return a +Sentinel+ singleton rather than raising
  # or returning a bare +nil+. This is architecture Decision 2: misses are
  # signaled by value, never by exception.
  #
  # The protocol a +Sentinel+ implements:
  #
  # * +#to_s+   — the byte-identical JS wire string (appears in payloads/logs).
  # * +#key+    — always +nil+, so the documented integrator pattern
  #   +case variation&.key+ falls through to the +else+ branch on a miss.
  # * +#error?+ — always +true+, the value-object discriminator that distinguishes
  #   a sentinel from a real {BucketedVariation}/{BucketedFeature} (both +false+).
  #
  # Sentinels are exposed as frozen singleton constants (e.g.
  # {RuleError::NO_DATA_FOUND}), so callers can branch on object identity for
  # granular handling:
  #
  #   result = context.run_experience("homepage-test")
  #   case result.key
  #   when nil
  #     # a miss — inspect which one via identity
  #     show_default if result.equal?(ConvertSdk::RuleError::NO_DATA_FOUND)
  #   else
  #     render_variation(result.key)
  #   end
  #
  # Equality is intentionally left as default object identity (no +==+ override):
  # two distinct +Sentinel+ instances built from the same wire string are NOT
  # equal, which is why the canonical instances live as shared frozen constants.
  class Sentinel
    # @param wire_string [String] the JS-parity wire string this sentinel emits.
    def initialize(wire_string)
      @wire_string = wire_string.dup.freeze
      freeze
    end

    # @return [String] the byte-identical JS wire string.
    def to_s
      @wire_string
    end

    # @return [nil] always nil, so +case variation&.key+ falls through to else.
    def key
      nil
    end

    # @return [Boolean] always true — a sentinel always signals a business miss.
    def error?
      true
    end
  end
end
