# Supported Syntax

This follows the layout of RE2's syntax reference, but describes the current
`regex.zig` Pike VM surface.

Support is ASCII-only today.

```text
regex.zig regular expression syntax reference
---------------------------------------------

Single characters:
.              any byte except '\n' (or any byte when s=true)
[xyz]          character class
[^xyz]         negated character class
\d             Perl character class
\D             negated Perl character class
[[:alpha:]]    ASCII character class
[[:^alpha:]]   negated ASCII character class
\p{Greek}      Unicode character class                         PLANNED
\pL            one-letter Unicode character class              PLANNED
\P{Greek}      negated Unicode character class                 PLANNED
\PL            negated one-letter Unicode character class      PLANNED

Composites:
xy             «x» followed by «y»
x|y            «x» or «y» (prefer «x»)

Repetitions:
x*             zero or more «x», prefer more
x+             one or more «x», prefer more
x?             zero or one «x», prefer one
x{n,m}         «n» to «m» «x», prefer more
x{n,}          «n» or more «x», prefer more
x{n}           exactly «n» «x»
x*?            zero or more «x», prefer fewer
x+?            one or more «x», prefer fewer
x??            zero or one «x», prefer zero
x{n,m}?        «n» to «m» «x», prefer fewer
x{n,}?         «n» or more «x», prefer fewer
x{n}?          exactly «n» «x»

Implementation note:
counted repetition bounds above 1000 are rejected by default.
`Options.limits.max_repeat` can change that limit.

Possessive repetitions:
x*+            zero or more «x», possessive                    NOT SUPPORTED
x++            one or more «x», possessive                     NOT SUPPORTED
x?+            zero or one «x», possessive                     NOT SUPPORTED
x{n,m}+        «n» to «m» «x», possessive                      NOT SUPPORTED
x{n,}+         «n» or more «x», possessive                     NOT SUPPORTED
x{n}+          exactly «n» «x», possessive                     NOT SUPPORTED

Grouping:
(re)           numbered capturing group
(?P<name>re)   named capturing group
(?<name>re)    named capturing group
(?'name're)    named capturing group                           NOT SUPPORTED
(?:re)         non-capturing group
(?flags)       set flags from this point onward; non-capturing
(?flags:re)    set flags only for «re»; non-capturing
(?#text)       comment                                         NOT SUPPORTED
(?|x|y|z)      branch numbering reset                          NOT SUPPORTED
(?>re)         possessive match of «re»                        NOT SUPPORTED
(?=re)         lookahead                                       NOT SUPPORTED
(?!re)         negative lookahead                              NOT SUPPORTED
(?<=re)        lookbehind                                      NOT SUPPORTED
(?<!re)        negative lookbehind                             NOT SUPPORTED
(?P=name)      named backreference                             NOT SUPPORTED
(?P>name)      recursive call to named group                   NOT SUPPORTED
\1             numeric backreference                           NOT SUPPORTED
\k<name>       named backreference                             NOT SUPPORTED

Flags:
i              case-insensitive (ASCII-only)
m              multi-line: «^» and «$» also match line boundaries
s              let «.» match '\n'
U              swap greedy/lazy defaults
R              CRLF mode                                       NOT SUPPORTED

Flag syntax is «xyz» (set) or «-xyz» (clear) or «xy-z» (set «xy», clear «z»).
Compile options can also set the initial defaults for i, m, s, and U.

Empty strings:
^              at beginning of text or line («m»=true)
$              at end of text (like «\z», not «\Z») or line («m»=true)
\A             at beginning of text
\b             at ASCII word boundary
\B             not at ASCII word boundary
\G             current search start                            NOT SUPPORTED
\Z             end of text, or before final newline            NOT SUPPORTED
\z             at end of text

Escape sequences:
\a             bell (0x07)
\f             form feed (0x0C)
\t             tab
\n             line feed
\r             carriage return
\v             vertical tab (0x0B)
\xNN           byte with hexadecimal value NN
\x{...}        braced hex escape                               PLANNED
\uNNNN         short Unicode escape                            NOT SUPPORTED
\UNNNNNNNN     long Unicode escape                             NOT SUPPORTED
\NNN           octal escape                                    PLANNED
\Q...\E        literal mode                                    PLANNED

Escaped literals:
\\             backslash
\. \+ \* \?    escaped metacharacters
\( \) \[ \]    escaped delimiters
\{ \} \^ \$    escaped delimiters
\# \& \- \~    escaped literals

Character class elements:
x              single literal byte
A-Z            byte range (inclusive)
\d             Perl character class
[:foo:]        ASCII character class «foo»
[:^foo:]       negated ASCII character class «foo»
\p{Foo}        Unicode character class «Foo»                   PLANNED
\pF            one-letter Unicode character class              PLANNED
[\d]           digits (== \d)
[^\d]          not digits (== \D)
[\w]           word chars (== \w)
[^\w]          not word chars (== \W)
[\s]           whitespace (== \s)
[^\s]          not whitespace (== \S)
[\b]           backspace / word-boundary class item            NOT SUPPORTED

Perl character classes (all ASCII-only):
\d             digits (== [0-9])
\D             not digits (== [^0-9])
\s             whitespace (== [\t\n\v\f\r ])
\S             not whitespace (== [^\t\n\v\f\r ])
\w             word characters (== [0-9A-Za-z_])
\W             not word characters (== [^0-9A-Za-z_])
\h             horizontal space                                NOT SUPPORTED
\H             not horizontal space                            NOT SUPPORTED

ASCII character classes:
[[:alnum:]]    alphanumeric (== [0-9A-Za-z])
[[:alpha:]]    alphabetic (== [A-Za-z])
[[:ascii:]]    ASCII (== [\x00-\x7F])
[[:blank:]]    blank (== [\t ])
[[:cntrl:]]    control (== [\x00-\x1F\x7F])
[[:digit:]]    digits (== [0-9])
[[:graph:]]    graphical (== [!-~])
[[:lower:]]    lower case (== [a-z])
[[:print:]]    printable (== [ -~])
[[:punct:]]    punctuation (== [!-/:-@[-`{-~])
[[:space:]]    whitespace (== [\t\n\v\f\r ])
[[:upper:]]    upper case (== [A-Z])
[[:word:]]     word characters (== [0-9A-Za-z_])
[[:xdigit:]]   hex digit (== [0-9A-Fa-f])
```
