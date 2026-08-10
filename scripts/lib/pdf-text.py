#!/usr/bin/env python3
"""Best-effort text extraction from a PDF receipt, stdlib only.

Usage: pdf-text.py FILE — prints extracted text to stdout, exits nonzero when
the file is unreadable, not a PDF, or yields no text. Inflates Flate streams
with zlib and collects the literal strings from text-bearing content streams
(Tj/TJ operators). Good enough to make simple vendor receipts searchable; it
is NOT a general PDF parser, and callers must treat empty output as "no text",
never as an error.
"""

import pathlib
import re
import sys
import zlib

MAX_TEXT_CHARS = 100_000

_ESCAPES = {
    b"n": b"\n",
    b"r": b"\r",
    b"t": b"\t",
    b"b": b"\b",
    b"f": b"\f",
    b"(": b"(",
    b")": b")",
    b"\\": b"\\",
}


def _unescape(raw: bytes) -> bytes:
    """Resolve PDF literal-string escapes (named, octal, stray backslash)."""
    out = bytearray()
    i = 0
    while i < len(raw):
        if raw[i : i + 1] != b"\\":
            out += raw[i : i + 1]
            i += 1
            continue
        nxt = raw[i + 1 : i + 2]
        octal = re.match(rb"[0-7]{1,3}", raw[i + 1 : i + 4])
        if nxt in _ESCAPES:
            out += _ESCAPES[nxt]
            i += 2
        elif octal:
            out.append(int(octal.group(0), 8) & 0xFF)
            i += 1 + len(octal.group(0))
        else:
            i += 1
    return bytes(out)


def _streams(pdf: bytes):
    """Yield every stream body, inflated when it is Flate-compressed."""
    for match in re.finditer(rb"stream\r?\n(.*?)endstream", pdf, re.DOTALL):
        body = match.group(1)
        try:
            yield zlib.decompress(body)
        except zlib.error:
            yield body


def extract(pdf: bytes) -> str:
    """Pull the literal strings out of text-bearing content streams."""
    parts = []
    for stream in _streams(pdf):
        if b"BT" not in stream and b"Tj" not in stream and b"TJ" not in stream:
            continue
        for match in re.finditer(rb"\((?:[^()\\]|\\.)*\)", stream):
            text = _unescape(match.group(0)[1:-1]).decode("latin-1", "replace").strip()
            if text:
                parts.append(text)
    return " ".join(parts)[:MAX_TEXT_CHARS]


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: pdf-text.py FILE", file=sys.stderr)
        return 2
    try:
        pdf = pathlib.Path(sys.argv[1]).read_bytes()
    except OSError as err:
        print(f"pdf-text: cannot read {sys.argv[1]}: {err}", file=sys.stderr)
        return 1
    if not pdf.startswith(b"%PDF"):
        return 1
    text = extract(pdf)
    if not text:
        return 1
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
