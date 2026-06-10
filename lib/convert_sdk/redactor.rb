# frozen_string_literal: true

module ConvertSdk
  # Masks secrets and strips URL query strings out of log messages.
  #
  # +Redactor+ is the structural guarantee behind security NFR5: it is wired
  # *inside* {LogManager} so that no call path can emit a message without first
  # passing through {#redact}. Redaction is by construction, not by discipline.
  #
  # Two transforms are applied to every message:
  #
  # * *Secret masking* — each known secret (e.g. an +sdk_key+ /
  #   +sdk_key_secret+ value) is replaced wherever it occurs with its first
  #   four characters followed by a single-character ellipsis (+abcd…+).
  #   Secrets shorter than four characters are replaced entirely (+…+).
  # * *URL query stripping* — any +http(s)+ URL has its +?query=string+ removed
  #   (+https://host/path?x=1+ becomes +https://host/path+), since query
  #   strings frequently carry tokens.
  #
  # Secrets become known at different times: some at construction, some at
  # +ConvertSdk.create+ time. {#register_secret} allows late registration so
  # the same redactor instance can be wired before all secrets are known.
  #
  # Redaction operates on *strings* — structured objects must already have
  # passed the +loggable+ conversion boundary (see {LogManager}) before
  # reaching here.
  class Redactor
    # Number of leading characters kept unmasked for a secret long enough to
    # retain a prefix. JS-parity disclosure budget.
    MASK_PREFIX_LENGTH = 4
    # The single-character ellipsis appended after the unmasked prefix (or used
    # as the whole replacement for short secrets).
    MASK_GLYPH = "…"
    # Matches an +http(s)+ URL's query string: a +?+ and everything up to the
    # next whitespace. The query is stripped; the path is kept.
    URL_QUERY_PATTERN = %r{(https?://\S*?)\?\S*}

    # @param secrets [Array<String, nil>] secret values to mask. nil/blank
    #   entries are ignored.
    def initialize(secrets = [])
      @secrets = []
      Array(secrets).each { |secret| register_secret(secret) }
    end

    # Register an additional secret to mask. Safe to call after construction
    # (e.g. once the SDK key is known at +ConvertSdk.create+ time).
    #
    # @param secret [String, nil] the secret value. nil/blank is a no-op.
    # @return [void]
    def register_secret(secret)
      return if secret.nil?

      value = secret.to_s
      return if value.strip.empty?

      @secrets << value unless @secrets.include?(value)
    end

    # Apply secret masking and URL query stripping to +message+.
    #
    # @param message [String] the message to redact.
    # @return [String] the redacted message (a new string; +message+ is not
    #   mutated).
    def redact(message)
      result = strip_url_queries(message.to_s)
      mask_secrets(result)
    end

    private

    # Replace every occurrence of every known secret with its masked form.
    # Longer secrets are masked first so a secret that is a prefix of another
    # does not partially un-mask the longer one.
    def mask_secrets(message)
      @secrets.sort_by { |secret| -secret.length }.each do |secret|
        message = message.gsub(secret, masked(secret))
      end
      message
    end

    # @return [String] +abcd…+ for secrets >= 4 chars, +…+ otherwise.
    def masked(secret)
      return MASK_GLYPH if secret.length < MASK_PREFIX_LENGTH

      "#{secret[0, MASK_PREFIX_LENGTH]}#{MASK_GLYPH}"
    end

    # Drop the query string from any URL in the message, keeping the path.
    def strip_url_queries(message)
      message.gsub(URL_QUERY_PATTERN, '\1')
    end
  end
end
