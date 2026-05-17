"""Shared UCD reader for Unicode generator scripts.

Fetches versioned unicode.org tables and expands the range forms used by UCD
files, including explicit ranges and First/Last range pairs.
"""

import re
import urllib.request
from collections.abc import Iterable, Iterator, Sequence
from pathlib import Path

UNICODE_MAX = 0x10FFFF
SURROGATE_FIRST = 0xD800
SURROGATE_LAST = 0xDFFF

_CONTINUATION_RE = re.compile(r'<(.*), (First|Last)>')

TableRow = tuple[Sequence[int], list[str]]


class Error(Exception):
    pass


def codepoint(text: str) -> int:
    """Converts a hexadecimal field to a valid Unicode scalar value."""
    value = text.strip()
    if (
        not value
        or len(value) > 6
        or not all(ch in '0123456789abcdefABCDEF' for ch in value)
    ):
        raise Error(f'invalid code point {value!r}')

    cp = int(value, 16)
    if cp > UNICODE_MAX or SURROGATE_FIRST <= cp <= SURROGATE_LAST:
        raise Error(f'invalid Unicode scalar U+{cp:X}')
    return cp


def codepoint_range(text: str) -> Sequence[int]:
    """Converts a code point or inclusive code point range field."""
    bounds = text.split('..')
    if len(bounds) == 1:
        return [codepoint(bounds[0])]
    if len(bounds) == 2:
        lo = codepoint(bounds[0])
        hi = codepoint(bounds[1])
        if lo < hi:
            return range(lo, hi + 1)
    raise Error(f'invalid range {text!r}')


def read_table(version: str, file_name: str, field_count: int) -> Iterator[TableRow]:
    """Reads a versioned UCD table from unicode.org."""
    source = f'https://www.unicode.org/Public/{version}/ucd/{file_name}'
    with urllib.request.urlopen(source, timeout=30) as response:
        yield from _read_table(source, response, field_count)


def read_table_file(path: Path, field_count: int) -> Iterator[TableRow]:
    """Reads a local UCD table file."""
    with path.open('rb') as file:
        yield from _read_table(path.name, file, field_count)


def _read_table(
    source: str, lines: Iterable[bytes], field_count: int
) -> Iterator[TableRow]:
    """Strips comments, splits fields, and expands UCD code ranges."""
    if field_count < 2:
        raise Error(f'invalid field count {field_count}')

    first: int | None = None
    expect_last: str | None = None

    for line_number, raw_line in enumerate(lines, start=1):
        # Strip comments, ignore empty lines.
        line = raw_line.decode('utf-8').split('#', 1)[0].strip()
        if not line:
            continue

        # Split fields on `;` and assert number of fields.
        fields = [field.strip() for field in line.split(';')]
        if len(fields) != field_count:
            raise Error(f'{source}:{line_number}: wrong field count {len(fields)}')

        # The first field is either a single code point or an explicit
        # inclusive range like `0041..005A`.
        try:
            codes = codepoint_range(fields[0])
        except Error as exc:
            raise Error(f'{source}:{line_number}: {exc}') from exc

        # Some UCD files encode ranges as two rows whose second field ends with
        # `<Name, First>` and `<Name, Last>`. When we see `First`, remember it
        # and wait for the matching `Last` row before yielding one expanded row.
        match = _CONTINUATION_RE.fullmatch(fields[1])
        name, marker = match.groups() if match else (fields[1], None)
        if expect_last is not None:
            # The row after `First` must be the corresponding `Last` row and
            # must advance the code point range.
            assert first is not None
            if (
                len(codes) != 1
                or codes[0] <= first
                or marker != 'Last'
                or name != expect_last
            ):
                raise Error(
                    f'{source}:{line_number}: expected Last line for {expect_last}'
                )
            codes = range(first, codes[0] + 1)
            fields[0] = f'{codes[0]:04X}..{codes[-1]:04X}'
            fields[1] = name
            first = None
            expect_last = None
        elif marker == 'First':
            # Defer yielding until the `Last` row determines the range end.
            if len(codes) != 1:
                raise Error(f'{source}:{line_number}: bad First line')
            first = codes[0]
            expect_last = name
            continue

        yield codes, fields

    if expect_last is not None:
        raise Error(f'{source}: expected Last line for {expect_last}; got EOF')
