# SQL execution source and fragment contract

Task 8 ports the current Swift `SQLScriptParser` and `SQLExecutionFragment`
execution semantics to `src/sql.rs`. Tree-sitter remains a display highlighter;
it does not split SQL for execution. The Go helper remains authoritative for
SQL classification, policy, authorization and all database behavior. Parsing a
statement never authorizes it. See IMPLEMENTATION.md for verification status.
The macOS product remains SwiftUI/AppKit. GPUI targets Windows 11 x64 and
Ubuntu 24.04 x64; Mac GPUI is development only.

## Immutable preparation

`SourceText::new(text: impl Into<Arc<str>>)` owns the exact document snapshot.
No path trims the whole source, normalizes Unicode or converts newlines.
`parse(&SourceText, Dialect) -> ParsedScript` returns immutable statements,
client-delimiter editor hit areas and diagnostics. Each statement exposes its
exact `sql()` and original `span()`. A `SourceSpan` exposes half-open `bytes()`
and `utf16()` ranges. Private fields prevent callers from changing prepared
SQL independently of its source ranges. SQL-bearing types deliberately have
no Debug implementation.

`resolve(source, selection: Range<usize>, dialect, script)` accepts GPUI UTF-8
byte offsets. `resolve_utf16` accepts Swift offsets instead. Both return
`Option<PreparedFragment>`; invalid positions and empty selections return None.
Nonempty selections clamp their upper bound to the source, trim only the
reference SQL whitespace (ASCII space, tab through carriage return and NBSP),
and parse precisely that substring, including partial SQL. Script resolution
ignores selection and parses the entire unchanged source. Fragment line labels
count LF, matching Swift; LSP separately treats lone CR as a line break.

`PreparedFragment` exposes `source`, `kind`, `span`, `source_sql`, `statements`,
`diagnostic`, `first_line` and `last_line`. `single_statement()` refuses the
first diagnostic, empty SQL and any multi-statement fragment. It is an interim
Run gate, not a policy decision. The live and synthetic demo Run paths capture
this preparation before asynchronous work. Live parse refusal occurs before
helper startup, credentials or connect. Explicit internal transaction commands
use their own bounded source snapshot rather than the editor's selection.

Each accepted live operation retains the prepared fragment as well as Task 3's
captured document/profile/settings/source revision/session generation. Its
execution entry records the prepared original byte range. Existing original
helper client ownership, terminal draining, ACK, Stop, stale payload rejection
and unknown transaction outcomes are preserved. A changed caret does not alter
an already captured fragment. A changed source revision still invalidates it.
Task 9 supplies the shared command registry; Task 10 supplies sequential scripts,
ordered policy review, execution highlighting and error navigation (SCRIPTS.md).

## Scanner and cursor semantics

The scanner directly follows the UTF-16 reference state machine, independently
of highlighting or adapter classification. It handles PostgreSQL tagged dollar
quotes, E-string versus ordinary string escapes, doubled quotes, nested block
comments and SQL routine BEGIN ATOMIC bodies with nested CASE/END tracking.
MySQL handles its string/backtick/comment rules and line-only DELIMITER changes.
Delimiter directives and terminators are excluded from submitted server SQL,
while all remaining statement ranges still address the original source.
Comments and newlines inside the reference statement range are preserved.

Cursor lookup first prefers inclusive server SQL ranges, then inclusive editor
hit areas containing client terminators, then the next statement, then the last.
Thus a cursor immediately after a semicolon stays with its preceding statement;
when the next statement starts at that exact offset, its server range wins.
Leading/trailing trivia and custom delimiter boundaries follow the same order.

Unsupported backslash/mysql client commands, streaming COPY to/from STDIN or
STDOUT, LOAD DATA LOCAL and incomplete quote/comment/dollar/atomic constructs
produce source diagnostics. Server-side COPY and nonlocal server SQL still
require helper assessment. This scanner intentionally supplies lexical splitting
and the reference client-directive checks, not an SQL grammar or a substitute
for the helper's mutation/security classification.

**Reference MySQL selection nuance:** Swift resolves a current statement using
the original script's delimiter state, then reparses that selected server SQL
with the default delimiter. For a custom-delimiter routine containing internal
semicolons, the resolved fragment therefore contains multiple smaller parsed
statements. `parse(original_source)` and full-script resolution correctly keep
the routine whole. The shared goldens retain this observable reference behavior.
Current Run refuses the multiple-statement result and never submits routine
pieces. The command/script paths retain this refusal. Changing it requires an explicit, reviewed
cross-client behavior change with corresponding shared fixtures; they must not
silently execute the fragment's routine pieces. Full-script execution can use
its already prepared original-source statements without reparsing removed
DELIMITER lines or reconstructing a concatenated buffer.

## Coordinate units and invalid positions

All coordinate conversion is explicit and uses the unchanged source:

| Interface | Units and boundary behavior |
| --- | --- |
| GPUI selection, source highlight | Zero-based UTF-8 byte offsets; continuation bytes are invalid |
| Swift NSRange | Zero-based UTF-16 units; surrogate interiors are invalid for conversion |
| LSP | Zero-based line and UTF-16 character; CRLF is one break, its interior is invalid, neither newline half adds a column |
| Adapter `errorPosition` | Optional one-based Unicode scalar offset within the exact submitted statement, not byte/UTF-16/grapheme units |

`SourceText::{byte_to_utf16,utf16_to_byte,span_bytes,span_utf16,byte_to_lsp,
lsp_to_byte}` return None for invalid boundaries or out-of-range coordinates.
Combining characters remain separate scalars and UTF-16 units; there is no
visual-column or grapheme rounding. EOF and exact line-end columns are valid.
LSP rejects nonexistent lines, columns beyond line end and surrogate interiors.
UTF-8/UTF-16 conversion can represent the CRLF interior, but LSP conversion
refuses it, exactly like Swift `SQLLSPPosition`.

`Statement::map_adapter_error(Option<usize>)` returns
`Result<Option<MappedAdapterPosition>, AdapterPositionError>`. Missing adapter
positions stay None; MySQL error text or line mentions do not invent a position.
A present zero is `ZeroIsNotOneBased` (the v3 transport already rejects zero).
Positive positions map from Unicode scalars into original byte and UTF-16
coordinates using the statement's captured source offsets, including removed
MySQL directives. Positions beyond statement end clamp to EOF like Swift,
with `clamped_to_end: true` reported explicitly. The lower-level
`adapter_error_byte`/`adapter_error_utf16` reproduce Swift's defensive clamp,
including zero, for shared reference assertions. UI callers should use the typed
optional mapping and retain source revision checks before displaying a marker.
No mapping should synthesize a marker when conversion or identity fails.

## Shared goldens and deferred verification

`protocol/fixtures/sql-execution/v1.json` is a new additive corpus derived from
`SQLScriptParserTests` and the Swift execution/command/LSP behavior. It does not
rewrite frozen parity baseline files or old goldens. Swift
`SQLExecutionFixturesTests` and Rust `sql::tests` assert identical selected text,
original byte/UTF-16 spans, delimiter hit areas, diagnostic messages/ranges,
fragment kinds/lines, scalar error mappings and LSP coordinates. New headless
GPUI callback assertions cover immutable selection capture and pre-helper
refusal of invalid/multiple statements, including MySQL routine pieces.

These cases are prepared and compiled only. The user deferred all test execution
to final integration. No runtime, database, native UI or credential coverage is
claimed. Task 2's native gates and all 171 target-desktop cells remain not-run.
Run at final integration, with completed-run summaries:

```sh
./scripts/gpui-prototype.sh test --locked -- sql::tests --test-threads=1
./scripts/gpui-prototype.sh test --locked --features native-smoke -- sql --test-threads=1
./scripts/test.sh --filter SQLExecutionFixturesTests --filter SQLScriptParserTests --filter WorkspaceCommandTests --filter SQLLanguageServiceTests
```

Use native Windows/Linux runners for their matching test targets and actual
Windows 11 / Ubuntu Wayland / Ubuntu X11 editors for caret, selection, CRLF,
Unicode, native input and script workflow acceptance. Compilation on a Mac
host establishes no native desktop behavior.
