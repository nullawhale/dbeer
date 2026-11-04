package sqlite

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	tc "dbeer/helper/internal/tablecapture"
)

func (s *Session) DescribeTable(ctx context.Context, t tc.Table) (tc.Descriptor, error) {
	d := tc.Descriptor{Engine: "sqlite", Table: t, Columns: []tc.Column{}}
	if !t.Valid() || t.Schema != "main" {
		return d, tc.ErrInvalid
	}
	schema, _, err := s.query(ctx, `SELECT type,sql FROM main.sqlite_schema WHERE name=?`, t.Name)
	if err != nil {
		return d, err
	}
	if len(schema) != 1 || cellText(schema[0][0]) != "table" || strings.HasPrefix(strings.ToUpper(cellText(schema[0][1])), "CREATE VIRTUAL") {
		return d, tc.ErrUnsupported
	}
	columns, err := s.tableInfo(ctx, "main", t.Name)
	if err != nil {
		return d, err
	}
	for _, c := range columns {
		if c.Hidden == 1 {
			continue
		}
		typ := c.NativeType
		if typ == "" {
			typ = "untyped"
		}
		definition, _ := json.Marshal(c)
		d.Columns = append(d.Columns, tc.Column{Index: len(d.Columns), Name: c.Name, NativeType: typ, TypeLabel: typ, Encoding: "sqliteValue", PrimaryKey: c.PrimaryKey, Numeric: false, Nullable: !c.NotNull, Generated: c.Hidden > 1, Definition: definition})
	}
	d.Definition, _ = json.Marshal(schema)
	return d, d.Seal()
}
func (s *Session) CaptureTable(ctx context.Context, spec tc.Spec, sink tc.Sink) (tc.Descriptor, tc.Outcome, error) {
	start := time.Now().UTC().Format(time.RFC3339Nano)
	out := tc.Outcome{StartedAt: start, Engine: "sqlite", Table: spec.Table, Consistency: "repeatableRead", Rendering: "sqliteValue", ReadLimit: spec.ReadLimit, PartialReasons: []string{}, FullOriginals: true}
	if s.TransactionStatus() != "idle" {
		return tc.Descriptor{}, out, tc.ErrInvalid
	}
	if err := s.exec(ctx, "BEGIN"); err != nil {
		return tc.Descriptor{}, out, err
	}
	defer func() { _ = s.exec(context.Background(), "ROLLBACK") }()
	d, err := s.DescribeTable(ctx, spec.Table)
	if err != nil {
		return d, out, err
	}
	if err = tc.Validate(d, spec); err != nil {
		return d, out, err
	}
	names := []string{}
	for _, name := range spec.Columns {
		names = append(names, quote(name))
	}
	out.FullOriginals = len(spec.Columns) == len(d.Columns)
	where := []string{}
	args := []any{}
	for _, f := range spec.Filters {
		col := quote(f.Column)
		switch f.Operator {
		case "isNull":
			where = append(where, col+" IS NULL")
		case "isNotNull":
			where = append(where, col+" IS NOT NULL")
		default:
			op := map[string]string{"eq": "=", "ne": "<>", "lt": "<", "lte": "<=", "gt": ">", "gte": ">=", "contains": "LIKE"}[f.Operator]
			if op == "" {
				return d, out, tc.ErrInvalid
			}
			where = append(where, col+" "+op+" ?")
			v := *f.Value
			if f.Operator == "contains" {
				v = "%" + v + "%"
			}
			args = append(args, v)
		}
	}
	sql := "SELECT " + strings.Join(names, ",") + " FROM main." + quote(spec.Table.Name)
	if len(where) > 0 {
		sql += " WHERE " + strings.Join(where, " AND ")
	}
	sql += " LIMIT ?"
	args = append(args, spec.ReadLimit+1)
	rows, _, err := s.query(ctx, sql, args...)
	if err != nil {
		return d, out, err
	}
	for i, row := range rows {
		out.ObservedAtLeast++
		if i == spec.ReadLimit {
			out.PartialReasons = append(out.PartialReasons, "readLimit")
			break
		}
		values := make([]*string, len(row))
		for j, v := range row {
			if v.Type != "null" {
				b, e := json.Marshal(v)
				if e != nil {
					return d, out, e
				}
				text := string(b)
				values[j] = &text
			}
		}
		if err = sink.Row(values); err != nil {
			return d, out, err
		}
		out.StoredRows++
	}
	if err = s.exec(ctx, "COMMIT"); err != nil {
		return d, out, err
	}
	out.FinishedAt = time.Now().UTC().Format(time.RFC3339Nano)
	out.DescriptorDigest = d.Digest
	return d, out, nil
}
