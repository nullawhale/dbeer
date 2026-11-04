package sqlite

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"reflect"
	"strconv"
	"strings"
	"time"

	"dbeer/helper/internal/protocol"
	lib "zombiezen.com/go/sqlite"
)

func cellValue(c protocol.CellValue) (protocol.SQLiteValue, error) {
	if c.Kind == "null" {
		return protocol.SQLiteValue{Type: "null"}, nil
	}
	if c.Value == nil {
		return protocol.SQLiteValue{}, errors.New("Missing cell value.")
	}
	v := *c.Value
	switch c.Kind {
	case "text":
		return stringValue(v), nil
	case "binary":
		return protocol.SQLiteValue{Type: "blob", Value: v}, nil
	case "sqliteInteger":
		if _, err := strconv.ParseInt(v, 10, 64); err != nil {
			return protocol.SQLiteValue{}, err
		}
		return protocol.SQLiteValue{Type: "integer", Value: v}, nil
	case "sqliteReal":
		if len(v) != 16 {
			return protocol.SQLiteValue{}, errors.New("Invalid REAL value.")
		}
		if _, err := strconv.ParseUint(v, 16, 64); err != nil {
			return protocol.SQLiteValue{}, err
		}
		return protocol.SQLiteValue{Type: "real", Value: v}, nil
	case "sqliteText":
		return protocol.SQLiteValue{Type: "text", Value: v}, nil
	case "sqliteBlob":
		return protocol.SQLiteValue{Type: "blob", Value: v}, nil
	}
	return protocol.SQLiteValue{}, errors.New("Invalid SQLite cell type.")
}
func valueSQL(v protocol.SQLiteValue) (string, error) {
	switch v.Type {
	case "null":
		return "NULL", nil
	case "integer":
		if _, e := strconv.ParseInt(v.Value, 10, 64); e != nil {
			return "", e
		}
		return v.Value, nil
	case "real":
		return exactRealSQL(v.Value)
	case "blob", "text":
		b, e := base64.StdEncoding.DecodeString(v.Value)
		if e != nil {
			return "", e
		}
		s := "X'" + hex.EncodeToString(b) + "'"
		if v.Type == "text" {
			s = "CAST(" + s + " AS TEXT)"
		}
		return s, nil
	}
	return "", errors.New("Invalid SQLite storage class.")
}

type rowPlan struct {
	sql       string
	args      []any
	original  []protocol.SQLiteValue
	predicate string
	keys      []any
}

func (s *Session) changes(ctx context.Context, c protocol.Command) (response protocol.Response) {
	r := c.Changes
	if r == nil || !r.Valid() || r.Schema != "main" || s.TransactionStatus() != "idle" {
		return s.fail(c, ctx, errors.New("Invalid changes request."))
	}
	applying := c.Type == "changes.apply"
	if applying && s.readOnly {
		return s.fail(c, ctx, errors.New("The SQLite connection is readonly."))
	}
	inTransaction := false
	rollback := func() {
		if inTransaction {
			recovery, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := s.exec(recovery, "ROLLBACK"); err != nil {
				s.Close()
			}
			inTransaction = false
		}
	}
	defer func() { rollback(); response.TransactionStatus = s.TransactionStatus(); response.Connected = !s.closed }()
	if applying {
		if err := s.exec(ctx, "BEGIN IMMEDIATE"); err != nil {
			return s.fail(c, ctx, err)
		}
		inTransaction = true
	}
	cols, err := s.tableInfo(ctx, "main", r.Table)
	if err != nil {
		return s.fail(c, ctx, err)
	}
	visible := []columnInfo{}
	byName := map[string]int{}
	pk := []int{}
	for _, col := range cols {
		if col.Hidden == 1 {
			continue
		}
		byName[col.Name] = len(visible)
		if col.PrimaryKey > 0 {
			pk = append(pk, len(visible))
		}
		visible = append(visible, col)
	}
	if !s.editableTable(ctx, r.Table, cols) || len(visible) != len(r.Columns) {
		return s.fail(c, ctx, errors.New("The SQLite table is not editable."))
	}
	for i, col := range visible {
		native := col.NativeType
		if native == "" {
			native = "dynamic"
		}
		if r.Columns[i].Name != col.Name || r.Columns[i].NativeType != native || r.Columns[i].Engine != "sqlite" {
			return s.fail(c, ctx, errors.New("The table structure changed."))
		}
	}
	qualified := "main." + quote(r.Table)
	plans := []rowPlan{}
	previews := []string{}
	for _, change := range r.Changes {
		plan := rowPlan{}
		literals := []string{}
		parts := []string{}
		if change.Kind != "insert" {
			for _, v := range change.Original {
				typed, e := cellValue(v)
				if e != nil {
					return s.fail(c, ctx, e)
				}
				plan.original = append(plan.original, typed)
			}
			for _, i := range pk {
				if plan.original[i].Type == "null" {
					return s.fail(c, ctx, errors.New("A NULL key cannot identify a row."))
				}
				parts = append(parts, quote(visible[i].Name)+" IS ?")
				plan.keys = append(plan.keys, plan.original[i])
			}
			plan.predicate = strings.Join(parts, " AND ")
		}
		names := []string{}
		sets := []string{}
		placeholders := []string{}
		literalSets := []string{}
		for _, a := range change.Values {
			index, ok := byName[a.Column]
			if !ok || visible[index].Hidden != 0 {
				return s.fail(c, ctx, errors.New("The column is not writable."))
			}
			names = append(names, quote(a.Column))
			if a.Value.Kind == "default" {
				d := visible[index].Default
				if d == nil {
					sets = append(sets, quote(a.Column)+"=NULL")
					literalSets = append(literalSets, quote(a.Column)+"=NULL")
					placeholders = append(placeholders, "NULL")
					literals = append(literals, "NULL")
				} else {
					sets = append(sets, quote(a.Column)+"="+*d)
					literalSets = append(literalSets, quote(a.Column)+"="+*d)
					placeholders = append(placeholders, *d)
					literals = append(literals, *d)
				}
				continue
			}
			value, e := cellValue(a.Value)
			if e != nil {
				return s.fail(c, ctx, e)
			}
			literal, e := valueSQL(value)
			if e != nil {
				return s.fail(c, ctx, e)
			}
			plan.args = append(plan.args, value)
			sets = append(sets, quote(a.Column)+"=?")
			literalSets = append(literalSets, quote(a.Column)+"="+literal)
			placeholders = append(placeholders, "?")
			literals = append(literals, literal)
		}
		previewWhere := []string{}
		for j, i := range pk {
			literal, e := valueSQL(plan.originalAt(change.Kind, i))
			if change.Kind == "insert" {
				break
			}
			if e != nil {
				return s.fail(c, ctx, e)
			}
			previewWhere = append(previewWhere, quote(visible[i].Name)+" IS "+literal)
			_ = j
		}
		preview := ""
		switch change.Kind {
		case "insert":
			if len(names) == 0 {
				plan.sql = "INSERT INTO " + qualified + " DEFAULT VALUES"
				preview = plan.sql
			} else {
				plan.sql = "INSERT INTO " + qualified + " (" + strings.Join(names, ",") + ") VALUES (" + strings.Join(placeholders, ",") + ")"
				preview = "INSERT INTO " + qualified + " (" + strings.Join(names, ",") + ") VALUES (" + strings.Join(literals, ",") + ")"
			}
		case "update":
			plan.sql = "UPDATE " + qualified + " SET " + strings.Join(sets, ",") + " WHERE " + plan.predicate
			preview = "UPDATE " + qualified + " SET " + strings.Join(literalSets, ",") + " WHERE " + strings.Join(previewWhere, " AND ")
			plan.args = append(plan.args, plan.keys...)
		case "delete":
			plan.sql = "DELETE FROM " + qualified + " WHERE " + plan.predicate
			plan.args = plan.keys
			preview = "DELETE FROM " + qualified + " WHERE " + strings.Join(previewWhere, " AND ")
		}
		plans = append(plans, plan)
		previews = append(previews, preview+";")
	}
	if !applying {
		out := protocol.Response{Type: "query.result", RequestID: c.RequestID, SessionID: c.SessionID, QueryID: c.QueryID, SQL: strings.Join(previews, "\n"), CommandTag: "PREVIEW", TransactionStatus: s.TransactionStatus(), Connected: true}
		return out
	}
	for i, plan := range plans {
		if r.Changes[i].Kind != "insert" {
			rows, _, e := s.query(ctx, "SELECT * FROM "+qualified+" WHERE "+plan.predicate, plan.keys...)
			if e != nil {
				return s.fail(c, ctx, e)
			}
			if len(rows) != 1 || !reflect.DeepEqual(rows[0], plan.original) {
				failure := s.fail(c, ctx, errors.New("Row changed."))
				failure.Category = "conflict"
				failure.Message = "A row changed or disappeared. No changes were committed."
				return failure
			}
		}
		if err = s.exec(ctx, plan.sql, plan.args...); err != nil {
			return s.fail(c, ctx, err)
		}
		if s.conn.Changes() != 1 {
			return s.fail(c, ctx, errors.New("The row change did not affect exactly one row."))
		}
	}
	if err = s.checkIdentity(); err != nil {
		return s.fail(c, ctx, err)
	}
	if err = s.exec(ctx, "COMMIT"); err != nil {
		code := lib.ErrCode(err)
		if code != lib.ResultBusy && code != lib.ResultConstraint {
			inTransaction = false
			s.Close()
			failure := s.fail(c, ctx, err)
			failure.OutcomeUnknown = true
			failure.Message = "The COMMIT outcome is unknown. Check the database before applying again."
			return failure
		}
		return s.fail(c, ctx, err)
	}
	inTransaction = false
	n := len(plans)
	return protocol.Response{Type: "query.result", RequestID: c.RequestID, SessionID: c.SessionID, QueryID: c.QueryID, CommandTag: "APPLY", RowCount: int64(n), AppliedChangeCount: &n, TransactionStatus: s.TransactionStatus(), Connected: true}
}
func (p rowPlan) originalAt(kind string, i int) protocol.SQLiteValue {
	if kind == "insert" {
		return protocol.SQLiteValue{Type: "null"}
	}
	return p.original[i]
}
