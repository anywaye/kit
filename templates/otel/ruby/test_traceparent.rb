# frozen_string_literal: true


require 'minitest/autorun'
require_relative 'traceparent'

# The W3C Trace Context conformance suite for `KitOtel`.
#
# The suite is the contract: it proves the template still continues a trace
# instead of quietly restarting it. Every assertion cites the section of
# https://www.w3.org/TR/trace-context/ that requires it.
#
# Runs on a bare `ruby` — no `bundle install`, no Gemfile, no network. If that
# ever stops being true, this template has grown a dependency. "Bare" means no
# gems; it does not mean any interpreter. The floor is KitOtel::RUBY_FLOOR —
# 2.7, for `filter_map` — and a run on anything older is a toolchain mistake
# wearing this suite's clothes, not a finding about trace propagation.
class TestTraceparent < Minitest::Test
  KNOWN_HEADER  = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'
  KNOWN_TRACE   = '4bf92f3577b34da6a3ce929d0e0e4736'
  KNOWN_PARENT  = '00f067aa0ba902b7'
  FIXED_SPAN    = '1111111111111111'

  # The headline promise: a known traceparent comes out the other side with its
  # trace identity intact and a fresh span id. §3.4 "Update parent-id" is the
  # most typical mutation and is the only one we perform.
  def test_known_traceparent_is_continued
    hop = KitOtel.server_hop({ 'traceparent' => KNOWN_HEADER }, FIXED_SPAN)

    assert_equal KNOWN_TRACE, hop.trace_id
    assert hop.continued, 'a valid inbound traceparent must be continued, not restarted'
    assert_equal FIXED_SPAN, hop.span_id
    refute_equal KNOWN_PARENT, hop.span_id, 'span id must not be the inbound parent-id'
    assert hop.sampled, 'sampled flag (§3.2.2.5.1) must survive the hop'

    out = hop.outbound_headers
    tp = KitOtel.parse_traceparent(out['traceparent'])
    refute_nil tp, "outbound traceparent #{out['traceparent'].inspect} did not parse"
    assert_equal KNOWN_TRACE, tp.trace_id
    assert_equal FIXED_SPAN, tp.parent_id, "outbound parent-id is this hop's span id"
    assert tp.sampled, 'outbound trace-flags lost the sampled bit'
    assert_equal 0, tp.version, 'we emit the version we implement'
  end

  # §3.2.2.5.1: sampled is a recommendation, not a rule, so it is carried and
  # never second-guessed here.
  def test_unsampled_flag_is_preserved
    unsampled = "00-#{KNOWN_TRACE}-#{KNOWN_PARENT}-00"
    hop = KitOtel.server_hop({ 'traceparent' => unsampled }, FIXED_SPAN)

    refute hop.sampled, 'sampled flag must not be invented on an unsampled trace'
    assert_equal KNOWN_TRACE, hop.trace_id
    assert hop.outbound_headers['traceparent'].end_with?('-00')
  end

  # Three services, one trace: hop N+1 must keep the trace-id hop N produced.
  def test_second_hop_keeps_the_same_trace_id
    first  = KitOtel.server_hop({ 'traceparent' => KNOWN_HEADER }, '2222222222222222')
    second = KitOtel.server_hop(first.outbound_headers, '3333333333333333')

    assert_equal KNOWN_TRACE, second.trace_id, 'trace broken across hops'
    assert second.continued, 'a traceparent this service just emitted must parse on the way back in'
  end

  BAD_HEADERS = {
    'empty' => '',
    'not a header' => 'garbage',
    'truncated at 54' => "00-#{KNOWN_TRACE}-#{KNOWN_PARENT}",
    'version 00 plus junk' => "#{KNOWN_HEADER}-extra",
    'all-zero trace-id' => "00-00000000000000000000000000000000-#{KNOWN_PARENT}-01",
    'all-zero parent-id' => "00-#{KNOWN_TRACE}-0000000000000000-01",
    'uppercase hex' => "00-4BF92F3577B34DA6A3CE929D0E0E4736-#{KNOWN_PARENT}-01",
    'forbidden version ff' => "ff-#{KNOWN_TRACE}-#{KNOWN_PARENT}-01",
    'one-char version' => "0-#{KNOWN_TRACE}-#{KNOWN_PARENT}-01",
    'wrong delimiters' => "00_#{KNOWN_TRACE}_#{KNOWN_PARENT}_01",
    'non-hex flags' => "00-#{KNOWN_TRACE}-#{KNOWN_PARENT}-0g"
  }.freeze

  def test_malformed_traceparent_starts_a_new_trace
    BAD_HEADERS.each_value do |value|
      hop = KitOtel.server_hop({ 'traceparent' => value }, FIXED_SPAN)

      refute hop.continued, "#{value.inspect} was accepted as a valid traceparent"
      refute_equal KNOWN_TRACE, hop.trace_id, 'an invalid traceparent must not contribute its trace-id'
      assert_equal 32, hop.trace_id.length
      refute_equal '0' * 32, hop.trace_id, 'restarted trace-id must not be all zeroes (§3.2.2.3)'
      refute_nil KitOtel.parse_traceparent(hop.outbound_headers['traceparent']),
                 'the restarted trace must be valid on the way out'
    end
  end

  def test_missing_traceparent_starts_a_new_trace
    hop = KitOtel.server_hop({}, FIXED_SPAN)

    refute hop.continued, 'no inbound traceparent means a new trace (§4.2)'
    assert_equal 32, hop.trace_id.length
    refute_equal '0' * 32, hop.trace_id
    refute hop.sampled, 'a trace this service started defaults to not-sampled (§3.2.2.5.1)'
  end

  # §3.3: tracestate is opaque to us and MUST travel with the trace.
  def test_tracestate_is_forwarded
    hop = KitOtel.server_hop(
      { 'traceparent' => KNOWN_HEADER, 'tracestate' => 'congo=t61rcWkgMzE' },
      FIXED_SPAN
    )

    assert_equal 'congo=t61rcWkgMzE', hop.outbound_headers['tracestate']
  end

  # §3.3.1.5: propagate at least 512 characters, and when it does not fit,
  # truncate whole entries — never a half entry.
  def test_tracestate_is_truncated_at_whole_entries
    entries = 60.times.map do |i|
      key = format('v%02d', i)
      "#{key}=#{'x' * 30}"
    end
    long = entries.join(',')

    hop = KitOtel.server_hop(
      { 'traceparent' => KNOWN_HEADER, 'tracestate' => long },
      FIXED_SPAN
    )

    out = hop.outbound_headers['tracestate']
    assert_operator out.length, :<=, 512, '§3.3.1.5 caps a combined header at 512'
    refute_empty out, 'truncating dropped the whole header'
    out.split(',').each do |entry|
      assert_includes long, entry, "entry #{entry.inspect} was truncated mid-entry"
    end
    assert out.start_with?(entries.first), '§3.3.1.5 drops entries from the end'
  end

  # §3.3.1.5: "Entries larger than 128 characters long SHOULD be removed first."
  def test_oversized_tracestate_entries_are_removed_first
    oversized = "huge=#{'y' * 200}"
    hop = KitOtel.server_hop(
      { 'traceparent' => KNOWN_HEADER, 'tracestate' => "#{oversized},small=1" },
      FIXED_SPAN
    )

    out = hop.outbound_headers['tracestate']
    refute_includes out, 'huge=', 'an entry over 128 characters is removed first'
    assert_equal 'small=1', out
  end

  # §3.3 and §4.2: a tracestate without a valid traceparent is invalid and MUST
  # be discarded — forwarding it would attach vendor state to an unrelated trace.
  def test_tracestate_without_a_valid_traceparent_is_discarded
    ['', 'not-a-traceparent'].each do |tp|
      hop = KitOtel.server_hop(
        { 'traceparent' => tp, 'tracestate' => 'congo=t61rcWkgMzE' },
        FIXED_SPAN
      )

      refute hop.outbound_headers.key?('tracestate'),
             'tracestate must be discarded when there is no valid traceparent'
    end
  end

  # §3.2.1: vendors MUST expect the header name in any case and SHOULD send it
  # lowercase. Proxies and SDKs are inconsistent about this.
  def test_header_names_are_case_insensitive_and_sent_lowercase
    %w[traceparent TraceParent TRACEPARENT Traceparent].each do |name|
      hop = KitOtel.server_hop({ name => KNOWN_HEADER }, FIXED_SPAN)
      assert_equal KNOWN_TRACE, hop.trace_id, "header #{name} was not recognised"
    end

    out = KitOtel.server_hop({ 'TraceParent' => KNOWN_HEADER }, FIXED_SPAN).outbound_headers
    out.each_key do |name|
      assert_equal name.downcase, name, '§3.2.1: vendors SHOULD send the header name lowercase'
    end
  end

  # §3.2.4: a higher version is parsed positionally, and unknown fields are
  # neither parsed nor forwarded — we re-emit at version 00.
  def test_higher_version_is_downgraded_and_unknown_fields_are_not_forwarded
    future = "cc-#{KNOWN_TRACE}-#{KNOWN_PARENT}-01-what-the-future-wants"

    tp = KitOtel.parse_traceparent(future)
    refute_nil tp, 'a well-formed higher version must be parsed per §3.2.4'
    assert_equal 0xcc, tp.version
    assert_equal KNOWN_TRACE, tp.trace_id
    assert_equal KNOWN_PARENT, tp.parent_id

    hop = KitOtel.server_hop({ 'traceparent' => future }, FIXED_SPAN)
    out = hop.outbound_headers['traceparent']
    assert out.start_with?('00-'), "outbound #{out} must be downgraded to version 00"
    refute_includes out, 'what-the-future-wants', '§3.2.4: MUST NOT forward unknown fields'
  end

  # §3.2.2.5: trace-flags is a bit field, so it must be masked on read and
  # rebuilt on write. §3.2.2.5.2: reserved bits MUST be set to zero.
  def test_trace_flags_are_a_bit_field
    both = "00-#{KNOWN_TRACE}-#{KNOWN_PARENT}-03"
    hop = KitOtel.server_hop({ 'traceparent' => both }, FIXED_SPAN)

    assert hop.sampled, 'bit 0 set means sampled'
    assert hop.outbound_headers['traceparent'].end_with?('-01'),
           'reserved bits must be zeroed on the way out (§3.2.2.5.2)'
  end

  # §8: trace-id and span id must be 16 and 8 random bytes, never all zeroes.
  def test_new_identifiers_are_random_and_never_all_zero
    seen = {}
    256.times do
      id = KitOtel.new_trace_id
      assert_equal 32, id.length
      refute_equal '0' * 32, id
      refute seen[id], "new_trace_id repeated #{id} in 256 draws (§8.2)"
      seen[id] = true

      span = KitOtel.new_span_id
      assert_equal 16, span.length
      refute_equal '0' * 16, span
    end
  end
end
