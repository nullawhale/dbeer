package sqlite

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"dbeer/helper/internal/protocol"
	ti "dbeer/helper/internal/tableimport"
)

func cellText(v protocol.SQLiteValue) string {
	if v.Type == "text" {
		b, _ := base64.StdEncoding.DecodeString(v.Value)
		return string(b)
	}
	return v.Value
}
func cellInt(v protocol.SQLiteValue) int { n, _ := strconv.Atoi(v.Value); return n }

func (s *Session) importDescription(ctx context.Context, r protocol.TableImportRequest) ([]ti.Column, string, error) {
	if r.Schema != "main" {
		return nil, "", ti.ErrInvalid
	}
	rows, _, err := s.query(ctx, `SELECT type,sql FROM main.sqlite_schema WHERE name=?`, r.Table)
	if err != nil || len(rows) != 1 || cellText(rows[0][0]) != "table" || strings.HasPrefix(strings.ToUpper(cellText(rows[0][1])), "CREATE VIRTUAL") {
		return nil, "", ti.ErrInvalid
	}
	info, err := s.tableInfo(ctx, "main", r.Table)
	if err != nil {
		return nil, "", err
	}
	columns := make([]ti.Column, 0, len(info))
	for _, c := range info {
		typ := c.NativeType
		if typ == "" {
			typ = "untyped"
		}
		columns = append(columns, ti.Column{TableImportColumn: protocol.TableImportColumn{Name: c.Name, NativeType: typ, Nullable: !c.NotNull, HasDefault: c.Default != nil || c.PrimaryKey > 0 && strings.EqualFold(c.NativeType, "INTEGER"), Generated: c.Hidden != 0, Binary: strings.EqualFold(c.NativeType, "BLOB")}, Writable: c.Hidden == 0, Supported: c.Hidden == 0})
	}
	fingerprint, err := ti.MetadataFingerprint([]any{rows, info})
	return columns, fingerprint, err
}

func (s *Session) tableImport(ctx context.Context, c protocol.Command) protocol.Response {
	rollback := func() { _ = s.exec(context.Background(), "ROLLBACK") }
	fail := func(err error) protocol.Response {
		rollback()
		r := s.fail(c, ctx, err)
		if errors.Is(err, ti.ErrConflict) {
			r.Category = "conflict"
			r.Message = ti.ErrConflict.Error()
		}
		return r
	}
	if c.TableImport == nil || !c.TableImport.Valid(c.Type) || s.TransactionStatus() != "idle" {
		return s.fail(c, ctx, ti.ErrInvalid)
	}
	if c.Type == "import.apply" && s.readOnly {
		return s.fail(c, ctx, errors.New("The profile is read-only."))
	}
	if err := s.checkIdentity(); err != nil {
		return s.fail(c, ctx, err)
	}
	begin := "BEGIN"
	if c.Type == "import.apply" {
		begin = "BEGIN IMMEDIATE"
	}
	if err := s.exec(ctx, begin); err != nil {
		return s.fail(c, ctx, err)
	}
	columns, fp, err := s.importDescription(ctx, *c.TableImport)
	if err != nil {
		return fail(err)
	}
	if c.Type == "import.describe" {
		rollback()
		return protocol.Response{Type: "import.describe.result", Connected: true, TransactionStatus: "idle", TableImport: &protocol.TableImportReply{Columns: ti.ReplyColumns(columns), Fingerprint: fp}}
	}
	mapped, err := ti.Validate(columns, fp, *c.TableImport)
	if err != nil {
		return fail(err)
	}
	names, values := []string{}, []string{}
	for _, column := range mapped {
		names = append(names, quote(column.Name))
		values = append(values, "?")
	}
	sql := "INSERT INTO main." + quote(c.TableImport.Table) + " (" + strings.Join(names, ",") + ") VALUES (" + strings.Join(values, ",") + ")"
	count := len(c.TableImport.Rows)
	if c.Type == "import.preview" {
		rollback()
		return protocol.Response{Type: "import.preview.result", Connected: true, TransactionStatus: "idle", TableImport: &protocol.TableImportReply{Fingerprint: fp, RowCount: &count, SQL: sql}}
	}
	for i, row := range c.TableImport.Rows {
		args := make([]any, len(row))
		for j, value := range row {
			switch value.Kind {
			case "null":
			case "text":
				args[j] = *value.Value
			case "binary":
				args[j], err = base64.StdEncoding.DecodeString(*value.Value)
			default:
				err = ti.ErrInvalid
			}
			if err != nil {
				return fail(err)
			}
		}
		if err = s.exec(ctx, sql, args...); err != nil {
			r := fail(err)
			n := i + 1
			r.TableImport = &protocol.TableImportReply{Row: &n}
			return r
		}
	}
	if err = s.exec(ctx, "COMMIT"); err != nil {
		r := s.fail(c, ctx, err)
		r.OutcomeUnknown = true
		r.Message = "The import COMMIT outcome is unknown. Verify the table before importing again."
		return r
	}
	return protocol.Response{Type: "import.apply.result", Connected: true, TransactionStatus: "idle", TableImport: &protocol.TableImportReply{RowCount: &count}, CommandTag: fmt.Sprintf("IMPORT %d", count)}
}
