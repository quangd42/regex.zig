#!/usr/bin/env python3
"""
Fetches CaseFolding.txt for SUPPORTED_VERSION and rewrites Zig case fold
range/delta table.

Case-fold range compression follows RE2's Unicode table generator; see LICENSE-RE2.
"""

import sys

if sys.version_info < (3, 12):
    sys.exit('error: Python 3.12 or newer is required')

import argparse
from collections.abc import Sequence
from pathlib import Path

import ucd

SUPPORTED_VERSION = '17.0.0'

# The current tables have no fold-equivalent group bigger than 4.
MAX_CASEFOLD_GROUP = 4

EVEN_ODD = 'even_odd'
ODD_EVEN = 'odd_even'
SKIP_SUFFIX = '_skip'

REPO_ROOT = Path(__file__).resolve().parents[2]
OUTPUT_PATH = REPO_ROOT / 'src/Compiler/unicode/case_fold_table.zig'

Pair = tuple[int, int]
Delta = int | str
FoldRange = tuple[int, int, Delta]


class Error(Exception):
    pass


def read_case_groups(input_path: Path | None) -> list[list[int]]:
    """Returns sorted code point groups equivalent under simple case folding."""
    groups: dict[int, set[int]] = {}
    seen: set[int] = set()

    # Try to read from local file first, if provided.
    if input_path:
        rows = ucd.read_table_file(input_path, 4)
    else:
        rows = ucd.read_table(SUPPORTED_VERSION, 'CaseFolding.txt', 4)

    for codes, fields in rows:
        if len(codes) != 1:
            raise Error('CaseFolding.txt source must be a single code point')

        source = codes[0]
        _, status, mapping, _ = fields
        if status not in ('C', 'S'):
            continue
        if source in seen:
            raise Error(f'duplicate simple case fold mapping for U+{source:X}')

        targets = mapping.split()
        if len(targets) != 1:
            raise Error('simple case fold mapping must have length 1')

        target = ucd.codepoint(targets[0])
        seen.add(source)
        groups.setdefault(target, {target}).add(source)

    casegroups = [sorted(group) for group in groups.values() if len(group) > 1]
    casegroups.sort()
    return casegroups


def make_fold_pairs(casegroups: Sequence[Sequence[int]]) -> list[Pair]:
    """Converts each fold group to cyclic pairs, wrapping last to first."""
    pairs: list[Pair] = []
    seen: set[int] = set()

    for group in casegroups:
        if len(group) > MAX_CASEFOLD_GROUP:
            raise Error(f'case fold group too large: {len(group)} members')
        for i, target in enumerate(group):
            source = group[i - 1]
            if source in seen:
                raise Error(f'duplicate simple case fold pair for U+{source:X}')
            seen.add(source)
            pairs.append((source, target))

    return sorted(pairs)


def make_ranges(pairs: Sequence[Pair], *, allow_skip: bool = False) -> list[FoldRange]:
    """Compresses sorted pairs into range/delta entries.
    [(65,97), (66, 98), ..., (90,122)] => [(65, 90, +32)].
    """
    ranges: list[FoldRange] = []
    last = -100

    def extend_adjacent(source: int, target: int, entry: FoldRange) -> FoldRange | None:
        lo, _, delta_ = entry
        if source != last + 1 or target != add_delta(source, delta_):
            return None
        return lo, source, delta_

    def extend_skip(source: int, target: int, entry: FoldRange) -> FoldRange | None:
        lo, _, delta_ = entry
        if source != last + 2 or not isinstance(delta_, str):
            return None
        base = delta_.removesuffix(SKIP_SUFFIX)
        if base not in (EVEN_ODD, ODD_EVEN) or target != add_delta(source, base):
            return None
        return lo, source, base + SKIP_SUFFIX

    for source, target in pairs:
        extended = extend_adjacent(source, target, ranges[-1]) if ranges else None
        if extended is None and allow_skip and ranges:
            extended = extend_skip(source, target, ranges[-1])

        if extended is not None:
            ranges[-1] = extended
        else:
            ranges.append((source, source, delta(source, target)))
        last = source

    return ranges


def delta(source: int, target: int) -> Delta:
    """Computes target - source, using parity sentinels for adjacent pairs."""
    if source + 1 == target:
        return EVEN_ODD if source % 2 == 0 else ODD_EVEN
    if source == target + 1:
        return ODD_EVEN if source % 2 == 0 else EVEN_ODD

    value = target - source
    if value < -(1 << 21) or value >= (1 << 21):
        raise Error(f'case fold delta out of i22 range: {value}')
    if value in (1, -1):
        raise Error(f'case fold delta collides with parity sentinel: {value}')
    return value


def add_delta(codepoint: int, delta: Delta) -> int:
    """Applies a numeric delta or parity sentinel to one code point."""
    if isinstance(delta, int):
        return codepoint + delta

    base = delta.removesuffix(SKIP_SUFFIX)
    if base == EVEN_ODD:
        return codepoint + 1 if codepoint % 2 == 0 else codepoint - 1
    if base == ODD_EVEN:
        return codepoint + 1 if codepoint % 2 == 1 else codepoint - 1
    raise Error(f'bad case fold delta {delta!r}')


def generate(input_path: Path | None, output_path: Path | None) -> str:
    """Returns the complete generated Zig table text."""
    casegroups = read_case_groups(input_path)
    pairs = make_fold_pairs(casegroups)
    ranges = make_ranges(pairs)

    command = 'python3 tools/unicode/case_fold.py update'
    if input_path:
        command += f' --input {input_path}'
    if output_path != OUTPUT_PATH:
        command += f' --output {output_path}'

    lines = [
        '// DO NOT EDIT: generated from Unicode UCD '
        f'{SUPPORTED_VERSION} by `{command}`.',
        '// See LICENSE-UNICODE in this directory for the Unicode data license.',
        '',
        f'pub const unicode_version = "{SUPPORTED_VERSION}";',
        '',
        'const case_fold = @import("case_fold.zig");',
        'const even_odd = case_fold.even_odd;',
        'const odd_even = case_fold.odd_even;',
        '',
        f'// {len(casegroups)} groups, {len(pairs)} pairs, {len(ranges)} ranges.',
        'pub const entries = [_]case_fold.Entry{',
    ]
    for lo, hi, delta_ in ranges:
        lines.append(
            f'    .{{ .lo = 0x{lo:X}, .hi = 0x{hi:X}, .delta = {delta_} }},',
        )
    lines += ['};', '']
    return '\n'.join(lines)


def display_path(path: Path) -> str:
    """Returns a compact path for status messages."""
    resolved = path.resolve()
    try:
        return str(resolved.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description='Generate src/Compiler/unicode/case_fold_table.zig from Unicode CaseFolding.txt.',
    )
    parser.add_argument('command', choices=('update', 'check'))
    parser.add_argument(
        '-i', '--input', type=Path, help='read CaseFolding.txt from a local path'
    )
    parser.add_argument(
        '-o',
        '--output',
        type=Path,
        default=OUTPUT_PATH,
        help='generated Zig output path',
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        expected = generate(args.input, args.output)
        if args.command == 'update':
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(expected, encoding='utf-8')
            print(
                f'updated {display_path(args.output)} from Unicode {SUPPORTED_VERSION}',
            )
        else:
            if args.output.read_text(encoding='utf-8') != expected:
                raise Error(f'generated file is stale: {display_path(args.output)}')
            print(
                f'{display_path(args.output)} is up to date for Unicode {SUPPORTED_VERSION}',
            )
    except (OSError, Error, ucd.Error) as exc:
        print(f'error: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
