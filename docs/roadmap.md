# Roadmap

This is a growing document. Add new milestones as the roadmap evolves.

## Milestone 1

Working Regex with complete linear-time PikeVM as the engine.

- Public API: `compile(allocator, pattern) !Regex`, `regex.match(haystack) bool`, `regex.find(haystack) ?Match`, `regex.findCaptures(haystack) ?Captures`
- Supported syntax: literals, concatenation, alternation, repetition, grouping, Perl classes, and bracket classes (`[...]`).
- Matching semantics: leftmost-first, earliest match search.
- Testing: Use relevant tests in RE2/Go `testdata/` <-> Rust `testdata/fowler/` for supported syntax.
- Performance: a basic literal-prefix fast path when the pattern starts with a literal.

## Next goals

- Error reporting. https://matklad.github.io/2026/02/16/diagnostics-factory.html | https://news.ycombinator.com/item?id=47028705
- Test harness to consume Rust's toml test files. https://github.com/karlseguin/zqlite.zig/blob/master/test_runner.zig
- More syntax support.
- Better public APIs.
- Engines: Backtracking, DFA, lazy DFA, one-pass DFA.
