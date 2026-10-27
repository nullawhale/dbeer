package postgres

import (
	"context"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	tc "dbeer/helper/internal/tablecapture"
	"encoding/base64"
	"encoding/json"
	"github.com/jackc/pgx/v5"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

func (s *Session) dataTransaction(ctx context.Context) (pgx.Tx, error) {
	s.conn.PgConn().Frontend().SetMaxBodyLen(tc.MaxRowBytes)
	tx, e := s.conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if e != nil {
		return nil, e
	}
	_, e = tx.Exec(ctx, "SET LOCAL search_path=pg_catalog; SET LOCAL row_security=off; SET LOCAL timezone='UTC'; SET LOCAL datestyle='ISO, YMD'; SET LOCAL intervalstyle='iso_8601'; SET LOCAL extra_float_digits=3; SET LOCAL bytea_output='hex'; SET LOCAL client_encoding='UTF8'; SET LOCAL lc_monetary='C'")
	if e != nil {
		rollbackData(tx)
		return nil, e
	}
	return tx, nil
}
func rollbackData(tx pgx.Tx) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = tx.Rollback(ctx)
}
func (s *Session) DescribeTable(ctx context.Context, table tc.Table) (tc.Descriptor, error) {
	tx, e := s.dataTransaction(ctx)
	if e != nil {
		return tc.Descriptor{}, e
	}
	defer rollbackData(tx)
	return describeDataTable(ctx, tx, table)
}
func describeDataTable(ctx context.Context, tx pgx.Tx, table tc.Table) (tc.Descriptor, error) {
	d := tc.Descriptor{Engine: "postgresql", Table: table, Columns: []tc.Column{}}
	if !table.Valid() {
		return d, tc.ErrInvalid
	}
	limits := sc.DefaultLimits()
	collector := sc.NewCollector(ctx, limits)
	r := &schemaCapture{ctx: ctx, tx: tx, sink: collector, spec: sc.CaptureSpec{Schemas: []string{table.Schema}, Limits: limits}, types: map[string]sc.TypeUse{}, loading: map[string]bool{}, sequences: map[string]bool{}}
	v, e := r.rows("SELECT c.oid::text,c.relkind::text,c.relpersistence::text,(c.relispartition OR c.reloftype<>0 OR c.relrowsecurity OR c.relforcerowsecurity OR EXISTS(SELECT 1 FROM pg_inherits WHERE inhrelid=c.oid OR inhparent=c.oid))::text,current_setting('server_version_num') FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname=$2", table.Schema, table.Name)
	if e != nil {
		return d, e
	}
	if len(v) != 1 || v[0][1] != "r" || pgBool(v[0][3]) {
		return d, tc.ErrUnsupported
	}
	r.version = int(pgInt(v[0][4]))
	if r.version < 140000 {
		return d, tc.ErrUnsupported
	}
	if _, e = tx.Exec(ctx, "LOCK TABLE ONLY "+pgx.Identifier{table.Schema, table.Name}.Sanitize()+" IN ACCESS SHARE MODE"); e != nil {
		return d, e
	}
	ref := sc.Ref{Kind: "table", Schema: table.Schema, Name: table.Name}
	columns, e := r.columns(ref, v[0][0])
	if e != nil {
		return d, e
	}
	constraints, e := r.constraints(ref, "conrelid", v[0][0])
	if e != nil {
		return d, e
	}
	primary := map[string]int{}
	for _, c := range constraints {
		if c.Kind.Value != nil && *c.Kind.Value == "p" {
			for i, key := range c.Columns.Items {
				primary[key.Name] = i + 1
			}
		}
	}
	definitions := collector.Capture.Types
	for i, c := range columns {
		if c.Type.Value == nil {
			return d, tc.ErrUnsupported
		}
		native, e := tc.PostgresType(*c.Type.Value, definitions)
		if e != nil {
			return d, e
		}
		base := postgresDataBase(*c.Type.Value, definitions)
		encoding := ""
		if base == "bytea" {
			encoding = "base64"
		}
		definition, _ := json.Marshal(c)
		valueComparison := ""
		if !postgresLosslessUse(*c.Type.Value, definitions, map[sc.Ref]bool{}) {
			valueComparison = "unresolved"
		}
		d.Columns = append(d.Columns, tc.Column{ValueComparison: valueComparison, Index: i, Name: c.Ref.Name, NativeType: native, TypeLabel: c.Type.Value.Ref.Schema + "." + c.Type.Value.Ref.Name, Encoding: encoding, PrimaryKey: primary[c.Ref.Name], Numeric: strings.Contains("|int2|int4|int8|numeric|float4|float8|", "|"+base+"|"), Generated: c.Generated.Value != nil && c.Generated.Value.Kind != "none", Identity: c.Identity.Value != nil && c.Identity.Value.Kind != "none", Nullable: c.Nullable.Value != nil && *c.Nullable.Value, Definition: definition})
	}
	d.Definition, e = json.Marshal(struct {
		Persistence string              `json:"persistence"`
		Columns     []sc.Column         `json:"columns"`
		Constraints []sc.Constraint     `json:"constraints"`
		Types       []sc.TypeDefinition `json:"types"`
	}{v[0][2], columns, constraints, definitions})
	if e != nil {
		return d, e
	}
	return d, d.Seal()
}
func postgresDataBase(u sc.TypeUse, defs []sc.TypeDefinition) string {
	if u.Kind == "array" {
		return "array"
	}
	for depth := 0; depth < 128; depth++ {
		if u.Kind == "array" {
			return "array"
		}
		if u.Kind == "builtin" {
			return u.Ref.Name
		}
		found := false
		for _, d := range defs {
			if d.Ref == u.Ref && d.Base.Value != nil {
				u = *d.Base.Value
				found = true
				break
			}
		}
		if !found {
			return u.Ref.Name
		}
	}
	return "unsupported"
}
func (s *Session) CaptureTable(ctx context.Context, spec tc.Spec, sink tc.Sink) (tc.Descriptor, tc.Outcome, error) {
	out := tc.Outcome{StartedAt: time.Now().UTC().Format(time.RFC3339Nano), ReadLimit: spec.ReadLimit, Consistency: "repeatableRead", Rendering: "postgresTextUTCISOv1", PartialReasons: []string{}, Table: spec.Table, Engine: "postgresql"}
	tx, e := s.dataTransaction(ctx)
	if e != nil {
		return tc.Descriptor{}, out, e
	}
	defer rollbackData(tx)
	d, e := describeDataTable(ctx, tx, spec.Table)
	if e != nil {
		return d, out, e
	}
	if e = tc.Validate(d, spec); e != nil {
		return d, out, e
	}
	metadata := []browseColumn{}
	byName := map[string]tc.Column{}
	for _, c := range d.Columns {
		byName[c.Name] = c
		metadata = append(metadata, browseColumn{name: c.Name, numeric: c.Numeric, binary: c.Encoding == "base64"})
	}
	request := protocol.CatalogRequest{Kind: "browse", Schema: spec.Table.Schema, Object: spec.Table.Name}
	for _, key := range spec.Keys {
		request.Sort = append(request.Sort, protocol.CatalogSort{Column: key, Direction: "asc"})
	}
	for _, f := range spec.Filters {
		request.Filters = append(request.Filters, protocol.CatalogFilter{Column: f.Column, Operator: f.Operator, Value: f.Value})
	}
	plan, e := buildBrowsePlan(request, metadata)
	if e != nil {
		return d, out, tc.ErrInvalid
	}
	quoted := []string{}
	for _, name := range spec.Columns {
		quoted = append(quoted, pgx.Identifier{name}.Sanitize())
	}
	statement := strings.Replace(plan.statement, "SELECT * FROM ", "SELECT "+strings.Join(quoted, ",")+" FROM ONLY ", 1)
	statement = strings.TrimSuffix(statement, " LIMIT 200 OFFSET 0") + " LIMIT " + strconv.Itoa(spec.ReadLimit+1)
	reader := s.conn.PgConn().ExecParams(ctx, statement, plan.values, nil, nil, nil)
	if len(reader.FieldDescriptions()) != len(spec.Columns) {
		_, _ = reader.Close()
		return d, out, tc.ErrChanged
	}
	var rowError error
	for reader.NextRow() {
		out.ObservedAtLeast++
		if out.StoredRows >= int64(spec.ReadLimit) {
			out.PartialReasons = []string{"readLimit"}
			continue
		}
		values := reader.Values()
		if len(values) != len(spec.Columns) {
			rowError = tc.ErrChanged
			break
		}
		row := make([]*string, len(values))
		for i, b := range values {
			if b == nil {
				continue
			}
			value := string(b)
			if byName[spec.Columns[i]].Encoding == "base64" {
				binary, e := decodeBytea(b)
				if e != nil {
					rowError = tc.ErrUnsupported
					break
				}
				value = base64.StdEncoding.EncodeToString(binary)
			} else if !utf8.Valid(b) {
				rowError = tc.ErrUnsupported
				break
			}
			row[i] = &value
		}
		if rowError != nil {
			break
		}
		if rowError = sink.Row(row); rowError != nil {
			break
		}
		out.StoredRows++
	}
	if rowError != nil { // Discarding a dedicated transport bounds a mid-row/quota failure.
		closeCtx, cancel := context.WithTimeout(context.Background(), time.Second)
		_ = s.conn.Close(closeCtx)
		cancel()
		_, _ = reader.Close()
		out.FinishedAt = time.Now().UTC().Format(time.RFC3339Nano)
		return d, out, rowError
	}
	_, e = reader.Close()
	out.FinishedAt = time.Now().UTC().Format(time.RFC3339Nano)
	out.DescriptorDigest = d.Digest
	return d, out, e
}
