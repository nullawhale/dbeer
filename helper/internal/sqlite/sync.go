package sqlite

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"math"
	"regexp"
	"strconv"
	"strings"

	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/syncplan"
)

func sqliteSyncLiteral(raw *string) (string, string, error) {
	if raw == nil {
		return "NULL", "null", nil
	}
	var value protocol.SQLiteValue
	if json.Unmarshal([]byte(*raw), &value) != nil || !value.Valid() {
		return "", "", syncplan.ErrInvalid
	}
	switch value.Type {
	case "null":
		return "NULL", "null", nil
	case "integer":
		if _, err := strconv.ParseInt(value.Value, 10, 64); err != nil {
			return "", "", err
		}
		return value.Value, "integer", nil
	case "real":
		bits, err := strconv.ParseUint(value.Value, 16, 64)
		if err != nil {
			return "", "", syncplan.ErrInvalid
		}
		f := math.Float64frombits(bits)
		// For nonzero non-NaN binary64 values, numeric equality identifies the
		// exact bit pattern. The storage-class predicate added by the caller
		// excludes equal INTEGER values. Both zero signs stay manual because IS
		// cannot distinguish them; do not assume a file normalized stored zero.
		if f == 0 || math.IsNaN(f) {
			return "", "", syncplan.ErrInvalid
		}
		literal, err := exactRealSQL(value.Value)
		return literal, "real", err
	case "text", "blob":
		b, err := base64.StdEncoding.DecodeString(value.Value)
		if err != nil {
			return "", "", err
		}
		literal := "X'" + hex.EncodeToString(b) + "'"
		if value.Type == "text" {
			literal = "CAST(" + literal + " AS TEXT)"
		}
		return literal, value.Type, nil
	default:
		// Unknown storage classes cannot establish an exact original-value guard.
		return "", "", syncplan.ErrInvalid
	}
}

// Source values do not serve as original-value guards. Build REAL assignments
// from their exact binary significand so SQLite decimal parsing cannot round a
// shortest decimal string to an adjacent floating-point value.
func sqliteSyncAssignmentLiteral(raw *string) (string, error) {
	if raw != nil {
		var value protocol.SQLiteValue
		if json.Unmarshal([]byte(*raw), &value) != nil || !value.Valid() {
			return "", syncplan.ErrInvalid
		}
		if value.Type == "real" {
			return exactRealSQL(value.Value)
		}
	}
	literal, _, err := sqliteSyncLiteral(raw)
	return literal, err
}

func RenderDataSynchronization(op syncplan.DataOperation) (string, error) {
	d := op.Descriptor
	if d.Engine != "sqlite" || d.Table.Schema != "main" || !d.Table.Valid() {
		return "", syncplan.ErrInvalid
	}
	target := "main." + quote(d.Table.Name)
	predicates := []string{}
	if op.Kind != "insert" {
		if len(op.Target) != len(d.Columns) {
			return "", syncplan.ErrInvalid
		}
		for i, c := range d.Columns {
			literal, kind, err := sqliteSyncLiteral(op.Target[i])
			if err != nil {
				return "", err
			}
			name := quote(c.Name)
			if kind == "null" {
				predicates = append(predicates, name+" IS NULL")
			} else {
				predicates = append(predicates, "typeof("+name+")='"+kind+"' AND "+name+" COLLATE BINARY IS "+literal)
			}
		}
	}
	if op.Kind == "delete" {
		return "DELETE FROM " + target + " WHERE " + strings.Join(predicates, " AND ") + ";", nil
	}
	if op.Kind != "insert" && op.Kind != "update" || op.Source == nil {
		return "", syncplan.ErrInvalid
	}
	names, values, assignments := []string{}, []string{}, []string{}
	seen := map[int]bool{}
	for _, m := range op.Mappings {
		if m.SourceIndex < 0 || m.SourceIndex >= len(op.Source) || m.TargetIndex < 0 || m.TargetIndex >= len(d.Columns) || seen[m.TargetIndex] {
			return "", syncplan.ErrInvalid
		}
		seen[m.TargetIndex] = true
		c := d.Columns[m.TargetIndex]
		if c.Generated {
			return "", syncplan.ErrInvalid
		}
		if op.Kind == "update" && (m.Key || sameCaptured(op.Source[m.SourceIndex], op.Target[m.TargetIndex])) {
			continue
		}
		literal, err := sqliteSyncAssignmentLiteral(op.Source[m.SourceIndex])
		if err != nil {
			return "", err
		}
		names = append(names, quote(c.Name))
		values = append(values, literal)
		assignments = append(assignments, quote(c.Name)+"="+literal)
	}
	if op.Kind == "update" {
		if len(assignments) == 0 {
			return "", syncplan.ErrInvalid
		}
		return "UPDATE " + target + " SET " + strings.Join(assignments, ",") + " WHERE " + strings.Join(predicates, " AND ") + ";", nil
	}
	if len(seen) != len(d.Columns) {
		return "", syncplan.ErrInvalid
	}
	return "INSERT INTO " + target + " (" + strings.Join(names, ",") + ") VALUES (" + strings.Join(values, ",") + ");", nil
}
func sameCaptured(a, b *string) bool { return a == nil && b == nil || a != nil && b != nil && *a == *b }

var sqliteCreateName = regexp.MustCompile("(?is)^CREATE\\s+TABLE\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?(?:main\\.)?(\"(?:\"\"|[^\"])+\"|`(?:``|[^`])+`|\\[[^\\]]+\\]|[A-Za-z_][A-Za-z0-9_]*)\\s*\\(")

func RenderSynchronizationSchema(ctx context.Context, op syncplan.SchemaOperation) (string, string, error) {
	if err := ctx.Err(); err != nil {
		return "", "", err
	}
	manual := func(reason string) (string, string, error) { return "", reason, nil }
	if op.Action != "create" || op.Ref.Kind != "table" || op.Ref.Schema != "main" {
		return manual("This SQLite transformation requires an explicitly reviewed structure draft or manual SQL.")
	}
	table, ok := syncplan.SchemaTable(op.Source, op.Ref)
	if !ok {
		return manual("The table definition was not captured.")
	}
	for _, option := range table.Options.Items {
		if option.Name != "definition" {
			continue
		}
		raw := option.Value
		m := sqliteCreateName.FindStringSubmatch(raw)
		if m == nil {
			return manual("The table definition cannot be preserved by the SQLite generator.")
		}
		name := m[1]
		switch name[0] {
		case '"':
			name = strings.ReplaceAll(name[1:len(name)-1], `""`, `"`)
		case '`':
			name = strings.ReplaceAll(name[1:len(name)-1], "``", "`")
		case '[':
			name = name[1 : len(name)-1]
		}
		if name != op.Ref.Name {
			return manual("Mapped SQLite table names require manual definition rewriting.")
		}
		return raw + ";", "", nil
	}
	return manual("The original SQLite table definition is unavailable.")
}
