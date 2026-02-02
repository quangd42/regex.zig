# Milestones

This is a growing document. Add new milestones as the roadmap evolves.

## Milestone 1: Minimal Bytecode VM

- Architecture: define a compact bytecode instruction set; compile AST to bytecode; run a Thompson-style VM over bytecode with epsilon threads.
- Features: literals, concatenation, alternation, grouping, and Perl classes (\d \D \w \W \s \S); empty alternation branches behave deterministically.
- Performance: linear-time VM simulation; add a basic literal-prefix fast path when the pattern starts with a literal.
- Testing: focused unit tests for edge cases (empty branches, nested groups, class negation); add a placeholder for RE2 differential tests.
- API/UX: `compile(allocator, pattern) !Regex`, `regex.match(haystack) bool`, `regex.find(haystack) ?Match`; compilation is the only error surface.
