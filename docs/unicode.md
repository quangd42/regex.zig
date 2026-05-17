# Unicode Support

`regex.zig` is a byte-oriented regex engine. Haystacks are `[]const u8`, match
offsets are byte offsets, and the VM executes byte transitions. Unicode support is implemented by compiling UTF-8
character classes down to an automaton that reads the input one byte at a time. In other words, the UTF-8 decoding
is built into the automaton.

Unicode mode does not validate an entire haystack. The engine compiles Unicode scalar matchers to their UTF-8 byte
encodings, so those matchers only match valid UTF-8 sequences. Byte-only patterns can still match arbitrary bytes.

Unicode mode is controlled by the `u` syntax flag, either inline with `(?u)` or through
`Regex.compile(..., .{ .syntax = .{ .unicode = true } })`.

Unicode mode is currently opt-in. Once Unicode properties and related syntax are implemented, the plan is to make `u`
enabled by default.


## What Works

- UTF-8 scalar literals in patterns are supported.
- In Unicode mode, `.` matches one valid UTF-8 scalar value instead of one raw byte.
- In Unicode mode, bracket classes and ranges are compiled as Unicode scalar ranges and lowered to UTF-8 byte matchers.
- With both `i` and `u` enabled, case-insensitive matching uses Unicode simple case folding from UCD 17.0.0.
- Perl and Posix classes still use ASCII definitions, but `(?iu)` applies Unicode simple folding to their letter ranges.
  This means `[[:upper:]]` is still the ASCII uppercase class, but `(?iu)[[:upper:]]` also matches simple fold equivalents
  such as `K` (Kelvin sign).

Examples:

```zig
try expect(match("(?iu)\\Ak\\z", "K"));
try expect(match("(?iu)\\Ak\\z", "K")); // Kelvin sign
try expect(match("(?iu)\\AΣ\\z", "ς")); // final sigma
```

## Roadmap

- Unicode properties such as `\p{Greek}` and `\pL` are planned.
- Perl classes `\d`, `\w`, and `\s` are defined in ASCII. Unicode definitions might be added.
- Word boundaries `\b` and `\B` are still ASCII word boundaries.
- Full case folding is not planned, so multi-scalar folds such as `ß` to `ss` are not supported.
- Canonical equivalence and normalization-aware matching are not supported.

## Notes

Unicode tables can add to binary size when Unicode-aware matching is used. A future build option is planned to disable
Unicode table support for applications that only need byte/ASCII regexes and prefer a smaller binary.

Generated Unicode data is covered by `src/Compiler/unicode/LICENSE-UNICODE`.
