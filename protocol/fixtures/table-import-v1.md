# Table import v1

`tableImportV1` is additive to protocol version 5. It is advertised in hello and
PostgreSQL/MySQL connection capabilities. Imports use a fresh dedicated
connection with `sessionPurpose: "import"`. This session accepts import commands
and import operation assessments, never arbitrary SQL or grid edits. A SQL tab
session cannot execute an import. Existing grid primary-key requirements remain
unchanged; import itself does not require a primary key.

The native client parses a bounded UTF-8 CSV/TSV file into a snapshot, maps source
fields to target columns, and sends the mapped values. The helper receives no
file path and does not open files.

Commands carry `tableImport`:

- `import.describe`: `{schema, table}` only.
- `import.preview`, `import.apply`: `{schema, table, fingerprint, columns, rows}`.
  `columns` contains mapped target names in row-value order; `rows` is a matrix
  of existing cell values: text, canonical Base64 binary, or SQL NULL. DEFAULT
  cells are rejected. Omitted target columns use server defaults.
- `operation.assess` can contain an `import.apply` operation with the identical
  `tableImport` payload. The immutable authorization includes all rows, mapped
  columns and the fingerprint. Apply is a write: readonly policy denies it and
  production policy requires confirmation.

Limits are 10,000 rows, 256 mapped columns, 100,000 cells and 4 MiB of total
encoded UTF-8 text/Base64 values. Names are nonempty UTF-8, at most 1,024 bytes,
without NUL. Text values also reject NUL. The enclosing protocol frame remains
limited to 16 MiB. All object shapes are closed; duplicate fields/target columns
and omitted cell values are rejected. Up to 4,096 target columns can be
described, with type descriptions limited to 65,536 bytes, a 4 MiB aggregate
metadata-facts budget before hashing, and an 8 MiB metadata reply budget. Large
metadata is rejected rather than truncated.

The fingerprint is a lowercase 64-character SHA256 of ordered table/column
facts, including type, nullability, default expressions, generated/identity
attributes, collation and effective insert permission. PostgreSQL also includes
the relation OID. MySQL includes engine and creation metadata, but cannot prove
a physical drop/recreate identity from ordinary information-schema privileges.
Defaults are read as metadata and never evaluated during preview.

Describe and preview hold a DDL-blocking relation/metadata lock inside a
transaction, read metadata, and roll back without executing INSERT. This is
compatible with server readonly sessions. Apply locks and rechecks the same
fingerprint, checks required omitted columns and the mapping, and inserts every
row using driver-bound parameters in one transaction. Lock waits are limited to
five seconds in the dedicated session. Mapped generated, unsupported or
non-writable columns are rejected. PostgreSQL currently supports ordinary
nonpartitioned base tables and known built-in scalar/bytea column types; mapped
custom types, enums and arrays are deferred. MySQL requires InnoDB and supports
common scalar, binary, JSON and ENUM/SET types. Strict conversion and any MySQL
warning fail the entire batch.

Replies retain request/session/query correlation and follow `query.started`:

- `import.describe.result`: `tableImport: {columns, fingerprint}`.
- `import.preview.result`: `tableImport: {fingerprint, rowCount, sql}`. SQL is one
  bounded INSERT template with placeholders, never literal data values.
- `import.apply.result`: `tableImport: {rowCount}`, after confirmed COMMIT.

Success replies include `connected: true` and `transactionStatus: "idle"`.
Row conversion/constraint failures roll back and may include only
`tableImport: {row}` on the error; `row` is the 1-based data-row index excluding
the header. `sqlNotExecuted` is true only before any INSERT was attempted.
Pre-COMMIT errors/cancellation never claim committed rows. A lost COMMIT
acknowledgement closes the session and returns `outcomeUnknown: true`; it is
never retried automatically. The user must verify the target before another
import. Transactional guarantees concern the imported table rows; ordinary
database trigger/default behavior remains under server control.

`table-import-v1.json` contains shared command and reply examples, NULL/empty/
text-NULL/binary distinctions, a row error and an unknown-COMMIT outcome.
