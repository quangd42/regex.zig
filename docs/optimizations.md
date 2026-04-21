# Optimizations

The followings are optimizations that were naturally adopted on the first-pass implementation, or are part of what enables
RE2 family's linear time matching guarantee.

## Compile Time

- Counted repetition lowering: `{n,m}` compiles to a required prefix, plus nested optional suffix to reduce equivalent epsilon paths.
- Character class normalization: class ranges are sorted and merged before codegen finishes.
- ASCII case-fold expansion: case-insensitive ASCII matching is compiled into matcher ranges instead of extra runtime branching.

## Runtime

- Literal-prefix fast path: unanchored search scans for a required leading literal byte before entering the full VM.
- Query-cost specialization: `match()` does no capture work, `find()` tracks only group 0, `findCaptures()` tracks all capture slots.
- Reused thread lists: the Pike VM allocates thread storage once and swaps two lists per input byte.
- Sparse-set dedup: active matcher states use sparse/dense storage for O(1) membership checks and compact iteration.
- Generation-based epsilon visitation: epsilon-closure clears are usually O(1), with full reset only on generation wraparound.

## Future explorations

- Parsing: Instead of keeping track span for error reporting in the main path, re parse to report errors.
- Parsing: Eliminate individual slices?
