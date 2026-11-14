package mariadb

import (
	dt "dbeer/helper/internal/datatransfer"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/syncplan"
	tc "dbeer/helper/internal/tablecapture"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"strconv"
	"strings"
	"unicode/utf8"
)

// RenderDataSynchronization uses hexadecimal literals and binary original
// guards, independent of text collation, SQL quoting mode and client charset.
func RenderDataSynchronization(op syncplan.DataOperation) (string, error) {
	if op.Descriptor.Engine != "mariadb" || !op.Descriptor.Table.Valid() {
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
			_, kind, e := mariaDBSynchronizationLiteral(c, op.Target[i])
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
			if op.Kind == "insert" || !mariaDBSynchronizationEqual(value, op.Target[m.TargetIndex]) {
				return "", syncplan.ErrInvalid
			}
			continue
		}
		if op.Kind == "update" && (m.Key || mariaDBSynchronizationEqual(value, op.Target[m.TargetIndex])) {
			continue
		}
		if c.Identity && (op.Kind == "update" || value == nil || *value == "0") {
			return "", syncplan.ErrInvalid
		}
		literal, _, e := mariaDBSynchronizationLiteral(c, value)
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

func mariaDBSynchronizationEqual(a, b *string) bool {
	return a == nil && b == nil || a != nil && b != nil && *a == *b
}

func mariaDBSynchronizationLiteral(c tc.Column, value *string) (literal, kind string, err error) {
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
		if !mariaDBBinaryType(kind) || kind == "bit" {
			return "", "", syncplan.ErrInvalid
		}
		b, e := base64.StdEncoding.DecodeString(*value)
		if e != nil {
			return "", "", syncplan.ErrInvalid
		}
		return "X'" + hex.EncodeToString(b) + "'", kind, nil
	}
	if c.Encoding != "" || mariaDBBinaryType(kind) || !utf8.ValidString(*value) {
		return "", "", syncplan.ErrInvalid
	}
	literal = "CONVERT(X'" + hex.EncodeToString([]byte(*value)) + "' USING utf8mb4)"
	if c.Numeric {
		template, normalized, e := flowNumericParameter(kind, *value)
		if e != nil {
			return "", "", syncplan.ErrInvalid
		}
		literal = "CONVERT(X'" + hex.EncodeToString([]byte(normalized)) + "' USING utf8mb4)"
		literal = strings.Replace(template, "?", literal, 1)
	}
	return literal, kind, nil
}

// MariaDB supports 38 fractional digits. This cast preserves the exact token.
func flowNumericParameter(kind, value string) (string, string, error) {
	canonical, p, scale, e := dt.Decimal(value)
	if e != nil || p > 65 || scale > 38 {
		return "", "", tc.ErrInvalid
	}
	switch kind {
	case "tinyint", "smallint", "mediumint", "int", "integer", "bigint", "decimal", "numeric":
	default:
		return "", "", tc.ErrUnsupported
	}
	return "CAST(? AS DECIMAL(65," + strconv.Itoa(scale) + "))", canonical, nil
}
func flowLiteral(value protocol.CellValue) (string, error) {
	if !value.Valid(false) {
		return "", tc.ErrInvalid
	}
	if value.Kind == "null" {
		return "NULL", nil
	}
	if value.Value == nil {
		return "", tc.ErrInvalid
	}
	if value.Kind == "binary" {
		b, e := base64.StdEncoding.DecodeString(*value.Value)
		if e != nil || base64.StdEncoding.EncodeToString(b) != *value.Value {
			return "", tc.ErrInvalid
		}
		return "X'" + hex.EncodeToString(b) + "'", nil
	}
	if value.Kind != "text" || !utf8.ValidString(*value.Value) {
		return "", tc.ErrInvalid
	}
	return "CONVERT(X'" + hex.EncodeToString([]byte(*value.Value)) + "' USING utf8mb4)", nil
}
