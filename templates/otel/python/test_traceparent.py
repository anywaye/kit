"""kit template — W3C Trace Context propagation for a FastAPI service.

Copy traceparent.py and this file into your service, then run
``python -m pytest test_traceparent.py`` (or ``python test_traceparent.py``).
The suite is the contract: it proves the template still continues a trace
instead of quietly restarting it.

REFERENCE: W3C Trace Context, W3C Recommendation 23 November 2021
https://www.w3.org/TR/trace-context/ — every rule asserted below cites the
section that requires it.

WHAT IT PROMISES
  - A valid inbound traceparent is continued: same trace-id, sampled flag
    preserved, parent-id replaced with this hop's span id (§3.4).
  - A missing or malformed traceparent starts a new trace and never raises. A
    request is not a 500 because its trace header was garbage.
  - tracestate travels with the trace, capped at 512 characters and truncated on
    whole-entry boundaries (§3.3.1.5).
"""

from __future__ import annotations

import unittest

from traceparent import new_span_id, new_trace_id, parse_traceparent, server_hop

KNOWN_HEADER = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
KNOWN_TRACE = "4bf92f3577b34da6a3ce929d0e0e4736"
KNOWN_PARENT = "00f067aa0ba902b7"
FIXED_SPAN = "1111111111111111"

BAD_HEADERS = {
    "empty": "",
    "not a header": "garbage",
    "truncated at 54": f"00-{KNOWN_TRACE}-{KNOWN_PARENT}",
    "version 00 plus junk": f"{KNOWN_HEADER}-extra",
    "all-zero trace-id": f"00-{'0' * 32}-{KNOWN_PARENT}-01",
    "all-zero parent-id": f"00-{KNOWN_TRACE}-{'0' * 16}-01",
    "uppercase hex": f"00-4BF92F3577B34DA6A3CE929D0E0E4736-{KNOWN_PARENT}-01",
    "forbidden version ff": f"ff-{KNOWN_TRACE}-{KNOWN_PARENT}-01",
    "one-char version": f"0-{KNOWN_TRACE}-{KNOWN_PARENT}-01",
    "wrong delimiters": f"00_{KNOWN_TRACE}_{KNOWN_PARENT}_01",
    "non-hex flags": f"00-{KNOWN_TRACE}-{KNOWN_PARENT}-0g",
}


class TraceparentTest(unittest.TestCase):
    """Every name here is the same in the other five templates, so a failure
    reads the same whichever language it came from."""

    def test_known_traceparent_is_continued(self) -> None:
        hop = server_hop({"traceparent": KNOWN_HEADER}, FIXED_SPAN)

        self.assertEqual(hop.trace_id, KNOWN_TRACE)
        self.assertTrue(hop.continued, "a valid inbound traceparent must be continued")
        self.assertEqual(hop.span_id, FIXED_SPAN)
        self.assertNotEqual(hop.span_id, KNOWN_PARENT, "span id must not be the inbound parent-id")
        self.assertTrue(hop.sampled, "sampled flag (§3.2.2.5.1) must survive the hop")

        out = hop.outbound_headers
        parsed = parse_traceparent(out["traceparent"])
        self.assertIsNotNone(parsed, "outbound traceparent did not parse")
        self.assertEqual(parsed.trace_id, KNOWN_TRACE)
        self.assertEqual(parsed.parent_id, FIXED_SPAN, "outbound parent-id is this hop's span id")
        self.assertTrue(parsed.sampled, "outbound trace-flags lost the sampled bit")
        self.assertEqual(parsed.version, 0, "we emit the version we implement")

    def test_unsampled_flag_is_preserved(self) -> None:
        unsampled = f"00-{KNOWN_TRACE}-{KNOWN_PARENT}-00"
        hop = server_hop({"traceparent": unsampled}, FIXED_SPAN)

        self.assertFalse(hop.sampled, "sampled flag must not be invented on an unsampled trace")
        self.assertEqual(hop.trace_id, KNOWN_TRACE)
        self.assertTrue(hop.outbound_headers["traceparent"].endswith("-00"))

    def test_second_hop_keeps_the_same_trace_id(self) -> None:
        first = server_hop({"traceparent": KNOWN_HEADER}, "2222222222222222")
        second = server_hop(first.outbound_headers, "3333333333333333")

        self.assertEqual(second.trace_id, KNOWN_TRACE, "trace broken across hops")
        self.assertTrue(second.continued, "a traceparent this service just emitted must parse")

    def test_malformed_traceparent_starts_a_new_trace(self) -> None:
        for name, value in BAD_HEADERS.items():
            with self.subTest(header=name):
                hop = server_hop({"traceparent": value}, FIXED_SPAN)

                self.assertFalse(hop.continued, f"{value!r} was accepted as a valid traceparent")
                self.assertNotEqual(hop.trace_id, KNOWN_TRACE, "an invalid traceparent contributed its trace-id")
                self.assertEqual(len(hop.trace_id), 32)
                self.assertNotEqual(hop.trace_id, "0" * 32, "restarted trace-id must not be all zeroes (§3.2.2.3)")
                self.assertIsNotNone(
                    parse_traceparent(hop.outbound_headers["traceparent"]),
                    "the restarted trace must be valid on the way out",
                )

    def test_missing_traceparent_starts_a_new_trace(self) -> None:
        hop = server_hop({}, FIXED_SPAN)

        self.assertFalse(hop.continued)
        self.assertEqual(len(hop.trace_id), 32)
        self.assertNotEqual(hop.trace_id, "0" * 32)
        self.assertFalse(hop.sampled, "a trace this service started defaults to not-sampled (§3.2.2.5.1)")

    def test_tracestate_is_forwarded(self) -> None:
        hop = server_hop({"traceparent": KNOWN_HEADER, "tracestate": "congo=t61rcWkgMzE"}, FIXED_SPAN)
        self.assertEqual(hop.outbound_headers["tracestate"], "congo=t61rcWkgMzE")

    def test_tracestate_is_truncated_at_whole_entries(self) -> None:
        entries = [f"v{i:02d}={'x' * 30}" for i in range(60)]
        long = ",".join(entries)

        hop = server_hop({"traceparent": KNOWN_HEADER, "tracestate": long}, FIXED_SPAN)
        out = hop.outbound_headers["tracestate"]

        self.assertLessEqual(len(out), 512, "§3.3.1.5 caps a combined header at 512")
        self.assertNotEqual(out, "", "truncating dropped the whole header")
        for entry in out.split(","):
            self.assertIn(entry, long, "an entry was truncated mid-entry, which §3.3.1.5 forbids")
        self.assertTrue(out.startswith(entries[0]), "§3.3.1.5 drops entries from the end")

    def test_oversized_tracestate_entries_are_removed_first(self) -> None:
        oversized = f"huge={'y' * 200}"
        hop = server_hop({"traceparent": KNOWN_HEADER, "tracestate": f"{oversized},small=1"}, FIXED_SPAN)

        out = hop.outbound_headers["tracestate"]
        self.assertNotIn("huge=", out, "an entry over 128 characters is removed first")
        self.assertEqual(out, "small=1")

    def test_tracestate_without_a_valid_traceparent_is_discarded(self) -> None:
        for value in ("", "not-a-traceparent"):
            with self.subTest(traceparent=value):
                hop = server_hop({"traceparent": value, "tracestate": "congo=t61rcWkgMzE"}, FIXED_SPAN)
                self.assertNotIn(
                    "tracestate",
                    hop.outbound_headers,
                    "tracestate must be discarded when there is no valid traceparent",
                )

    def test_header_names_are_case_insensitive_and_sent_lowercase(self) -> None:
        for name in ("traceparent", "TraceParent", "TRACEPARENT", "Traceparent"):
            with self.subTest(name=name):
                hop = server_hop({name: KNOWN_HEADER}, FIXED_SPAN)
                self.assertEqual(hop.trace_id, KNOWN_TRACE, f"header {name} was not recognised")

        out = server_hop({"TraceParent": KNOWN_HEADER}, FIXED_SPAN).outbound_headers
        for name in out:
            self.assertEqual(name, name.lower(), "§3.2.1: send the header name lowercase")

    def test_higher_version_is_downgraded_and_unknown_fields_are_not_forwarded(self) -> None:
        future = f"cc-{KNOWN_TRACE}-{KNOWN_PARENT}-01-what-the-future-wants"

        parsed = parse_traceparent(future)
        self.assertIsNotNone(parsed, "a well-formed higher version must be parsed per §3.2.4")
        assert parsed is not None
        self.assertEqual(parsed.version, 0xCC)
        self.assertEqual(parsed.trace_id, KNOWN_TRACE)
        self.assertEqual(parsed.parent_id, KNOWN_PARENT)

        out = server_hop({"traceparent": future}, FIXED_SPAN).outbound_headers["traceparent"]
        self.assertTrue(out.startswith("00-"), "outbound must be downgraded to version 00")
        self.assertNotIn("what-the-future-wants", out, "§3.2.4: MUST NOT forward unknown fields")

    def test_trace_flags_are_a_bit_field(self) -> None:
        hop = server_hop({"traceparent": f"00-{KNOWN_TRACE}-{KNOWN_PARENT}-03"}, FIXED_SPAN)

        self.assertTrue(hop.sampled, "bit 0 set means sampled; reading flags as a number is the classic bug")
        self.assertTrue(
            hop.outbound_headers["traceparent"].endswith("-01"),
            "reserved bits must be zeroed on the way out (§3.2.2.5.2)",
        )

    def test_new_identifiers_are_random_and_never_all_zero(self) -> None:
        seen: set[str] = set()
        for _ in range(256):
            trace_id = new_trace_id()
            self.assertEqual(len(trace_id), 32)
            self.assertNotEqual(trace_id, "0" * 32)
            self.assertNotIn(trace_id, seen, "new_trace_id repeated within 256 draws (§8.2)")
            seen.add(trace_id)

            span_id = new_span_id()
            self.assertEqual(len(span_id), 16)
            self.assertNotEqual(span_id, "0" * 16)


if __name__ == "__main__":
    unittest.main()
