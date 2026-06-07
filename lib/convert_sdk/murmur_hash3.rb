# frozen_string_literal: true

module ConvertSdk
  # Vendored pure-Ruby MurmurHash3 (x86 32-bit variant).
  #
  # This is the cross-SDK hashing cornerstone: bucketing computes
  # +MurmurHash3.hash(experienceId + visitorId, 9999)+ and MUST produce a
  # byte-identical result to every other Convert SDK (JS, PHP), or a visitor
  # would bucket into a different variation on Ruby than on web. The 75-vector
  # parity suite (+spec/cross_sdk/hash_vectors_spec.rb+) is the proof.
  #
  # Implemented as pure Ruby with explicit 32-bit masking — no C extension and
  # no gemspec dependency, so it is JRuby-compatible by construction. Ruby
  # integers are arbitrary-precision; the +& MASK_32+ on every arithmetic step
  # is the correctness boundary that emulates 32-bit unsigned overflow.
  #
  # Reference: Austin Appleby's MurmurHash3_x86_32 (public domain).
  # https://github.com/aappleby/smhasher/blob/master/src/MurmurHash3.cpp
  module MurmurHash3
    # 32-bit overflow mask — applied after every multiply/add/shift.
    MASK_32 = 0xFFFFFFFF

    # Canonical MurmurHash3_x86_32 mixing constants.
    C1 = 0xcc9e2d51
    C2 = 0x1b873593
    # Body block mixing: rotl(h1, ROT_H) * M + N
    M = 5
    N = 0xe6546b64
    R1 = 15 # k1 rotate-left before * C2
    R2 = 13 # h1 rotate-left in the body mix

    # Finalization mix (fmix32) constants.
    FMIX_C1 = 0x85ebca6b
    FMIX_C2 = 0xc2b2ae35

    # Compute the MurmurHash3 x86 32-bit hash of +key+ with +seed+.
    #
    # @param key [String] the key; hashed over its UTF-8 byte sequence.
    # @param seed [Integer] the 32-bit seed.
    # @return [Integer] unsigned 32-bit hash value in the range 0..0xFFFFFFFF.
    def self.hash(key, seed)
      data = key.b # raw bytes (ASCII-8BIT view); UTF-8 multi-byte chars hash over their bytes
      length = data.bytesize
      h1 = seed & MASK_32

      h1 = mix_body(data, length, h1)
      h1 = mix_tail(data, length, h1)

      # Finalization: fold in the length, then avalanche.
      fmix32(h1 ^ length)
    end

    # Process all full 4-byte little-endian body blocks.
    def self.mix_body(data, length, h1)
      block_count = length / 4
      block_count.times do |block|
        i = block * 4
        k1 = read_u32_le(data, i)
        h1 ^= mix_k1(k1)
        h1 = ((rotl32(h1, R2) * M) + N) & MASK_32
      end
      h1
    end
    private_class_method :mix_body

    # Process the trailing 1..3 bytes (the tail) in little-endian order.
    def self.mix_tail(data, length, h1)
      tail_start = (length / 4) * 4
      remaining = length & 3
      return h1 if remaining.zero?

      k1 = 0
      k1 |= byte_at(data, tail_start + 2) << 16 if remaining >= 3
      k1 |= byte_at(data, tail_start + 1) << 8 if remaining >= 2
      k1 |= byte_at(data, tail_start) # remaining >= 1
      h1 ^ mix_k1(k1)
    end
    private_class_method :mix_tail

    # The shared k1 scramble: k1 * C1, rotl R1, * C2.
    def self.mix_k1(k1)
      k1 = (k1 * C1) & MASK_32
      k1 = rotl32(k1, R1)
      (k1 * C2) & MASK_32
    end
    private_class_method :mix_k1

    # Read a 32-bit little-endian word at byte offset +index+.
    def self.read_u32_le(data, index)
      byte_at(data, index) |
        (byte_at(data, index + 1) << 8) |
        (byte_at(data, index + 2) << 16) |
        (byte_at(data, index + 3) << 24)
    end
    private_class_method :read_u32_le

    # Read one byte as a guaranteed Integer. Every call site has already bounds-
    # checked the index, so a nil here would be a genuine bug — surface it.
    def self.byte_at(data, index)
      Integer(data.getbyte(index))
    end
    private_class_method :byte_at

    # 32-bit left rotate.
    def self.rotl32(value, shift)
      value &= MASK_32
      ((value << shift) | (value >> (32 - shift))) & MASK_32
    end
    private_class_method :rotl32

    # fmix32 avalanche finalizer.
    def self.fmix32(hash)
      hash &= MASK_32
      hash ^= hash >> 16
      hash = (hash * FMIX_C1) & MASK_32
      hash ^= hash >> 13
      hash = (hash * FMIX_C2) & MASK_32
      hash ^ (hash >> 16)
    end
    private_class_method :fmix32
  end
end
