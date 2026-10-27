package postgres

import (
	"context"

	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/resultsource"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type postgresSourceColumn struct {
	attribute int
	oid       uint32
	column    protocol.ResultSourceColumn
}

func readonlyPostgresSource(reason string) *protocol.ResultSource {
	return &protocol.ResultSource{Columns: []protocol.ResultSourceColumn{}, ReadOnlyReason: reason}
}

// PostgreSQL's row description, rather than labels in the SELECT list, proves
// each projected column's relation and attribute. The syntax gate additionally
// excludes rewrites such as joins and views that cannot identify one base row.
// Optional metadata is read only while idle, so a denied catalog read cannot
// abort the caller's existing transaction.
func preparePostgresResultSource(ctx context.Context, conn *pgx.Conn, sql string, fields []pgconn.FieldDescription) *protocol.ResultSource {
	selection, reason := resultsource.Parse(sql, "postgresql")
	if reason != "" {
		return readonlyPostgresSource(reason)
	}
	if transactionStatus(conn) != "idle" {
		return readonlyPostgresSource("Source-row actions require a result loaded outside an explicit transaction.")
	}
	if len(fields) == 0 || len(fields) > 4096 {
		return readonlyPostgresSource("The result has no supported source-column metadata.")
	}
	oid := fields[0].TableOID
	for _, field := range fields {
		if oid == 0 || field.TableOID != oid || field.TableAttributeNumber == 0 {
			return readonlyPostgresSource(resultsource.Unsupported)
		}
	}
	var schema, table, kind, persistence string
	var inherited bool
	err := conn.QueryRow(ctx, `SELECT n.nspname::pg_catalog.text,c.relname::pg_catalog.text,c.relkind::pg_catalog.text,c.relpersistence::pg_catalog.text,
EXISTS(SELECT 1 FROM pg_catalog.pg_inherits i WHERE i.inhparent=c.oid OR i.inhrelid=c.oid)
FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE c.oid=$1::pg_catalog.oid`, oid).Scan(&schema, &table, &kind, &persistence, &inherited)
	if err != nil {
		return readonlyPostgresSource("Source-table metadata is unavailable. The SQL result is read only.")
	}
	if table != selection.Table || selection.Schema != "" && schema != selection.Schema || kind != "r" || inherited || persistence == "t" {
		return readonlyPostgresSource("Source-row actions require one permanent base table without inheritance or partitioning.")
	}
	rows, err := conn.Query(ctx, `SELECT a.attnum::pg_catalog.int4,a.attname::pg_catalog.text,pg_catalog.format_type(a.atttypid,a.atttypmod),a.atttypid,
COALESCE((SELECT k.ordinality FROM pg_catalog.pg_index i CROSS JOIN LATERAL pg_catalog.unnest(i.indkey) WITH ORDINALITY k(attnum,ordinality)
WHERE i.indrelid=c.oid AND i.indisprimary AND i.indisvalid AND k.ordinality<=i.indnkeyatts AND k.attnum=a.attnum),0)::pg_catalog.int4,
(a.attgenerated<>'' OR a.attidentity='a'),pg_catalog.has_column_privilege(c.oid,a.attnum,'UPDATE')
FROM pg_catalog.pg_class c JOIN pg_catalog.pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
WHERE c.oid=$1::pg_catalog.oid ORDER BY a.attnum LIMIT 4097`, oid)
	if err != nil {
		return readonlyPostgresSource("Source-column metadata is unavailable. The SQL result is read only.")
	}
	metadata := []postgresSourceColumn{}
	for rows.Next() {
		var column postgresSourceColumn
		var generated, canUpdate bool
		if rows.Scan(&column.attribute, &column.column.Name, &column.column.NativeType, &column.oid, &column.column.PrimaryKey, &generated, &canUpdate) != nil {
			rows.Close()
			return readonlyPostgresSource("Source-column metadata could not be decoded. The SQL result is read only.")
		}
		column.column.TableIndex = len(metadata)
		column.column.Generated = generated
		column.column.Editable = canUpdate && !generated
		metadata = append(metadata, column)
	}
	rows.Close()
	if rows.Err() != nil || len(metadata) == 0 || len(metadata) > 4096 {
		return readonlyPostgresSource("Complete source-column metadata is unavailable. The SQL result is read only.")
	}
	// A source-row lookup uses the displayed PK as a bound typed predicate.
	// All originals must also round-trip for existing tokenless conflict checks.
	// Never reprepare or rewrite arbitrary SQL to obtain physical row evidence:
	// PostgreSQL may execute user-defined coercion routines during Parse itself.
	cache, loading := map[uint32]bool{}, map[uint32]bool{}
	needsStorage := false
	for index := range metadata {
		column := &metadata[index]
		lossless, err := postgresLosslessType(ctx, conn, column.oid, cache, loading)
		if err != nil {
			return readonlyPostgresSource("Source-column types are unavailable. The SQL result is read only.")
		}
		column.column.Editable = column.column.Editable && lossless
		needsStorage = needsStorage || !lossless
		if column.column.PrimaryKey > 0 && !lossless {
			return readonlyPostgresSource("The primary key's displayed type cannot identify an exact source row. Open the table directly.")
		}
	}
	source := mapPostgresResultSource(schema, table, fields, metadata)
	if source.Table != "" && len(fields) == len(metadata) && needsStorage {
		source.ReadOnlyReason = "These SQL result types need lossless storage evidence before editing. Open Source Row to edit the table safely."
	}
	return source
}

func mapPostgresResultSource(schema, table string, fields []pgconn.FieldDescription, metadata []postgresSourceColumn) *protocol.ResultSource {
	byAttribute := map[int]postgresSourceColumn{}
	primary := 0
	for _, column := range metadata {
		byAttribute[column.attribute] = column
		if column.column.PrimaryKey > primary {
			primary = column.column.PrimaryKey
		}
	}
	if primary == 0 {
		return readonlyPostgresSource("The source table has no primary key.")
	}
	source := &protocol.ResultSource{Schema: schema, Table: table, Columns: make([]protocol.ResultSourceColumn, len(fields))}
	seen, keys := map[int]bool{}, map[int]bool{}
	for index, field := range fields {
		column, ok := byAttribute[int(field.TableAttributeNumber)]
		if !ok || column.oid != field.DataTypeOID || seen[column.attribute] {
			return readonlyPostgresSource("Repeated, computed or changed source columns make this result read only.")
		}
		seen[column.attribute] = true
		source.Columns[index] = column.column
		if column.column.PrimaryKey > 0 {
			keys[column.column.PrimaryKey] = true
		}
	}
	for key := 1; key <= primary; key++ {
		if !keys[key] {
			return readonlyPostgresSource("Select every primary-key column to open the exact source row.")
		}
	}
	if len(fields) != len(metadata) {
		source.ReadOnlyReason = "Select every source column to edit this result. The source row can still be opened."
	} else {
		editable := false
		for _, column := range source.Columns {
			editable = editable || column.Editable
		}
		if !editable {
			source.ReadOnlyReason = "No source column is writable with the current permissions."
		}
	}
	return source
}

func samePostgresSourceFields(before, after []pgconn.FieldDescription) bool {
	if len(before) != len(after) {
		return false
	}
	for index, left := range before {
		right := after[index]
		if left.TableOID != right.TableOID || left.TableAttributeNumber != right.TableAttributeNumber || left.DataTypeOID != right.DataTypeOID || left.TypeModifier != right.TypeModifier || left.Name != right.Name {
			return false
		}
	}
	return true
}
