# SQL completion engine

`sqlcomplete` owns SQL completion rules. It is a pure Go package: its input is
editor text, a UTF-8 byte offset, the dialect, and a catalog snapshot. Its output
is ranked candidates with replacement and matched-label byte ranges, or signature labels with
byte spans for the active parameter. It cannot open connections,
read credentials, execute SQL, or depend on AppKit or LSP.

The boundaries are:

- PostgreSQL/MySQL adapters load names, columns, structured foreign keys, and function signatures in
  the existing paginated `completion` catalog request. Each key contains paired
  source/target columns, preserving composite-key correspondence.
  Signatures contain input parameter names/types/positions, optional and variadic
  flags, and return types. PostgreSQL OUT/TABLE parameters are excluded from the
  call arguments; default expressions and function bodies are never loaded.
- Swift caches metadata per connected profile and forwards bounded snapshots.
- `sqllsp` handles JSON-RPC, document versions, UTF-16 positions, diagnostics,
  and conversion to/from the engine's byte offsets.
- The native editor displays candidates, handles focus and keyboard navigation,
  and applies one undoable text edit. It waits for contextual LSP results; basic
  local keyword completion is an emergency fallback when the service fails.

## Where rules belong

- `lex.go`: dialect-aware tokens and lexical diagnostics, including unfinished
  input. Comments/literals never contribute identifiers or query scopes.
- `scope.go`: CTE visibility, query blocks, source aliases, derived projections,
  star expansion, correlated subqueries, LATERAL visibility, and set branches.
- `completion.go`: clause rules, qualified/unqualified candidates, projection
  aliases, ambiguity handling, and deduplication.
- `matching.go`: name search and deterministic ranking. Case-insensitive exact
  names precede longer prefixes. Word-prefix chunks support snake_case,
  camelCase, acronym boundaries, and later words (`oi` / `orditem` / `items`
  find `order_items`). Query columns and CTEs precede general candidates of
  comparable match quality. Matching FK snippets keep their contextual priority.
  Typo-only matches follow strong matches: one insertion/deletion/substitution
  or adjacent transposition is allowed from three characters, and two edits from
  seven. Short queries do not receive typo corrections. Ranking happens before
  the 256-item engine limit and 100-row native popup limit.
  Match spans trace that same search path, including typo alignment, only for
  the final candidates. Substituted or missing letters remain unhighlighted.
- `joins.go`: FK joins in both directions, composite predicates, self joins,
  collision-free aliases, and existing `ON` condition suggestions.
- `signature.go`: current function/argument detection, nested delimiters,
  PostgreSQL named arguments, optional/variadic parameters, overload ranking,
  and SUBSTRING FROM/FOR separators. `builtins.go` supplies offline signatures
  for common built-ins; catalog overloads remain grouped by schema and name.
- `dialect.go` / `identifiers.go`: keywords, built-ins, quoting, and identifier
  case rules. Database metadata SQL stays in the database adapters.

This is a tolerant completion analysis, not a server SQL parser or validator.
It resolves projected identifiers, `*`, qualified stars, and explicit expression
aliases without executing expressions or inferring their types. Unknown
projections stay unknown; foreign keys are used only for direct catalog sources,
not guessed through arbitrary CTE expressions or derived tables. Unsupported
syntax must not block editing or turn into a query error diagnostic.

Fuzzy search changes candidate discovery only. SQL scope/alias binding still
uses the dialect's exact identifier rules, and insertion preserves catalog
spelling and quoting. No arbitrary within-word subsequence search is used.
Fuzzy work is bounded to a 64-rune query and 256-rune candidate, with a banded
edit-distance calculation; longer identifiers retain ordinary prefix matching.

Completion items carry the private LSP extension
`data.dbeerMatchRanges: [[start, end], ...]`: ordered, non-overlapping, half-open
UTF-16 offsets within `label`. The engine uses UTF-8 byte spans, and `sqllsp`
translates them. Missing data means no highlight. The native client ignores
malformed/oversized ranges without dropping a valid completion. Shared
`protocol/fixtures/completion-matches.json` cases exercise both implementations,
including non-BMP names. The popup expands display spans to composed characters
and uses bold text plus `editorSuggestWidget.highlightForeground` /
`editorSuggestWidget.focusHighlightForeground`; absent selected highlight colors
inherit the selection foreground for contrast. Theme/selection changes restyle
existing ranges without changing search, insertion, focus, or Undo.

Analysis is limited to the current statement, 48 query levels, 512 scopes,
256 sources per scope, and a bounded token-visit budget. The LSP boundary limits
documents and catalog snapshots independently. Recursive CTEs use explicit
column lists or their anchor projection. Sibling set-operation branches do not
share table aliases; scalar subqueries can correlate with enclosing sources,
and FROM subqueries see preceding sibling sources only with LATERAL.

Add engine regression cases in `completion_test.go`; use LSP tests for position
encoding/document isolation, adapter tests for real metadata, and native tests
for insertion, focus, and Undo. Run focused Go checks from `helper` with
`go test -race ./internal/sqlcomplete ./internal/sqllsp` and native checks with
`scripts/test.sh` from the repository root.

Signature help is a separate `textDocument/signatureHelp` LSP request. Parameter
spans are translated from UTF-8 bytes to UTF-16 offsets in the signature label.
Overloads are ranked by supplied argument count and names, not expression types.
At most 32 overloads and 256 parameters per signature pass the LSP boundary;
catalog snapshots have a separate 8192-parameter budget. The native panel shows
the preferred overload first and up to eight alternatives with scrolling.

Metadata references: [PostgreSQL pg_proc](https://www.postgresql.org/docs/current/catalog-pg-proc.html),
[MySQL PARAMETERS](https://dev.mysql.com/doc/refman/8.4/en/information-schema-parameters-table.html),
and [LSP signature help](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_signatureHelp).

## Cassandra CQL

The Cassandra dialect uses its own keyword/function registry and clause rules in
`cassandra.go`, keeping SQL joins, OFFSET and transaction commands out of CQL
suggestions. The catalog supplies keyspaces, tables, materialized views, UDTs and
bounded UDF/UDA overload declarations without routine source bodies;
optional partition/clustering/static column lists annotate column candidates.
An explicit per-document keyspace limits unqualified source resolution after
`USE`, while qualified names can still address other keyspaces. CQL completion
never executes queries or adds `ALLOW FILTERING`.

DDL completion supplies existing objects and native/UDT declaration types. CQL
function signatures include Cassandra 5.0 math, collection, masking and vector
functions, while the server determines version availability. Literal brackets
and braces count as nested argument boundaries. Unqualified user signatures use
the target table's keyspace when available, falling back to the active keyspace
for incomplete statements. UDT declaration suggestions stay within the target
keyspace. PostgreSQL named-argument syntax is not applied to CQL.
The LSP accepts `languageId: "cql"` as well as `"cassandra"` for offline documents.
`protocol/fixtures/cql-language-v1.json` exercises catalog decoding and signature
help through both Go LSP and the native Swift client without database or UI access.
