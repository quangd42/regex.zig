# Feature Matrix

This matrix tracks regex features and engine support, grouped to mirror the
Rust regex syntax reference.

Legend:

- planned = not implemented yet
- done = fully implemented
- not supported = explicitly unsupported in this engine
- ??? = maybe?

## Core Syntax

| Feature          | PikeVM (NFA) |
| ---------------- | ------------ |
| Literals         | done         |
| Escaped literals | done         |
| Dot (.)          | done         |
| Concatenation    | done         |
| Alternation (\|) | done         |
| Grouping (...)   | done         |

## Repetition

| Feature                                      | PikeVM (NFA)  |
| -------------------------------------------- | ------------- |
| ?                                            | done          |
| *                                            | done          |
| +                                            | done          |
| {m}                                          | done          |
| {m,}                                         | done          |
| {m,n}                                        | done          |
| Lazy quantifiers (*?, +?, ??, {m,n}?)        | done          |
| Possessive quantifiers (*+, ++, ?+, {m,n}+)  | not supported |

## Character Classes

| Feature                             | PikeVM (NFA) |
| ----------------------------------- | ------------ |
| `[abc]`                             | done         |
| `[a-z]`                             | done         |
| `[^...]`                            | done         |
| Escapes inside [] (\], \-, \^, \\)  | done         |
| POSIX classes (`[[:alpha:]]` etc.)  | done         |
| Perl classes (\d \D \w \W \s \S)    | done         |
| Unicode properties (\p{..}, \P{..}) | planned      |
| Unicode scripts/blocks              | planned      |

## Anchors and Boundaries

| Feature                   | PikeVM (NFA) |
| ------------------------- | ------------ |
| ^ and $                   | planned      |
| \A and \z                 | planned      |
| Word boundaries \b and \B | planned      |

## Groups and Captures

| Feature                              | PikeVM (NFA)  |
| ------------------------------------ | ------------- |
| Capturing groups                     | done          |
| Non-capturing groups (?:...)         | planned       |
| Named capturing groups (?P<name>...) | planned       |
| Backreferences (\1, \k<name>)        | not supported |

## Flags and Modes

| Feature                    | PikeVM (NFA) |
| -------------------------- | ------------ |
| Case-insensitive (i)       | planned      |
| Multiline (m)              | planned      |
| Dotall (s)                 | planned      |
| Ungreedy (U)               | planned      |
| Inline flags (?i)          | planned      |
| Scoped flags (?i:...)      | planned      |
| Unicode mode               | planned      |
| UTF-8 validity enforcement | planned      |
| Line terminator override   | planned      |

## Escapes

| Feature                              | PikeVM (NFA)  |
| ------------------------------------ | ------------- |
| Hex escapes (\xNN)                   | done          |
| Hex escapes (\x{NN...})              | planned       |
| Unicode escapes (\uNNNN, \UNNNNNNNN) | planned       |
| Octal escapes (\NNN)                 | planned       |
| C-style escapes (\n, \r, \t, etc.)   | done          |
| Literal mode \Q...\E                 | not supported |

## Lookaround

| Feature                      | PikeVM (NFA)  |
| ---------------------------- | ------------- |
| Lookahead (?=...)            | not supported |
| Negative lookahead (?!...)   | not supported |
| Lookbehind (?<=...)          | not supported |
| Negative lookbehind (?<!...) | not supported |

## Matching Semantics and APIs

| Feature                          | PikeVM (NFA) |
| -------------------------------- | ------------ |
| Empty matches (zero-width)       | done         |
| Leftmost-first semantics         | done         |
| Leftmost-longest semantics       | planned      |
| Earliest match search            | done         |
| Overlapping matches              | ???????      |
| Multiple patterns (pattern sets) | ???????      |
| Capture iteration                | planned      |
| Find all matches                 | planned      |
| Bounded search (start/end)       | planned      |
| Replacements                     | planned      |
| Streaming search                 | ???????      |
