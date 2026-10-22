# Offline INSERT formatting v1

The optional `formatInsertsV1` hello capability adds an offline request to native
protocol v5. Existing command shapes and the protocol version remain unchanged.

`formatInserts` accepts `requestId` and `insert` only. The latter contains the
explicit target `engine` (`postgresql` or `mysql`), `schema`, `table`, unique
target `columns` (`{ "name": "..." }`) and rectangular `rows` of existing
`CellValue` objects. The caller must provide mappings for repeated source column
names. An empty schema deliberately produces an unqualified table name. No
session, connection, authorization or executable SQL is accepted.

The response is `{ "type": "insertSQL", "requestId": "...", "sql": "..." }`.
Formatting never opens a connection or executes SQL. It works with already
loaded rows while every database session is disconnected or busy.

Text values, including precise numbers, remain exact string literals. The user
chosen destination column controls any conversion when the user later executes
the copied statements. PostgreSQL uses escaped `E` literals and rejects text
containing a zero byte. MySQL uses UTF-8 hexadecimal `CONVERT` expressions whose
meaning is independent of SQL modes and the client character set. Binary values
use PostgreSQL `pg_catalog.decode` or MySQL hexadecimal binary literals. SQL NULL,
empty text, text `NULL`, text `DEFAULT`, DEFAULT and empty binary remain distinct.

Requests are limited to 1000 rows, 4096 columns, 100000 cells and 8 MiB of names
and values. SQL output is limited to 8 MiB; its entire serialized response must
also fit the 16 MiB protocol frame. Validation and formatting errors contain
fixed diagnostics only. `cases.json` is consumed by Go and native Swift non-UI
tests; its invalid commands also cover duplicate keys and strict wire names.
