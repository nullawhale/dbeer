package postgres

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"io"
	"regexp"
	"strconv"
	"strings"

	dt "dbeer/helper/internal/datatransfer"
	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

var transferNumeric = regexp.MustCompile(`^numeric\(([0-9]+),([0-9]+)\)$`)

func (s *Session) transferIdentity(ctx context.Context) (string, error) {
	var identity string
	err := s.conn.QueryRow(ctx, `SELECT current_database() || ':' || (SELECT oid::text FROM pg_catalog.pg_database WHERE datname=current_database()) || ':' || pg_catalog.pg_postmaster_start_time()::text || ':' || COALESCE(inet_server_addr()::text,'local') || ':' || COALESCE(inet_server_port()::text,'local')`).Scan(&identity)
	return dt.Digest(identity), err
}

func (s *Session) transferDescription(ctx context.Context, tx pgx.Tx, schema, table string) (dt.Description, error) {
	d := dt.Description{Columns: []protocol.TransferColumn{}, Notices: []string{}}
	var oid, kind, persistence string
	var rls bool
	if err := tx.QueryRow(ctx, `SELECT c.oid::text,c.relkind::text,c.relpersistence::text,c.relrowsecurity OR c.relforcerowsecurity FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname=$2`, schema, table).Scan(&oid, &kind, &persistence, &rls); err != nil {
		return d, dt.ErrInvalid
	}
	if kind != "r" && kind != "p" || persistence == "t" || rls {
		return d, dt.ErrInvalid
	}
	if _, err := tx.Exec(ctx, "LOCK TABLE "+pgx.Identifier{schema, table}.Sanitize()+" IN ACCESS SHARE MODE"); err != nil {
		return d, err
	}
	identity, err := s.transferIdentity(ctx)
	if err != nil {
		return d, err
	}
	rows, err := tx.Query(ctx, `SELECT a.attname::text,t.typname::text,n.nspname::text,pg_catalog.format_type(a.atttypid,a.atttypmod),NOT a.attnotnull,a.attidentity::text,a.attgenerated::text FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_type t ON t.oid=a.atttypid JOIN pg_catalog.pg_namespace n ON n.oid=t.typnamespace WHERE a.attrelid=$1::oid AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum LIMIT 257`, oid)
	if err != nil {
		return d, err
	}
	defer rows.Close()
	facts := [][]any{{schema, table, oid, kind, persistence, identity}}
	for rows.Next() {
		var name, kind, namespace, native, identity, generated string
		var nullable bool
		if err = rows.Scan(&name, &kind, &namespace, &native, &nullable, &identity, &generated); err != nil {
			return d, err
		}
		if namespace != "pg_catalog" {
			return d, dt.ErrInvalid
		}
		c := protocol.TransferColumn{SourceIndex: len(d.Columns), Name: name, Nullable: nullable, Type: "text"}
		switch kind {
		case "bool":
			c.Type = "boolean"
		case "int2", "int4", "int8":
			c.Type = "integer"
		case "float4", "float8":
			c.Type = "real"
		case "bytea":
			c.Type = "binary"
		case "date":
			c.Type = "date"
		case "timestamp":
			c.Type = "timestamp"
		case "timestamptz":
			c.Type = "timestampTZ"
		case "json", "jsonb":
			c.Type = "json"
		case "numeric":
			if match := transferNumeric.FindStringSubmatch(native); len(match) == 3 {
				c.Type = "decimal"
				c.Precision, _ = strconv.Atoi(match[1])
				c.Scale, _ = strconv.Atoi(match[2])
				if c.Scale > c.Precision {
					c.Type = "text"
					c.Precision, c.Scale = 0, 0
				}
			}
		}
		if c.Type == "text" && kind != "text" && kind != "varchar" && kind != "bpchar" {
			d.Notices = append(d.Notices, "Some source types are proposed as TEXT to preserve their textual value. Review destination types and numeric bounds explicitly.")
		}
		if !c.Valid() {
			return d, dt.ErrInvalid
		}
		d.Columns = append(d.Columns, c)
		facts = append(facts, []any{name, kind, native, nullable, identity, generated})
	}
	if err = rows.Err(); err != nil {
		return d, err
	}
	if len(d.Columns) == 0 || len(d.Columns) > protocol.MaxTransferColumns {
		return d, dt.ErrInvalid
	}
	d.Digest = dt.Digest(facts)
	return d, nil
}
func (s *Session) TransferDescribe(ctx context.Context, schema, table string) (dt.Description, error) {
	if s.conn.IsClosed() || s.TransactionStatus() != "idle" {
		return dt.Description{}, dt.ErrInvalid
	}
	tx, err := s.dataTransaction(ctx)
	if err != nil {
		return dt.Description{}, err
	}
	defer rollbackData(tx)
	return s.transferDescription(ctx, tx, schema, table)
}
func (s *Session) TransferCapture(ctx context.Context, schema, table, digest string, sink func([]protocol.CellValue) error) (dt.Description, error) {
	if s.conn.IsClosed() || s.TransactionStatus() != "idle" {
		return dt.Description{}, dt.ErrInvalid
	}
	tx, err := s.dataTransaction(ctx)
	if err != nil {
		return dt.Description{}, err
	}
	defer rollbackData(tx)
	d, err := s.transferDescription(ctx, tx, schema, table)
	if err != nil {
		return d, err
	}
	if d.Digest != digest {
		return d, dt.ErrChanged
	}
	names := []string{}
	for _, column := range d.Columns {
		name := pgx.Identifier{column.Name}.Sanitize()
		if column.Type == "real" {
			name += "::double precision"
		}
		if column.Type == "timestampTZ" {
			name = "pg_catalog.to_char(" + name + " AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')"
		}
		names = append(names, name)
	}
	rows, err := tx.Query(ctx, "SELECT "+strings.Join(names, ",")+" FROM "+pgx.Identifier{schema, table}.Sanitize(), pgx.QueryResultFormats{pgx.TextFormatCode})
	if err != nil {
		return d, err
	}
	defer rows.Close()
	for rows.Next() {
		values := rows.RawValues()
		if len(values) != len(d.Columns) {
			return d, dt.ErrChanged
		}
		row := make([]protocol.CellValue, len(values))
		bytes := 0
		for index, value := range values {
			if value == nil {
				row[index] = protocol.CellValue{Kind: "null"}
				continue
			}
			bytes += len(value)
			if bytes > dt.MaxRowBytes {
				return d, dt.ErrInvalid
			}
			text := string(value)
			kind := "text"
			if d.Columns[index].Type == "binary" {
				decoded, e := decodeBytea(value)
				if e != nil {
					return d, dt.ErrInvalid
				}
				text = base64.StdEncoding.EncodeToString(decoded)
				kind = "binary"
			}
			row[index] = protocol.CellValue{Kind: kind, Value: &text}
		}
		if err = sink(row); err != nil {
			rows.Close()
			return d, err
		}
	}
	return d, rows.Err()
}
func transferPostgresDDL(schema, table string, columns []protocol.TransferColumn) (string, error) {
	if err := dt.ValidateTarget("postgresql", schema, table); err != nil {
		return "", err
	}
	if err := dt.ValidateColumns(columns, "postgresql"); err != nil {
		return "", err
	}
	parts := []string{}
	for _, column := range columns {
		kind := ""
		switch column.Type {
		case "text":
			kind = "TEXT"
		case "integer":
			kind = "BIGINT"
		case "decimal":
			kind = "NUMERIC(" + strconv.Itoa(column.Precision) + "," + strconv.Itoa(column.Scale) + ")"
		case "real":
			kind = "DOUBLE PRECISION"
		case "boolean":
			kind = "BOOLEAN"
		case "date":
			kind = "DATE"
		case "timestamp":
			kind = "TIMESTAMP WITHOUT TIME ZONE"
		case "timestampTZ":
			kind = "TIMESTAMP WITH TIME ZONE"
		case "json":
			kind = "JSON"
		case "binary":
			kind = "BYTEA"
		default:
			return "", dt.ErrInvalid
		}
		part := pgx.Identifier{column.Name}.Sanitize() + " " + kind
		if !column.Nullable {
			part += " NOT NULL"
		}
		parts = append(parts, part)
	}
	return "CREATE TABLE " + pgx.Identifier{schema, table}.Sanitize() + " (\n  " + strings.Join(parts, ",\n  ") + "\n);", nil
}
func (s *Session) TransferPreview(ctx context.Context, schema, table string, columns []protocol.TransferColumn) (string, string, error) {
	if s.conn.IsClosed() || s.TransactionStatus() != "idle" {
		return "", "", dt.ErrInvalid
	}
	statement, err := transferPostgresDDL(schema, table, columns)
	if err != nil {
		return "", "", err
	}
	var exists, namespace bool
	if err = s.conn.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname=$1),EXISTS(SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname=$2)`, schema, table).Scan(&namespace, &exists); err != nil {
		return "", "", err
	}
	if !namespace {
		return "", "", dt.ErrInvalid
	}
	if exists {
		return "", "", dt.ErrExists
	}
	identity, err := s.transferIdentity(ctx)
	if err != nil {
		return "", "", err
	}
	return statement, identity, nil
}
func (s *Session) TransferApply(ctx context.Context, schema, table, expectedIdentity string, columns []protocol.TransferColumn, read dt.RowReader, progress func(int64)) (out dt.Result, err error) {
	statement, identity, err := s.TransferPreview(ctx, schema, table, columns)
	if err != nil {
		return out, err
	}
	if identity != expectedIdentity {
		return out, dt.ErrChanged
	}
	tx, err := s.conn.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return out, err
	}
	defer rollbackData(tx)
	if _, err = tx.Exec(ctx, "SET LOCAL lock_timeout='5s'; SET LOCAL timezone='UTC'; SET LOCAL client_encoding='UTF8'"); err != nil {
		return out, err
	}
	if _, err = tx.Exec(ctx, statement); err != nil {
		return out, err
	}
	names := []string{}
	for _, column := range columns {
		names = append(names, pgx.Identifier{column.Name}.Sanitize())
	}
	copyReader, copyWriter := io.Pipe()
	done := make(chan error, 1)
	var count int64
	go func() {
		var failure error
		defer func() { copyWriter.CloseWithError(failure); done <- failure }()
		for {
			row, e := read()
			if e == io.EOF {
				break
			}
			if e != nil {
				failure = e
				return
			}
			if len(row) != len(columns) {
				failure = dt.ErrInvalid
				return
			}
			parts := make([]string, len(row))
			for index, value := range row {
				if value.Kind == "null" {
					parts[index] = `\N`
					continue
				}
				if value.Value == nil {
					failure = dt.ErrInvalid
					return
				}
				text := *value.Value
				if value.Kind == "binary" {
					decoded, e := base64.StdEncoding.DecodeString(text)
					if e != nil {
						failure = dt.ErrInvalid
						return
					}
					text = `\x` + hex.EncodeToString(decoded)
				}
				text = strings.NewReplacer(`\`, `\\`, "\n", `\n`, "\r", `\r`, "\t", `\t`).Replace(text)
				parts[index] = text
			}
			if _, e = io.WriteString(copyWriter, strings.Join(parts, "\t")+"\n"); e != nil {
				failure = e
				return
			}
			count++
			if count%1000 == 0 {
				progress(count)
			}
		}
	}()
	tag, copyErr := tx.Conn().PgConn().CopyFrom(ctx, copyReader, "COPY "+pgx.Identifier{schema, table}.Sanitize()+" ("+strings.Join(names, ",")+") FROM STDIN WITH (FORMAT text)")
	copyReader.CloseWithError(copyErr)
	writeErr := <-done
	if copyErr != nil {
		return out, copyErr
	}
	if writeErr != nil {
		return out, writeErr
	}
	if tag.RowsAffected() != count {
		return out, dt.ErrInvalid
	}
	if ctx.Err() != nil {
		return out, ctx.Err()
	}
	if err = tx.Commit(ctx); err != nil {
		if transferCommitOutcomeUnknown(err) {
			out.OutcomeUnknown = true
			out.Rows = count
			closeConnection(s.conn)
			return out, err
		}
		return out, err
	}
	out.Rows = count
	out.TableCreated = true
	progress(count)
	return out, nil
}

func transferCommitOutcomeUnknown(err error) bool {
	var server *pgconn.PgError
	return !errors.As(err, &server) || server.Severity == "FATAL" || server.Severity == "PANIC" || server.SeverityUnlocalized == "FATAL" || server.SeverityUnlocalized == "PANIC" || strings.HasPrefix(server.Code, "08") || server.Code == "40003" || server.Code == "57P01"
}

var _ dt.Database = (*Session)(nil)
