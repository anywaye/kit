
ExUnit.start()

defmodule KitOtel.TraceparentTest do
  use ExUnit.Case, async: true

  @known_header "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
  @known_trace "4bf92f3577b34da6a3ce929d0e0e4736"
  @known_parent "00f067aa0ba902b7"
  @fixed_span "1111111111111111"

  defp headers(pairs), do: Map.new(pairs)

  defp hop(pairs, span \\ @fixed_span) do
    KitOtel.Traceparent.server_hop(headers(pairs), span)
  end

  defp sampled(%{flags: flags}), do: Bitwise.band(flags, 0x01) == 0x01
  defp outbound(%{} = hop), do: KitOtel.Traceparent.ServerHop.outbound_headers(hop)

  test "known traceparent is continued" do
    hop = hop(%{"traceparent" => @known_header})

    assert hop.trace_id == @known_trace
    assert hop.continued, "a valid inbound traceparent must be continued, not restarted"
    assert hop.span_id == @fixed_span
    refute hop.span_id == @known_parent, "span id must not be the inbound parent-id"
    assert sampled(hop), "sampled flag (§3.2.2.5.1) must survive the hop"

    out = outbound(hop)
    {:ok, tp} = KitOtel.Traceparent.parse(out["traceparent"])

    assert tp.trace_id == @known_trace
    assert tp.parent_id == @fixed_span, "outbound parent-id is this hop's span id"
    assert sampled(tp), "outbound trace-flags lost the sampled bit"
    assert tp.version == 0, "we emit the version we implement"
  end

  test "unsampled flag is preserved" do
    hop = hop(%{"traceparent" => "00-#{@known_trace}-#{@known_parent}-00"})

    refute sampled(hop), "sampled flag must not be invented on an unsampled trace"
    assert hop.trace_id == @known_trace
    assert String.ends_with?(outbound(hop)["traceparent"], "-00")
  end

  test "second hop keeps the same trace id" do
    first = hop(%{"traceparent" => @known_header}, "2222222222222222")
    second = KitOtel.Traceparent.server_hop(outbound(first), "3333333333333333")

    assert second.trace_id == @known_trace, "trace broken across hops"
    assert second.continued, "a traceparent we just emitted must parse on the way back in"
  end

  test "malformed traceparent starts a new trace" do
    bad = [
      empty: "",
      not_a_header: "garbage",
      truncated_at_54: "00-#{@known_trace}-#{@known_parent}",
      version_00_plus_junk: "#{@known_header}-extra",
      all_zero_trace_id: "00-#{String.duplicate("0", 32)}-#{@known_parent}-01",
      all_zero_parent_id: "00-#{@known_trace}-#{String.duplicate("0", 16)}-01",
      uppercase_hex: "00-4BF92F3577B34DA6A3CE929D0E0E4736-#{@known_parent}-01",
      forbidden_version_ff: "ff-#{@known_trace}-#{@known_parent}-01",
      one_char_version: "0-#{@known_trace}-#{@known_parent}-01",
      wrong_delimiters: "00_#{@known_trace}_#{@known_parent}_01",
      non_hex_flags: "00-#{@known_trace}-#{@known_parent}-0g"
    ]

    for {name, value} <- bad do
      hop = hop(%{"traceparent" => value})

      refute hop.continued, "#{name}: #{inspect(value)} was accepted as a valid traceparent"
      refute hop.trace_id == @known_trace, "#{name}: an invalid traceparent contributed its trace-id"
      assert String.length(hop.trace_id) == 32, "#{name}"
      refute hop.trace_id == String.duplicate("0", 32), "#{name}: trace-id must not be all zeroes (§3.2.2.3)"
      assert {:ok, _} = KitOtel.Traceparent.parse(outbound(hop)["traceparent"]),
             "#{name}: the restarted trace must be valid on the way out"
    end
  end

  test "missing traceparent starts a new trace" do
    hop = hop(%{})

    refute hop.continued
    assert String.length(hop.trace_id) == 32
    refute hop.trace_id == String.duplicate("0", 32)
    refute sampled(hop), "a trace we started defaults to not-sampled (§3.2.2.5.1)"
  end

  test "tracestate is forwarded" do
    hop = hop(%{"traceparent" => @known_header, "tracestate" => "congo=t61rcWkgMzE"})

    assert outbound(hop)["tracestate"] == "congo=t61rcWkgMzE"
  end

  test "tracestate is truncated at whole entries" do
    entries =
      for i <- 0..59 do
        "v#{String.pad_leading(Integer.to_string(i), 2, "0")}=#{String.duplicate("x", 30)}"
      end

    long = Enum.join(entries, ",")
    hop = hop(%{"traceparent" => @known_header, "tracestate" => long})
    out = outbound(hop)["tracestate"]

    assert String.length(out) <= 512, "§3.3.1.5 caps a combined header at 512"
    assert out != "", "truncating dropped the whole header"

    for entry <- String.split(out, ",") do
      assert String.contains?(long, entry), "entry #{entry} was truncated mid-entry"
    end

    assert String.starts_with?(out, hd(entries)), "§3.3.1.5 drops entries from the end"
  end

  test "oversized tracestate entries are removed first" do
    oversized = "huge=#{String.duplicate("y", 200)}"
    hop = hop(%{"traceparent" => @known_header, "tracestate" => "#{oversized},small=1"})
    out = outbound(hop)["tracestate"]

    refute String.contains?(out, "huge="), "an entry over 128 characters is removed first"
    assert out == "small=1"
  end

  test "tracestate without a valid traceparent is discarded" do
    for value <- ["", "not-a-traceparent"] do
      hop = hop(%{"traceparent" => value, "tracestate" => "congo=t61rcWkgMzE"})

      refute Map.has_key?(outbound(hop), "tracestate"),
             "tracestate must be discarded when traceparent is #{inspect(value)}"
    end
  end

  test "header names are case insensitive and sent lowercase" do
    for name <- ["traceparent", "TraceParent", "TRACEPARENT", "Traceparent"] do
      hop = hop(%{name => @known_header})
      assert hop.trace_id == @known_trace, "header #{name} was not recognised"
    end

    out = outbound(hop(%{"TraceParent" => @known_header}))

    for name <- Map.keys(out) do
      assert name == String.downcase(name), "§3.2.1: send #{name} lowercase"
    end
  end

  test "higher version is downgraded and unknown fields are not forwarded" do
    future = "cc-#{@known_trace}-#{@known_parent}-01-what-the-future-wants"
    assert {:ok, tp} = KitOtel.Traceparent.parse(future)

    assert tp.version == 0xCC
    assert tp.trace_id == @known_trace
    assert tp.parent_id == @known_parent

    out = outbound(hop(%{"traceparent" => future}))["traceparent"]

    assert String.starts_with?(out, "00-"), "outbound #{out} must be downgraded to version 00"

    refute String.contains?(out, "what-the-future-wants"),
           "§3.2.4: MUST NOT forward unknown fields"
  end

  test "trace flags are a bit field" do
    hop = hop(%{"traceparent" => "00-#{@known_trace}-#{@known_parent}-03"})

    assert sampled(hop), "bit 0 set means sampled; reading flags as a number is the classic bug"
    assert String.ends_with?(outbound(hop)["traceparent"], "-01"),
           "reserved bits must be zeroed on the way out (§3.2.2.5.2)"
  end

  test "new identifiers are random and never all zero" do
    {_traces, spans} =
      Enum.reduce(1..256, {MapSet.new(), MapSet.new()}, fn _i, {traces, spans} ->
        trace_id = KitOtel.Traceparent.new_trace_id()
        span_id = KitOtel.Traceparent.new_span_id()

        assert String.length(trace_id) == 32
        assert String.length(span_id) == 16
        refute trace_id == String.duplicate("0", 32)
        refute span_id == String.duplicate("0", 16)

        refute MapSet.member?(traces, trace_id),
               "new_trace_id repeated #{trace_id} in 256 draws (§8.2)"

        refute MapSet.member?(spans, span_id),
               "new_span_id repeated #{span_id} in 256 draws (§8.2)"

        {MapSet.put(traces, trace_id), MapSet.put(spans, span_id)}
      end)

    assert MapSet.size(_traces) == 256
    assert MapSet.size(spans) == 256
  end
end
