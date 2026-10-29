# frozen_string_literal: true


require 'securerandom'

# W3C Trace Context propagation, with no dependencies.
#
# Two entry points matter: `KitOtel.server_hop` for the inbound side and
# `ServerHop#outbound_headers` for the outbound one. Both cannot fail — a
# malformed or absent `traceparent` yields a new trace, because a request is
# not an error because its trace header was garbage (3.2.2.3, 4.2).
#
# See the file header for the W3C Trace Context sections behind each rule, and
# `test_traceparent.rb` for the suite that asserts them.
module KitOtel
  RUBY_FLOOR = '2.7'

  SAMPLED = 0x01

  MIN_HEADER_LEN = 55

  TRACESTATE_LIMIT = 512

  TRACESTATE_ENTRY_LIMIT = 128

  ZERO_TRACE_ID = '0' * 32
  ZERO_SPAN_ID = '0' * 16

  TraceParent = Struct.new(:version, :trace_id, :parent_id, :flags, :extra) do
    # The caller's recording decision (3.2.2.5.1). We carry this rather than
    # making our own: a service that re-decides sampling per hop produces traces
    # with holes in them, which are worse than no traces.
    #
    # `sampled?` is the real method, because that is the Ruby spelling.
    # `sampled` is an alias so the predicate reads the same here as in the other
    # five templates — a cross-language suite that has to remember which language
    # suffixes its booleans is a suite nobody maintains. Both exist; neither is
    # deprecated.
    def sampled?
      flags.allbits?(SAMPLED)
    end
    alias_method :sampled, :sampled?
  end

  ServerHop = Struct.new(:trace_id, :span_id, :flags, :tracestate, :continued) do
    def sampled?
      flags.allbits?(SAMPLED)
    end
    alias_method :sampled, :sampled?

    # The shape is fixed by 3.4: parent-id becomes this hop's span id, and the
    # version is downgraded to the one we implement. Those two mutations plus
    # the sampled flag are the entire allowed set.
    def outbound_headers
      out = { 'traceparent' => KitOtel.format_traceparent(trace_id, span_id, flags) }
      out['tracestate'] = tracestate unless tracestate.to_s.empty?
      out
    end
  end

  class << self
    # Parse a `traceparent` header value.
    #
    # Returns nil for anything invalid, and that is the whole contract:
    # 3.2.2.3 and 3.2.2.4 say a vendor MUST ignore the header when trace-id or
    # parent-id is invalid, and 3.2.4 says to restart the trace when the version
    # cannot be parsed. There is no error to handle and no value to partially
    # trust.
    # Split into one predicate per spec rule rather than one long guard chain.
    #
    # The single-method version was correct and unreadable: a 36-ABC, 17-branch
    # method where a reviewer cannot see which rule rejects a header without
    # reading all of it. Each check below is named after the section that
    # requires it, so `parse_traceparent` reads as a list of rules — which is
    # what it is — and a change to one rule is a change to one method.
    #
    # Every one of these returns true when the header is REJECTED. Naming them
    # that way keeps the caller a single readable conjunction.
    def parse_traceparent(value)
      return nil if value.nil?

      raw = value.to_s
      return nil unless well_formed?(raw)
      return nil if all_zero_identifier?(raw)

      build_traceparent(raw)
    end

    # 3.2.4: "When the version prefix cannot be parsed ... the implementation
    # should restart the trace." Everything the spec requires of the header's
    # SHAPE, in the order it states them. A well-formed header is one a vendor
    # can parse positionally; an all-zero identifier is well formed and still
    # invalid, which is why that check is not in here.
    def well_formed?(raw)
      !malformed_version_prefix?(raw) &&
        !forbidden_version?(raw) &&
        !wrong_delimiters?(raw) &&
        !non_hex_fields?(raw) &&
        !wrong_length_for_version?(raw)
    end

    # The five fixed slices of a header that has already been validated. Kept out
    # of `parse_traceparent` so that method is a list of rules and this one is a
    # list of offsets — two things a reader can hold in their head, rather than
    # both at once.
    def build_traceparent(raw)
      TraceParent.new(
      )
    end

    # A short header cannot hold the four fields, whatever the version.
    # 3.2.4: "When the version prefix cannot be parsed (it's not 2 hex characters
    # followed by a dash), the implementation should restart the trace." Checked
    # before anything else, so a malformed version is never mistaken for a valid
    # one.
    def malformed_version_prefix?(raw)
      raw.length < MIN_HEADER_LEN || raw[2] != '-' || !lowercase_hex?(raw[0, 2])
    end

    # 3.2.2.1: "Version ff is invalid."
    def forbidden_version?(raw)
      raw[0, 2].to_i(16) == 0xFF
    end

    # The three fixed positions, all three mandatory (3.2.4).
    def wrong_delimiters?(raw)
      raw[35] != '-' || raw[52] != '-'
    end

    # 3.2.2 defines the alphabet as HEXDIGLC, lowercase only.
    def non_hex_fields?(raw)
      [raw[3, 32], raw[36, 16], raw[53, 2]].any? { |field| !lowercase_hex?(field) }
    end

    # 3.2.2.2 defines version 00 as exactly these four fields. Trailing data
    # means the sender is not speaking version 00, and accepting it would be
    # inventing a format the spec does not define.
    #
    # 3.2.4: on a higher version the two flag characters are followed by either
    # the end of the header or a dash introducing an unknown field.
    def wrong_length_for_version?(raw)
      version = raw[0, 2].to_i(16)
      if version.zero?
        raw.length != MIN_HEADER_LEN
      elsif raw.length > MIN_HEADER_LEN
        raw[MIN_HEADER_LEN] != '-'
      else
        false
      end
    end

    # 3.2.2.3 and 3.2.2.4: all zeroes is an invalid value for both identifiers,
    # and the required response is to ignore the header.
    def all_zero_identifier?(raw)
      raw[3, 32] == ZERO_TRACE_ID || raw[36, 16] == ZERO_SPAN_ID
    end

    # Continue the trace described by the inbound headers.
    #
    # This is the one function a service's middleware calls. It cannot fail: a
    # malformed or absent traceparent yields a new trace, because a request is
    # not an error because its trace header was garbage (4.2, 3.2.2.3).
    #
    # +span_id+ is a parameter rather than generated here so the caller owns the
    # span lifecycle — in a service it comes from the tracer, in a test it is a
    # constant, which is why the suite can assert equality instead of a shape.
    def server_hop(headers, span_id)
      tp = parse_traceparent(header(headers, 'traceparent'))

      if tp.nil?
        return ServerHop.new(new_trace_id, span_id, 0, nil, false)
      end

      ServerHop.new(
        tp.trace_id,
        span_id,
        tp.flags & SAMPLED,
        forward_tracestate(header(headers, 'tracestate')),
        true
      )
    end

    # Build a traceparent at version 00.
    #
    # Always version 00, always lowercase hex, always exactly 55 characters
    # (3.2.2.2). It takes no version parameter on purpose: a service speaks one
    # version, and a caller that could pass any version would eventually pass a
    # wrong one.
    def format_traceparent(trace_id, parent_id, flags)
      format('00-%<trace>s-%<parent>s-%<flags>02x', trace: trace_id, parent: parent_id, flags: flags & 0xFF)
    end

    # Apply the 3.3.1.5 limits to an inbound tracestate.
    #
    # The order matters and is the order the spec states: oversized entries go
    # first (they are the expensive ones and the least likely to be a
    # well-known vendor key), then entries are dropped from the end. Dropping
    # from the front would discard the most recent vendor's entry, which is the
    # one that just wrote it and the one that knows where the trace currently is.
    def forward_tracestate(value)
      return nil if value.nil? || value.empty?

      entries = usable_tracestate_entries(value)
      entries.pop while entries.length.positive? && entries.join(',').length > TRACESTATE_LIMIT

      entries.empty? ? nil : entries.join(',')
    end

    # The entries that survive 3.3.1.1 and the 3.3.1.5 per-entry limit, in the
    # order they arrived. Extracted so `forward_tracestate` reads as the two
    # rules it implements rather than as one loop with a nested filter.
    def usable_tracestate_entries(value)
      value.split(',', -1).filter_map do |raw|
        entry = raw.strip
        next if entry.empty?

        entry.length > TRACESTATE_ENTRY_LIMIT ? nil : entry
      end
    end

    # Look a header up case-insensitively.
    #
    # 3.2.1: "Vendors MUST expect the header name in any case (upper, lower,
    # mixed)". Rack gives us Title-Case, but a test, a proxy, or a middleware
    # that copies raw keys will not, and being strict here breaks traces in
    # production for no reason.
    def header(headers, name)
      return nil unless headers.respond_to?(:each_pair)

      pair = headers.find { |key, _| key.to_s.casecmp?(name) }
      pair&.last
    end

    # A fresh 16-byte trace identifier as 32 hex characters.
    #
    # 8: 16 bytes from a cryptographically secure source, never all zeroes.
    def new_trace_id
      random_hex(16)
    end

    # A fresh 8-byte span identifier as 16 hex characters.
    #
    # 8. On all-zero failure it returns a fixed non-zero constant rather than
    # raising: an exhausted entropy source is not a reason to take the service
    # down, and 3.2.2.4 only requires that the value is not all zeroes. The
    # collision risk is theoretical; the availability risk is not.
    def new_span_id
      id = random_hex(8)
      id == ZERO_SPAN_ID ? '0000000000000001' : id
    end

    private

    # Whether +str+ is entirely lowercase hex. 3.2.2 defines the alphabet as
    # HEXDIGLC, lowercase only. Uppercase is rejected rather than folded:
    # accepting it means two services disagree about whether a header is valid,
    # and one of them starts a new trace.
    def lowercase_hex?(str)
      !str.empty? && str.match?(/\A[0-9a-f]+\z/)
    end

    # +byte_count+ bytes from SecureRandom as lowercase hex.
    #
    # SecureRandom rather than Random: trace ids end up in logs and in traces
    # that leave the process, and a predictable trace id is an invitation to
    # correlate two users' requests by guessing.
    def random_hex(byte_count)
      SecureRandom.hex(byte_count)
    end
  end
end
