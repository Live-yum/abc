"""Offline format tests. Fixtures are constructed bytes; no profiler is run."""

from __future__ import annotations

import os
import struct
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import pprof_raw
from pprof_raw import PprofRawError, parse_pprof_raw


BINARY = "/tmp/preflight-fixture"
# Independent literal bytes from the official PrintProfileData header.
HEADER = bytes.fromhex(
    "0000000000000000 0300000000000000 0000000000000000 "
    "0100000000000000 0000000000000000"
)
PREFIX = b"--- symbol\nbinary=/tmp/preflight-fixture\n"
SEPARATOR = b"---\n--- profile\n"


def sample(value: int, *pcs: int) -> bytes:
    return struct.pack(f"<{2 + len(pcs)}Q", value, len(pcs), *pcs)


def raw(*records: bytes, symbols: bytes = b"", header: bytes = HEADER) -> bytes:
    return PREFIX + symbols + SEPARATOR + header + b"".join(records)


class RawParserTests(unittest.TestCase):
    def parse(self, data: bytes, binary: str | Path = BINARY):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "profile.raw"
            path.write_bytes(data)
            return parse_pprof_raw(path, binary)

    def rejected(self, data: bytes, message: str | None = None):
        with self.assertRaisesRegex(PprofRawError, message or ".+"):
            self.parse(data)

    def test_local_eof_empty_profile_is_exact_zero(self):
        self.assertEqual(self.parse(raw()), {"total": 0, "stacks": {}, "symbols": {}})

    def test_empty_profile_with_unused_symbols(self):
        result = self.parse(raw(symbols=b"0x0000000000000000 unknown\n0x401000 malloc\n"))
        self.assertEqual(result["total"], 0)
        self.assertEqual(result["symbols"], {0: "unknown", 0x401000: "malloc"})

    def test_zero_values_retained_and_not_terminators(self):
        result = self.parse(raw(sample(0, 0x401000), sample(9, 0x402000)))
        self.assertEqual(result["stacks"], {(0x401000,): 0, (0x402000,): 9})
        self.assertEqual(result["total"], 9)

    def test_exact_large_integers_and_duplicate_stacks(self):
        value = 2**53 + 1
        result = self.parse(raw(sample(value, 0x401000), sample(2**64 - 1, 0x401000)))
        self.assertEqual(result["total"], value + 2**64 - 1)
        self.assertEqual(result["stacks"], {(0x401000,): value + 2**64 - 1})

    def test_all_records_kept_beyond_graph_node_default(self):
        result = self.parse(raw(*(sample(i, 0x400000 + i) for i in range(200))))
        self.assertEqual(len(result["stacks"]), 200)
        self.assertEqual(result["total"], sum(range(200)))

    def test_order_recursion_caller_zero_and_unknown_symbols_preserved(self):
        stack = (0x401000, 0x402000, 0x401000, 0)
        result = self.parse(raw(sample(7, *stack)))
        self.assertEqual(result["stacks"], {stack: 7})
        self.assertEqual(result["symbols"], {})

    def test_symbol_addresses_inline_names_and_missing_name(self):
        symbols = b"0x0000000000401000 inline_fn--outer_fn(int)\n0x0000000000402000\n"
        result = self.parse(raw(sample(1, 0x401000, 0x402000), symbols=symbols))
        self.assertEqual(result["symbols"], {0x401000: "inline_fn--outer_fn(int)", 0x402000: ""})

    def test_canonical_trailer_at_eof_for_nonempty_and_empty_profile(self):
        self.assertEqual(self.parse(raw(sample(0, 0)))["total"], 0)
        result = self.parse(raw(sample(2, 0x401000), sample(0, 0)))
        self.assertEqual(result["stacks"], {(0x401000,): 2})

    def test_bad_zero_first_pc_and_data_after_trailer_rejected(self):
        for records in [(sample(1, 0),), (sample(0, 0, 1),),
                        (sample(0, 0), sample(1, 0x401000)),
                        (sample(0, 0), b"MAPPED_LIBRARIES:\n")]:
            with self.subTest(records=records):
                self.rejected(raw(*records), "zero-PC trailer")

    def test_exact_binary_identity_required_without_normalization(self):
        self.assertEqual(self.parse(raw(), Path(BINARY))["total"], 0)
        for binary in ["fixture", "/tmp/./preflight-fixture", "", "x\ny"]:
            with self.subTest(binary=binary), self.assertRaises(PprofRawError):
                self.parse(raw(), binary)

    def test_unknown_duplicate_and_invalid_symbol_records_rejected(self):
        for symbols in [b"0x1 foo\n0x01 foo\n", b"0x10000000000000000 foo\n",
                        b"0x1 \n", b"0X1 foo\n", b"0xG foo\n", b"garbage\n",
                        b"build=x\n", b"binary=/tmp/other\n", b"0x1 a\x00b\n",
                        b"0x1 \xff\n", "0x1 a\u0085b\n".encode()]:
            with self.subTest(symbols=symbols):
                self.rejected(raw(symbols=symbols))

    def test_bad_section_order_markers_and_line_endings_rejected(self):
        data = raw(sample(1, 0x401000))
        variants = [data.replace(b"--- symbol", b"--- symbols", 1),
                    data.replace(b"--- profile", b"--- heap", 1),
                    data.replace(SEPARATOR, b"--- profile\n", 1),
                    data.replace(PREFIX, b"--- symbol\n", 1),
                    data.replace(b"\n", b"\r\n", 1),
                    data.replace(b"binary=", b"unknown=", 1)]
        for bad in variants:
            with self.subTest(data=bad):
                self.rejected(bad)

    def test_truncation_at_every_nonboundary_byte_rejected(self):
        data = raw(sample(1, 0x401000, 0x402000))
        # The format has no record count: ending after its complete header is
        # valid. All other strict prefixes of this single-record file fail.
        valid_header_end = len(raw())
        for cut in range(len(data)):
            if cut == valid_header_end:
                continue
            with self.subTest(cut=cut):
                self.rejected(data[:cut])

    def test_unknown_header_words_and_unsupported_endianness_width(self):
        for slot in range(5):
            header = bytearray(HEADER)
            header[slot * 8] ^= 1
            with self.subTest(slot=slot):
                self.rejected(raw(header=header), "header")
        for header in [struct.pack(">5Q", 0, 3, 0, 1, 0),
                       struct.pack("<5I", 0, 3, 0, 1, 0)]:
            self.rejected(raw(header=header), "header")

    def test_stack_depth_and_trailing_partial_word_fail_closed(self):
        self.rejected(raw(struct.pack("<2Q", 1, 0)), "depth")
        self.rejected(raw(struct.pack("<2Q", 1, pprof_raw.MAX_STACK_DEPTH + 1)), "depth")
        self.rejected(raw(sample(1, 0x401000), b"\x00"), "record header")

    def test_bounds_fail_instead_of_truncating(self):
        with patch.object(pprof_raw, "MAX_RAW_BYTES", 8):
            self.rejected(raw(), "byte limit")
        with patch.object(pprof_raw, "MAX_SYMBOL_LINE_BYTES", 8):
            self.rejected(raw(), "symbol line")
        with patch.object(pprof_raw, "MAX_SYMBOLS", 1):
            self.rejected(raw(symbols=b"0x1 a\n0x2 b\n"), "symbol count")
        with patch.object(pprof_raw, "MAX_RECORDS", 1):
            self.rejected(raw(sample(1, 1), sample(1, 1)), "record count")

    def test_nonregular_file_rejected_without_fifo_blocking(self):
        with tempfile.TemporaryDirectory() as directory:
            fifo = Path(directory) / "fifo"
            os.mkfifo(fifo)
            with self.assertRaisesRegex(PprofRawError, "regular file"):
                parse_pprof_raw(fifo, BINARY)

    def test_missing_file_is_explicit_error(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(PprofRawError, "cannot read"):
                parse_pprof_raw(Path(directory) / "missing", BINARY)

    def test_symlink_input_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "profile.raw"
            target.write_bytes(raw())
            link = Path(directory) / "profile-link.raw"
            link.symlink_to(target)
            with self.assertRaisesRegex(PprofRawError, "cannot read"):
                parse_pprof_raw(link, BINARY)


if __name__ == "__main__":
    unittest.main()
