package postgres

import (
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/syncplan"
	tc "dbeer/helper/internal/tablecapture"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
)

// RenderDataSynchronization builds SQL from typed, retained catalog facts. The
// binary send guards distinguish stored values without collation or output GUCs.
func RenderDataSynchronization(op syncplan.DataOperation) (string, error) {
	if op.Descriptor.Engine != "postgresql" || !op.Descriptor.Table.Valid() {
		return "", syncplan.ErrInvalid
	}
	q := pgx.Identifier{op.Descriptor.Table.Schema, op.Descriptor.Table.Name}.Sanitize()
	columns := op.Descriptor.Columns
	if op.Target != nil && len(op.Target) != len(columns) {
		return "", syncplan.ErrInvalid
	}
	guard := []string{}
	if op.Kind != "insert" {
		if op.Target == nil {
			return "", syncplan.ErrInvalid
		}
		for i, c := range columns {
			literal, send, e := postgresSynchronizationLiteral(c, op.Target[i])
			if e != nil {
				return "", e
			}
			name := pgx.Identifier{c.Name}.Sanitize()
			if op.Target[i] == nil {
				guard = append(guard, name+" IS NULL")
			} else {
				guard = append(guard, "pg_catalog."+send+"("+name+") IS NOT DISTINCT FROM pg_catalog."+send+"("+literal+")")
			}
		}
	}
	if op.Kind == "delete" {
		return "DELETE FROM ONLY " + q + " WHERE " + strings.Join(guard, " AND ") + ";", nil
	}
	if op.Kind != "insert" && op.Kind != "update" || op.Source == nil {
		return "", syncplan.ErrInvalid
	}
	names, values, assignments := []string{}, []string{}, []string{}
	seen := map[int]bool{}
	identity := false
	for _, m := range op.Mappings {
		if m.SourceIndex < 0 || m.SourceIndex >= len(op.Source) || m.TargetIndex < 0 || m.TargetIndex >= len(columns) || seen[m.TargetIndex] {
			return "", syncplan.ErrInvalid
		}
		seen[m.TargetIndex] = true
		c := columns[m.TargetIndex]
		value := op.Source[m.SourceIndex]
		if c.Generated {
			if op.Kind == "insert" || !synchronizationEqual(value, op.Target[m.TargetIndex]) {
				return "", syncplan.ErrInvalid
			}
			continue
		}
		if op.Kind == "update" && (m.Key || synchronizationEqual(value, op.Target[m.TargetIndex])) {
			continue
		}
		if c.Identity && op.Kind == "update" {
			return "", syncplan.ErrInvalid
		}
		literal, _, e := postgresSynchronizationLiteral(c, value)
		if e != nil {
			return "", e
		}
		name := pgx.Identifier{c.Name}.Sanitize()
		names = append(names, name)
		values = append(values, literal)
		assignments = append(assignments, name+" = "+literal)
		identity = identity || c.Identity
	}
	if op.Kind == "update" {
		if len(assignments) == 0 {
			return "", syncplan.ErrInvalid
		}
		return "UPDATE ONLY " + q + " SET " + strings.Join(assignments, ", ") + " WHERE " + strings.Join(guard, " AND ") + ";", nil
	}
	for i, c := range columns {
		if !c.Generated && !seen[i] || c.Generated {
			return "", syncplan.ErrInvalid
		}
	}
	if len(names) == 0 {
		return "", syncplan.ErrInvalid
	}
	override := ""
	if identity {
		override = " OVERRIDING SYSTEM VALUE"
	}
	prefix := ""
	if identity {
		prefix = "-- Explicit identity values do not advance the sequence; review its next value before later inserts.\n"
	}
	return prefix + "INSERT INTO " + q + " (" + strings.Join(names, ", ") + ")" + override + " VALUES (" + strings.Join(values, ", ") + ");", nil
}

func synchronizationEqual(a, b *string) bool {
	return a == nil && b == nil || a != nil && b != nil && *a == *b
}

func postgresSynchronizationLiteral(c tc.Column, value *string) (literal, send string, err error) {
	var column sc.Column
	if json.Unmarshal(c.Definition, &column) != nil || column.Type.State != "known" || column.Type.Value == nil {
		return "", "", syncplan.ErrInvalid
	}
	u := column.Type.Value
	if u.Kind != "builtin" || u.Ref.Schema != "pg_catalog" {
		return "", "", syncplan.ErrInvalid
	}
	functions := map[string]string{"bool": "boolsend", "bytea": "byteasend", "int2": "int2send", "int4": "int4send", "int8": "int8send", "text": "textsend", "varchar": "varcharsend", "bpchar": "bpcharsend", "numeric": "numeric_send", "uuid": "uuid_send", "json": "json_send", "jsonb": "jsonb_send", "float4": "float4send", "float8": "float8send", "date": "date_send", "time": "time_send", "timetz": "timetz_send", "timestamp": "timestamp_send", "timestamptz": "timestamptz_send", "interval": "interval_send"}
	send = functions[u.Ref.Name]
	if send == "" || c.ValueComparison != "" {
		return "", "", syncplan.ErrInvalid
	}
	if value == nil {
		return "NULL", send, nil
	}
	if c.Encoding == "base64" {
		if u.Ref.Name != "bytea" {
			return "", "", syncplan.ErrInvalid
		}
		b, e := base64.StdEncoding.DecodeString(*value)
		if e != nil {
			return "", "", syncplan.ErrInvalid
		}
		return "pg_catalog.decode('" + hex.EncodeToString(b) + "', 'hex')", send, nil
	}
	if c.Encoding != "" || u.Ref.Name == "bytea" || !utf8.ValidString(*value) || strings.ContainsRune(*value, 0) {
		return "", "", syncplan.ErrInvalid
	}
	return postgresTextLiteral(*value) + "::" + pgx.Identifier{"pg_catalog", u.Ref.Name}.Sanitize(), send, nil
}
