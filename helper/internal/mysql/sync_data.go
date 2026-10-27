package mysql

import (
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/syncplan"
	tc "dbeer/helper/internal/tablecapture"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"strings"
	"unicode/utf8"
)

// RenderDataSynchronization uses hexadecimal literals and binary original
// guards, independent of text collation, SQL quoting mode and client charset.
func RenderDataSynchronization(op syncplan.DataOperation) (string, error) {
	if op.Descriptor.Engine != "mysql" || !op.Descriptor.Table.Valid() {
		return "", syncplan.ErrInvalid
	}
	q := QuoteIdentifier(op.Descriptor.Table.Schema) + "." + QuoteIdentifier(op.Descriptor.Table.Name)
	columns := op.Descriptor.Columns
	if op.Kind == "update" {
		for _, c := range columns {
			var raw []*string
			if json.Unmarshal(c.Definition, &raw) != nil || len(raw) < 7 || raw[6] == nil {
				return "", syncplan.ErrInvalid
			}
			if strings.Contains(strings.ToLower(*raw[6]), "on update") {
				return "", syncplan.ErrInvalid
			}
		}
	}
	if op.Target != nil && len(op.Target) != len(columns) {
		return "", syncplan.ErrInvalid
	}
	predicates := []string{}
	if op.Kind != "insert" {
		if op.Target == nil {
			return "", syncplan.ErrInvalid
		}
		for i, c := range columns {
			_, kind, e := mysqlSynchronizationLiteral(c, op.Target[i])
			if e != nil {
				return "", e
			}
			name := QuoteIdentifier(c.Name)
			if op.Target[i] == nil {
				predicates = append(predicates, name+" IS NULL")
				continue
			}
			expression := name
			value := []byte(*op.Target[i])
			if c.Encoding == "base64" {
				value, e = base64.StdEncoding.DecodeString(*op.Target[i])
				if e != nil {
					return "", syncplan.ErrInvalid
				}
			} else {
				if kind == "char" {
					return "", syncplan.ErrInvalid
				}
				expression = "CAST(" + name + " AS CHAR CHARACTER SET utf8mb4)"
			}
			predicates = append(predicates, "CAST("+expression+" AS BINARY) <=> X'"+hex.EncodeToString(value)+"'")
		}
	}
	if op.Kind == "delete" {
		return "DELETE FROM " + q + " WHERE " + strings.Join(predicates, " AND ") + " LIMIT 1;", nil
	}
	if op.Kind != "insert" && op.Kind != "update" || op.Source == nil {
		return "", syncplan.ErrInvalid
	}
	names, values, assignments := []string{}, []string{}, []string{}
	seen := map[int]bool{}
	for _, m := range op.Mappings {
		if m.SourceIndex < 0 || m.SourceIndex >= len(op.Source) || m.TargetIndex < 0 || m.TargetIndex >= len(columns) || seen[m.TargetIndex] {
			return "", syncplan.ErrInvalid
		}
		seen[m.TargetIndex] = true
		c := columns[m.TargetIndex]
		value := op.Source[m.SourceIndex]
		if c.Generated {
			if op.Kind == "insert" || !mysqlSynchronizationEqual(value, op.Target[m.TargetIndex]) {
				return "", syncplan.ErrInvalid
			}
			continue
		}
		if op.Kind == "update" && (m.Key || mysqlSynchronizationEqual(value, op.Target[m.TargetIndex])) {
			continue
		}
		if c.Identity && (op.Kind == "update" || value == nil || *value == "0") {
			return "", syncplan.ErrInvalid
		}
		literal, _, e := mysqlSynchronizationLiteral(c, value)
		if e != nil {
			return "", e
		}
		name := QuoteIdentifier(c.Name)
		names = append(names, name)
		values = append(values, literal)
		assignments = append(assignments, name+" = "+literal)
	}
	if op.Kind == "update" {
		if len(assignments) == 0 {
			return "", syncplan.ErrInvalid
		}
		return "UPDATE " + q + " SET " + strings.Join(assignments, ", ") + " WHERE " + strings.Join(predicates, " AND ") + " LIMIT 1;", nil
	}
	for i, c := range columns {
		if !c.Generated && !seen[i] || c.Generated {
			return "", syncplan.ErrInvalid
		}
	}
	if len(names) == 0 {
		return "", syncplan.ErrInvalid
	}
	return "INSERT INTO " + q + " (" + strings.Join(names, ", ") + ") VALUES (" + strings.Join(values, ", ") + ");", nil
}

func mysqlSynchronizationEqual(a, b *string) bool {
	return a == nil && b == nil || a != nil && b != nil && *a == *b
}

func mysqlSynchronizationLiteral(c tc.Column, value *string) (literal, kind string, err error) {
	var native struct {
		Type               sc.TypeUse
		Charset, Collation string
	}
	if json.Unmarshal([]byte(c.NativeType), &native) != nil || native.Type.Modifiers.State != "known" {
		return "", "", syncplan.ErrInvalid
	}
	kind = native.Type.Ref.Name
	allowed := map[string]bool{"tinyint": true, "smallint": true, "mediumint": true, "int": true, "bigint": true, "decimal": true, "varchar": true, "tinytext": true, "text": true, "mediumtext": true, "longtext": true, "binary": true, "varbinary": true, "tinyblob": true, "blob": true, "mediumblob": true, "longblob": true, "date": true, "datetime": true, "time": true, "year": true, "json": true}
	if !allowed[kind] || c.ValueComparison != "" {
		return "", "", syncplan.ErrInvalid
	}
	if value == nil {
		return "NULL", kind, nil
	}
	if c.Encoding == "base64" {
		if !binaryType(kind) || kind == "bit" {
			return "", "", syncplan.ErrInvalid
		}
		b, e := base64.StdEncoding.DecodeString(*value)
		if e != nil {
			return "", "", syncplan.ErrInvalid
		}
		return "X'" + hex.EncodeToString(b) + "'", kind, nil
	}
	if c.Encoding != "" || binaryType(kind) || !utf8.ValidString(*value) {
		return "", "", syncplan.ErrInvalid
	}
	literal = "CONVERT(X'" + hex.EncodeToString([]byte(*value)) + "' USING utf8mb4)"
	if c.Numeric {
		template, normalized, e := browseNumericParameter(kind, *value)
		if e != nil {
			return "", "", syncplan.ErrInvalid
		}
		literal = "CONVERT(X'" + hex.EncodeToString([]byte(normalized)) + "' USING utf8mb4)"
		literal = strings.Replace(template, "?", literal, 1)
	}
	return literal, kind, nil
}
