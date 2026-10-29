
defmodule KitOtel.Traceparent do
  @moduledoc """
  W3C Trace Context propagation, with no dependencies.

  Two functions matter: `server_hop/2` for the inbound side and
  `ServerHop.outbound_headers/1` for the outbound one. See the module docs in
  the file header for the spec sections behind each rule.
  """

  @sampled 0x01

  @min_header_len 55

  @tracestate_limit 512

  @tracestate_entry_limit 128

  @zero_trace_id String.duplicate("0", 32)
  @zero_span_id String.duplicate("0", 16)

  defmodule TraceParent do
    @moduledoc """
    A parsed `traceparent` header.

    `:version` is the raw version byte: zero for version `00`, the only version
    we emit; a higher version is parsed (§3.2.4) and then downgraded. `:extra`
    is everything after the flags field on a higher-version header, retained for
    logging only — §3.2.4 says vendors MUST NOT forward unknown fields, and
    `outbound_headers/1` does not.
    """

    @enforce_keys [:trace_id, :parent_id, :flags]
    defstruct [:version, :trace_id, :parent_id, :flags, extra: ""]

    @type t :: %__MODULE__{
            version: non_neg_integer | nil,
            trace_id: binary(),
            parent_id: binary(),
            flags: non_neg_integer,
            extra: binary()
          }

    @doc """
    The caller's recording decision (§3.2.2.5.1).

    We carry this rather than making our own: a service that re-decides sampling
    per hop produces traces with holes in them, which are worse than no traces.
    """
    @spec sampled?(t()) :: boolean()
    def sampled?(%__MODULE__{flags: flags}), do: Bitwise.band(flags, 0x01) == 0x01
  end

  defmodule ServerHop do
    @moduledoc """
    One service's continuation of a trace.

    `:continued` is not a debug field: a span exporter needs to know whether this
    is a root span in order to label it correctly.
    """

    @enforce_keys [:trace_id, :span_id, :flags]
    defstruct [:trace_id, :span_id, :flags, :tracestate, :continued]

    @type t :: %__MODULE__{
            trace_id: binary(),
            span_id: binary(),
            flags: non_neg_integer,
            tracestate: binary() | nil,
            continued: boolean()
          }

    @spec sampled?(t()) :: boolean()
    def sampled?(%__MODULE__{flags: flags}), do: Bitwise.band(flags, 0x01) == 0x01

    @doc """
    This hop as headers for the next service.

    The shape is fixed by §3.4: parent-id becomes this hop's span id, and the
    version is downgraded to the one we implement. Those two mutations plus the
    sampled flag are the entire allowed set — §3.4 says vendors MUST NOT make
    any other mutation.
    """
    @spec outbound_headers(t()) :: %{optional(binary()) => binary()}
    def outbound_headers(%__MODULE__{} = hop) do
      headers = %{
        "traceparent" => KitOtel.Traceparent.format_traceparent(hop.trace_id, hop.span_id, hop.flags)
      }

      case hop.tracestate do
        state when is_binary(state) and state != "" -> Map.put(headers, "tracestate", state)
        _ -> headers
      end
    end
  end

  @doc """
  Parse a `traceparent` header value.

  Returns `{:error, :invalid}` for anything invalid, and that is the whole
  contract: §3.2.2.3 and §3.2.2.4 say a vendor MUST ignore the header when
  trace-id or parent-id is invalid, and §3.2.4 says to restart the trace when
  the version cannot be parsed. There is nothing to partially trust.

  An atom rather than an exception on purpose: this runs on every inbound
  request, and a `:error` tuple costs nothing on the happy path.
  """
  @spec parse(binary() | nil) :: {:ok, TraceParent.t()} | {:error, :invalid}
  def parse(value) when is_binary(value) do
    with true <- byte_size(value) >= @min_header_len,
         <<version::binary-size(2), "-", trace_id::binary-size(32), "-", parent_id::binary-size(16),
           "-", flags_field::binary-size(2), _rest::binary>> <- value,
         true <- lowcase_hex?(version),
         {:ok, version} <- parse_version(version),
         true <- lowcase_hex?(trace_id) and lowcase_hex?(parent_id) and lowcase_hex?(flags_field),
         {:ok, flags} <- parse_flags(flags_field),
         :ok <- check_trailing(value, version),
         true <- trace_id != @zero_trace_id and parent_id != @zero_span_id do
      {:ok,
       %TraceParent{
         version: version,
         trace_id: trace_id,
         parent_id: parent_id,
         flags: flags,
         extra: extra(value)
       }}
    else
      _ -> {:error, :invalid}
    end
  end

  def parse(_), do: {:error, :invalid}

  @doc """
  Continue the trace described by the inbound headers.

  This is the one function a service's plug calls. It cannot fail: a malformed or
  absent traceparent yields a new trace, because a request is not an error
  because its trace header was garbage (§4.2, §3.2.2.3).

  `span_id` is a parameter rather than generated here so the caller owns the span
  lifecycle — in a service it comes from the tracer, in a test it is a constant,
  which is why the suite can assert equality instead of a shape.
  """
  @spec server_hop(map(), binary()) :: ServerHop.t()
  def server_hop(headers, span_id) do
    case parse(header(headers, "traceparent")) do
      {:ok, %TraceParent{} = tp} ->
        %ServerHop{
          trace_id: tp.trace_id,
          span_id: span_id,
          flags: Bitwise.band(tp.flags, @sampled),
          tracestate: forward_tracestate(header(headers, "tracestate")),
          continued: true
        }

      {:error, :invalid} ->
        %ServerHop{trace_id: new_trace_id(), span_id: span_id, flags: 0, continued: false}
    end
  end

  @doc """
  Build a `traceparent` at version 00.

  Always version 00, always lowercase hex, always exactly 55 characters
  (§3.2.2.2). It takes no version parameter on purpose: a service speaks one
  version, and a caller that could pass any version would eventually pass a
  wrong one.
  """
  @spec format_traceparent(binary(), binary(), non_neg_integer) :: binary()
  def format_traceparent(trace_id, parent_id, flags) do
    "00-" <> trace_id <> "-" <> parent_id <> "-" <> encode_flags(flags)
  end

  @doc """
  Apply the §3.3.1.5 limits to an inbound `tracestate`.

  The order matters and is the order the spec states: oversized entries go first
  (they are the expensive ones and the least likely to be a well-known vendor
  key), then entries are dropped from the end. Dropping from the front would
  discard the most recent vendor's entry, which is the one that just wrote it and
  the one that knows where the trace currently is.
  """
  @spec forward_tracestate(binary() | nil) :: binary() | nil
  def forward_tracestate(nil), do: nil

  def forward_tracestate(value) when is_binary(value) do
    entries =
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or byte_size(&1) > @tracestate_entry_limit))

    trimmed = drop_from_end(entries)

    case trimmed do
      [] -> nil
      _ -> Enum.join(trimmed, ",")
    end
  end

  @doc """
  Look a header up case-insensitively.

  §3.2.1: "Vendors MUST expect the header name in any case (upper, lower,
  mixed)". Plug and Req lower-case for us, but a raw map built by a test, a
  proxy, or a custom adapter will not be, and being strict here breaks traces in
  production for no reason.
  """
  @spec header(map(), binary()) :: binary() | nil
  def header(headers, name) when is_map(headers) do
    case Map.fetch(headers, name) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(headers, fn {key, value} ->
          if String.downcase(to_string(key)) == String.downcase(name), do: value
        end)
    end
  end

  @doc """
  A fresh 16-byte trace identifier as 32 hex characters.

  §8: 16 bytes from a cryptographically secure source, never all zeroes.
  """
  @spec new_trace_id() :: binary()
  def new_trace_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  @doc """
  A fresh 8-byte span identifier as 16 hex characters.

  §8. On all-zero failure it returns a fixed non-zero constant rather than
  raising: an exhausted entropy source is not a reason to take the service down,
  and §3.2.2.4 only requires that the value is not all zeroes. The collision
  risk is theoretical; the availability risk is not.
  """
  @spec new_span_id() :: binary()
  def new_span_id do
    id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    if id == @zero_span_id, do: "0000000000000001", else: id
  end


  defp parse_version(<<"ff", _rest::binary>>), do: {:error, :invalid}
  defp parse_version(hex), do: {:ok, String.to_integer(hex, 16)}

  defp parse_flags(hex), do: {:ok, String.to_integer(hex, 16)}

  defp check_trailing(value, 0), do: if(byte_size(value) == @min_header_len, do: :ok, else: {:error, :invalid})

  defp check_trailing(value, _version) when byte_size(value) > @min_header_len,
    do: if(binary_part(value, @min_header_len, 1) == "-", do: :ok, else: {:error, :invalid})

  defp check_trailing(_value, _version), do: :ok

  defp extra(value) when byte_size(value) > @min_header_len,
    do: binary_part(value, @min_header_len + 1, byte_size(value) - @min_header_len - 1)

  defp extra(_value), do: ""

  defp drop_from_end(entries) do
    if Enum.any?(entries, &(byte_size(&1) > @tracestate_entry_limit)) do
      Enum.reject(entries, &(byte_size(&1) > @tracestate_entry_limit))
    else
      trim_to_limit(entries)
    end
  end

  defp trim_to_limit(entries), do: trim_to_limit(entries, byte_size(Enum.join(entries, ",")))

  defp trim_to_limit([], _joined), do: []

  defp trim_to_limit(entries, joined) when joined <= @tracestate_limit, do: entries

  defp trim_to_limit(entries, _joined) do
    shorter = Enum.drop(entries, -1)
    trim_to_limit(shorter, byte_size(Enum.join(shorter, ",")))
  end

  defp encode_flags(flags), do: flags |> Bitwise.band(0xFF) |> Integer.to_string(16) |> String.pad_leading(2, "0")

  defp lowcase_hex?(""), do: false
  defp lowcase_hex?(value), do: not String.match?(value, ~r/[^0-9a-f]/)
end
