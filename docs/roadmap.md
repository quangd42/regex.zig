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

- Error reporting stabilization:
  - Complete compile diagnostics taxonomy wiring:
    - `program_too_large`
    - `too_many_patterns`
    - `unsupported_feature`
  - Optional renderer module for diagnostics (`src/errors/render.zig`) as helper API, not a core dependency.
  - References: `reference/error_reporting/01_error_reporting_plan.md`.
- Usage-guide documentation effort:
  - Move/maintain small public API usage tests close to `src/Regex.zig`.
  - Add error-handling usage tests (`catch error.Parse/error.Compile`, diagnostics side-channel).
  - Gradually turn these tests into executable docs for package users.
- Limits roadmap (informed by Go/Rust):
  - Parser limit baseline is in place (`repeat_size`, default 1000).
  - Compiler limit baseline is in place for `states_count`.
  - Add additional compile-time limits incrementally, with diagnostics tags and tests.
- Test harness to consume Rust's toml test files. https://github.com/karlseguin/zqlite.zig/blob/master/test_runner.zig
- Documentation https://github.com/karlseguin/http.zig/blob/master/readme.md
- More syntax support.
- Better public APIs.
- Engines: Backtracking, DFA, lazy DFA, one-pass DFA.
