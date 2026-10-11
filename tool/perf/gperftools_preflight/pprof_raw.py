"""Read the bounded local gperftools 2.15 --raw format without running tools.

This is deliberately the Ubuntu amd64, little-endian, 64-bit *local* output
contract, not a general pprof reader. The input consists of UTF-8 symbol lines,
then ``--- profile\n`` and unsigned 64-bit words. The exact header is
``0, 3, 0, 1, 0``; records are ``value, depth, PCs...``. Local --raw emits no
trailer, so clean EOF is valid, including immediately after the header. The
documented CPU trailer ``0, 1, 0`` is also accepted, only at EOF. Other first-PC
zero records are rejected because upstream treats them as end markers.

Zero *values* are real records and are retained. Duplicate stacks are summed
with Python integers. Unknown symbols and zero PCs after the first frame are
retained. Symbol address zero is valid and must not be mistaken for a record
terminator. Missing symbol mappings are allowed; source symbolization only
covers PCs assigned to known mapped binaries. Inline names remain joined by
``--``, exactly as emitted. No demangling, address adjustment, frame dropping,
unit conversion, ranking or truncation happens here.

Primary sources (commit pinned; read, not executed):
https://github.com/gperftools/gperftools/blob/365060c4213a48adb27f63d5dfad41b3dfbdd62e/src/pprof
  PrintProfileData L1117-1163; PrintSymbolizedProfile L1166-1206;
  ReadHeapProfile L4043-4228; ExtractSymbols L4757-4798.
https://github.com/gperftools/gperftools/blob/365060c4213a48adb27f63d5dfad41b3dfbdd62e/docs/cpuprofile-fileformat.html
  64-bit little-endian slots, duplicate-stack aggregation and CPU trailer.

Completeness caveat: a format without a record count/trailer cannot detect
deletion of whole final records. The caller MUST compare totals and stacks
against its independently parsed original heap dump. This parser detects
partial records, unknown formats and trailing garbage; it does not prove
that pprof preserved all source buckets.
"""

from __future__ import annotations

import os
import re
import stat
import struct
from typing import TypedDict


MAX_RAW_BYTES = 16 * 1024 * 1024
MAX_SYMBOL_LINE_BYTES = 64 * 1024
MAX_SYMBOLS = 131_072
MAX_RECORDS = 131_072
MAX_STACK_DEPTH = 1024
_HEADER = struct.pack("<5Q", 0, 3, 0, 1, 0)
_RECORD_HEADER = struct.Struct("<2Q")
_SYMBOL = re.compile(rb"0x([0-9a-f]{1,16})(?: (.+))?\Z")


class PprofRawError(ValueError):
    """The input is malformed, unsupported or exceeds the declared bounds."""


class RawProfile(TypedDict):
    total: int
    stacks: dict[tuple[int, ...], int]
    symbols: dict[int, str]


def _read_bounded(path: str | os.PathLike[str]) -> bytes:
    # O_NONBLOCK prevents a FIFO from blocking before the regular-file check.
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode):
                raise PprofRawError("pprof raw input must be a regular file")
            if info.st_size > MAX_RAW_BYTES:
                raise PprofRawError("pprof raw file exceeds byte limit")
            data = stream.read(MAX_RAW_BYTES + 1)
    except OSError as exc:
        raise PprofRawError(f"cannot read pprof raw input: {exc}") from exc
    if len(data) > MAX_RAW_BYTES:
        raise PprofRawError("pprof raw file exceeds byte limit")
    return data


def parse_pprof_raw(
    path: str | os.PathLike[str], binary: str | os.PathLike[str]
) -> RawProfile:
    """Return exact ``total``, ``stacks`` and ``symbols`` for one raw file.

    ``binary`` must equal the literal executable argument used for pprof, not
    an independently resolved/normalized equivalent path. The value unit is
    external provenance: use separate files for --inuse_space (bytes) and
    --inuse_objects (objects), since raw does not encode that distinction.
    No executable or profile is launched, and no external files are opened.
    Limits fail closed rather than discarding excess records.
    """
    expected_binary = os.fspath(binary)
    if not isinstance(expected_binary, str) or not expected_binary:
        raise PprofRawError("expected binary must be a nonempty text path")
    if any(not char.isprintable() for char in expected_binary):
        raise PprofRawError("expected binary contains control characters")
    try:
        expected_binary_bytes = expected_binary.encode("utf-8")
    except UnicodeError as exc:
        raise PprofRawError("expected binary is not valid UTF-8") from exc

    data = _read_bounded(path)
    offset = 0

    def line() -> bytes:
        nonlocal offset
        end = data.find(b"\n", offset, offset + MAX_SYMBOL_LINE_BYTES + 1)
        if end < 0:
            raise PprofRawError("missing, unterminated or oversized symbol line")
        result = data[offset:end]
        offset = end + 1
        if any(byte < 0x20 or byte == 0x7F for byte in result):
            raise PprofRawError("control byte in symbol section")
        return result

    if line() != b"--- symbol":
        raise PprofRawError("expected gperftools raw symbol section")
    if line() != b"binary=" + expected_binary_bytes:
        raise PprofRawError("raw binary identity is missing or mismatched")

    symbols: dict[int, str] = {}
    while True:
        record = line()
        if record == b"---":
            break
        match = _SYMBOL.fullmatch(record)
        if match is None:
            raise PprofRawError("unknown or malformed symbol record")
        pc = int(match.group(1), 16)
        if pc in symbols:
            raise PprofRawError("duplicate symbol address")
        if len(symbols) >= MAX_SYMBOLS:
            raise PprofRawError("symbol count exceeds limit")
        try:
            symbol = (match.group(2) or b"").decode("utf-8")
        except UnicodeError as exc:
            raise PprofRawError("symbol is not valid UTF-8") from exc
        if any(not char.isprintable() for char in symbol):
            raise PprofRawError("control character in symbol")
        symbols[pc] = symbol

    if line() != b"--- profile":
        raise PprofRawError("expected raw binary profile section")
    if data[offset : offset + len(_HEADER)] != _HEADER:
        raise PprofRawError("unsupported or truncated LE64 raw profile header")
    offset += len(_HEADER)

    stacks: dict[tuple[int, ...], int] = {}
    total = 0
    record_count = 0
    while offset < len(data):
        if len(data) - offset < _RECORD_HEADER.size:
            raise PprofRawError("truncated profile record header")
        value, depth = _RECORD_HEADER.unpack_from(data, offset)
        offset += _RECORD_HEADER.size
        if not 1 <= depth <= MAX_STACK_DEPTH:
            raise PprofRawError("invalid or oversized stack depth")
        end = offset + depth * 8
        if end > len(data):
            raise PprofRawError("truncated profile stack")
        stack = struct.unpack_from(f"<{depth}Q", data, offset)
        offset = end
        if stack[0] == 0:
            if value != 0 or depth != 1 or offset != len(data):
                raise PprofRawError("invalid zero-PC trailer or trailing data")
            break
        record_count += 1
        if record_count > MAX_RECORDS:
            raise PprofRawError("profile record count exceeds limit")
        stacks[stack] = stacks.get(stack, 0) + value
        total += value

    return {"total": total, "stacks": stacks, "symbols": symbols}
