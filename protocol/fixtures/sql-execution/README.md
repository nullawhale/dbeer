# Shared execution source goldens

`v1.json` adds Swift/Rust execution-only expectations without changing the frozen
GPUI baseline or existing protocol fixtures. Literal expected statements derive
from the current `SQLScriptParserTests` dialect cases. Additional expectations
cover `SQLExecutionFragment`, the workspace's adapter scalar error mapping and
`SQLLSPPosition`. Every span contains half-open original UTF-8 byte and UTF-16
unit endpoints. Selection coordinates also use endpoints, not location/length.

The corpus includes PostgreSQL nested comments, tagged dollar quotes, E strings,
BEGIN ATOMIC and nested CASE; MySQL escapes/comments, DELIMITER procedures and
triggers; unsupported client commands/imports and incomplete lexemes; inclusive
semicolon/custom-delimiter caret boundaries, adjacent statements, whitespace,
partial/clamped selections and full scripts; non-BMP scalars, combining marks,
CRLF/lone CR/LF, line ends/EOF and invalid byte/surrogate/LSP positions.

MySQL caret resolution intentionally records Swift's reparse of the selected
server SQL with the default delimiter. A routine may therefore resolve to
multiple fragments, while full-script parsing preserves the routine. Interim
GPUI Run refuses that result. See prototypes/gpui/PARSING.md before adding script
execution; these fragments must never be silently executed as routine pieces.

Consumers: Rust `sql::tests`, Swift `SQLExecutionFixturesTests`. Cases are
prepared and compiled; all execution is deferred to final integration by user
instruction. These synthetic fixtures require no credentials or database.
