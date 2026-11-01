# Typed query parameters v1

`queryParametersV1` is additive to protocol version 5. It is advertised in the
hello response and in PostgreSQL/MySQL connection capabilities. Other engines
reject supplied parameters, including definitions unused by the statement.

Execute commands and execute operations in `operation.assess` optionally carry
`parameters`, an array of `{ "name": "customer_id", "type": "integer", "value": "42" }`.
Each object has exactly these three fields. `value` must be a string or explicit
JSON `null`; omission is invalid. Null remains distinct from empty text and the
text `NULL`. Parameter names are case-sensitive ASCII identifiers matching
`[A-Za-z_][A-Za-z0-9_]*`, at most 64 bytes. At most 128 distinct definitions are
accepted. Each value and the sum of all value bytes are limited to 1 MiB.
MySQL repeated placeholders additionally have an 8 MiB total bound-value budget
to limit wire-packet amplification. With no definitions, existing SQL is passed
through unchanged, including PostgreSQL array slices containing colons.

Supported types and non-null value formats:

| Type | Format |
| --- | --- |
| `text` | UTF-8 text, including empty text; NUL is rejected |
| `integer` | `[+-]?[0-9]+`, within signed 64-bit range |
| `decimal` | `[+-]?[0-9]+(\.[0-9]+)?`; exact, no exponent |
| `boolean` | `true` or `false` |
| `date` | Valid Gregorian `YYYY-MM-DD`, year 0001 through 9999 |
| `timestamp` | `YYYY-MM-DD HH:mm:ss` with optional 1–6 fractional digits; no time zone |

MySQL decimal definitions are additionally limited to 65 total decimal digits
and 30 fractional digits. They bind as strings with a matching `DECIMAL(p,s)`
cast, preserving precision without binary floating-point conversion.

SQL uses named placeholders such as `:customer_id`. Strings, quoted identifiers,
comments, PostgreSQL dollar strings and `::` casts, and MySQL `:=` assignments
do not contain placeholders. Repeated names reuse their value. Missing
definitions, duplicate definitions, mixed native `$1`/`?` placeholders, executable
MySQL comments, and ambiguous backslash quoting are rejected. Valid unused
definitions are allowed so that callers can execute selected statements from a
saved script. Every supplied definition is validated, even when unused.

Each command continues to execute one statement on its owning physical session.
PostgreSQL uses extended protocol parameter binding with explicit built-in type
OIDs. MySQL uses prepared statements. Parameter values are never inserted into
SQL text. Assessment authorization includes all definition names, types and
values, including unused definitions. Policy classification masks placeholder
names as opaque constant tokens with identical source offsets; parameter names
cannot be interpreted as SQL keywords. Parameterized result sets do not infer editable row
sources; rewritten PostgreSQL error positions are omitted.

`query-parameters-v1.json` covers all six types, repeated and unused definitions,
null versus empty text, command/assessment shapes, and invalid bindings.
