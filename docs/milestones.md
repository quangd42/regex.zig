# Milestones

This is a growing document. Add new milestones as the roadmap evolves.

## Milestone 1

Working Regex with complete linear-time PikeVM as the engine.
- Public API: `compile(allocator, pattern) !Regex`, `regex.match(haystack) bool`, `regex.find(haystack) ?Match`, `regex.findCaptures(haystack) ?Captures`
- Supported syntax: literals, concatenation, alternation, grouping, and Perl classes (\d \D \w \W \s \S).
- Matching semantics: leftmost-first, earliest match search.
- Testing: Use relevant tests in RE2/Go `testdata/` <-> Rust `testdata/fowler/` for supported syntax.
- Performance: a basic literal-prefix fast path when the pattern starts with a literal.

## Milestone 2

Full syntax support with PikeVM.
- Public API: `regex.findAll(haystack) ?MatchIter`, `regex.findAllCaptures(gpa, haystack) ?CapturesIter`, ?
- All supported syntax in `docs/feature_matrix.md`.
- Testing: Full RE2/Go `testdata/` <-> Rust `testdata/fowler/`. Test harness, test generator.
- Performance: ???
