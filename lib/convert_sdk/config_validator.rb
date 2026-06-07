# frozen_string_literal: true

module ConvertSdk
  # The fail-fast validation rules for {Config} — the SDK's only raising surface.
  #
  # +ConfigValidator+ holds every presence/type rule for the configuration
  # surface, extracted from {Config} so the surface class stays focused on
  # naming-world translation and typed readers while the (uniform, table-like)
  # validation rules live in one cohesive place. Every violation raises a stdlib
  # +ArgumentError+ naming the offending option and the expected type; there is
  # no custom exception hierarchy anywhere in the SDK (Decision 3).
  #
  # Rules:
  #
  # * presence — at least one of +sdk_key+ / +data+ must be present (FR6);
  # * strings — +sdk_key+ / +sdk_key_secret+ / +environment+ / +config_endpoint+
  #   / +track_endpoint+ / +negation+ must be String (nil accepted for the
  #   optional ones); +data+ must be a Hash when present;
  # * integers — +max_traffic+ / +hash_seed+ / +event_batch_size+;
  # * intervals — +data_refresh_interval+ / +flush_interval+ are Numeric or nil
  #   (nil = timer-off); +open_timeout+ / +read_timeout+ are Numeric;
  # * booleans — +keys_case_sensitive+ / +tracking+ (strict true/false);
  # * log level — must be one of the {LogLevel} values.
  class ConfigValidator
    # The accepted {LogLevel} integer values (TRACE..SILENT).
    LOG_LEVEL_VALUES = [
      LogLevel::TRACE, LogLevel::DEBUG, LogLevel::INFO,
      LogLevel::WARN, LogLevel::ERROR, LogLevel::SILENT
    ].freeze

    # @param values [Hash{Symbol=>Object}] the merged option values, keyed by the
    #   public snake_case option names (the {Config::DEFAULTS} keys).
    def initialize(values)
      @values = values
    end

    # Run every rule. The first violation raises; presence is checked first so a
    # wholly-empty config reports the most useful fault.
    #
    # @raise [ArgumentError] on any presence/type violation.
    # @return [void]
    def validate!
      validate_presence!
      validate_strings!
      validate_integers!
      validate_intervals!
      validate_booleans!
      validate_log_level!
    end

    private

    # At least one of sdk_key / data must be present (FR6).
    def validate_presence!
      return unless @values[:sdk_key].nil? && @values[:data].nil?

      raise ArgumentError, "configuration requires sdk_key or data (at least one)"
    end

    # String-or-nil options, plus the Hash-or-nil data option.
    def validate_strings!
      %i[sdk_key sdk_key_secret environment config_endpoint track_endpoint negation].each do |name|
        require_string(name, @values[name])
      end
      require_type(:data, @values[:data], Hash) unless @values[:data].nil?
    end

    # Integer options (bucketing constants and batch size).
    def validate_integers!
      %i[max_traffic hash_seed event_batch_size].each do |name|
        require_type(name, @values[name], Integer)
      end
    end

    # Timer intervals (Numeric or nil = timer-off) and HTTP timeouts (Numeric).
    def validate_intervals!
      require_interval(:data_refresh_interval, @values[:data_refresh_interval])
      require_interval(:flush_interval, @values[:flush_interval])
      require_type(:open_timeout, @values[:open_timeout], Numeric)
      require_type(:read_timeout, @values[:read_timeout], Numeric)
    end

    # Strict boolean flags.
    def validate_booleans!
      %i[keys_case_sensitive tracking].each do |name|
        require_boolean(name, @values[name])
      end
    end

    # log_level must be one of the {LogLevel} values.
    def validate_log_level!
      level = @values[:log_level]
      return if LOG_LEVEL_VALUES.include?(level)

      raise ArgumentError,
            "log_level must be a LogLevel value (#{LOG_LEVEL_VALUES.join(", ")}), got #{level.inspect}"
    end

    # Require String-or-nil (nil acceptable for optional strings).
    def require_string(name, value)
      return if value.nil? || value.is_a?(String)

      raise ArgumentError, "#{name} must be a String, got #{value.class}"
    end

    # Require a Numeric-or-nil timer interval; nil means timer-off.
    def require_interval(name, value)
      return if value.nil? || value.is_a?(Numeric)

      raise ArgumentError, "#{name} must be a Numeric (seconds) or nil (timer-off), got #{value.class}"
    end

    # Require +value+ to be an instance of +type+.
    def require_type(name, value, type)
      return if value.is_a?(type)

      raise ArgumentError, "#{name} must be a #{type}, got #{value.class}"
    end

    # Require a strict boolean (true / false), never truthy coercion.
    def require_boolean(name, value)
      return if [true, false].include?(value)

      raise ArgumentError, "#{name} must be a boolean (true/false), got #{value.class}"
    end
  end
end
