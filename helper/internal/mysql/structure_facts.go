package mysql

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"strings"
)

func (s *Session) readStructureFacts(t tableedit.Target, engine, collation, options, comment string) (*tableedit.Facts, error) {
	limits := sc.Limits{Nodes: 256, Members: 2048, Bytes: 2 << 20, Scalar: 65536}
	sink := sc.NewCollector(context.Background(), limits)
	r := &mysqlSchemaCapture{s: s, spec: sc.CaptureSpec{Schemas: []string{t.Schema}, Limits: limits}, sink: sink, explicitTimestamp: true, gipk: true}
	settings, e := s.work.client.Execute("SELECT @@sql_mode,@@show_gipk_in_create_table_and_information_schema,CURRENT_USER(),CURRENT_ROLE(),@@partial_revokes")
	if e != nil {
		return nil, tableedit.ErrUnsupported
	}
	defer settings.Close()
	if settings.RowNumber() != 1 {
		return nil, tableedit.ErrUnsupported
	}
	mode, _ := ownedStructureString(settings, 0, 0)
	gipk, _ := settings.GetInt(0, 1)
	principal, _ := ownedStructureString(settings, 0, 2)
	role, _ := ownedStructureString(settings, 0, 3)
	partial, _ := settings.GetInt(0, 4)
	r.sqlMode = mode
	r.gipk = gipk == 1
	values := []string{t.Table, engine, collation, options, comment}
	row := make([]*string, len(values))
	for i := range values {
		row[i] = &values[i]
	}
	ref := sc.Ref{Kind: "table", Schema: t.Schema, Name: t.Table}
	if r.table(ref, row) != nil || len(sink.Capture.Tables) != 1 {
		return nil, tableedit.ErrUnsupported
	}
	f := &tableedit.Facts{EngineContext: []sc.Option{{Name: "sqlMode", Value: mode}}, Table: sink.Capture.Tables[0], Types: sink.Capture.Types, Dependents: map[string][]string{}}
	if user, host, ok := strings.Cut(principal, "@"); ok && strings.Count(principal, "@") == 1 && role == "NONE" && partial == 0 {
		grantee := "'" + strings.ReplaceAll(user, "'", "''") + "'@'" + strings.ReplaceAll(host, "'", "''") + "'"
		grants, e := r.rows("SELECT PRIVILEGE_TYPE FROM information_schema.USER_PRIVILEGES WHERE GRANTEE=? AND PRIVILEGE_TYPE='SELECT'", grantee)
		if e != nil {
			return nil, tableedit.ErrUnsupported
		}
		f.Proof = len(grants) > 0
	}
	incoming, e := r.rows(`SELECT TABLE_SCHEMA,TABLE_NAME,CONSTRAINT_NAME,REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE REFERENCED_TABLE_SCHEMA=? AND REFERENCED_TABLE_NAME=? ORDER BY TABLE_SCHEMA,TABLE_NAME,CONSTRAINT_NAME,ORDINAL_POSITION`, t.Schema, t.Table)
	if e != nil {
		return nil, tableedit.ErrUnsupported
	}
	for _, row := range incoming {
		schema, table, name := myText(row, 0), myText(row, 1), myText(row, 2)
		i := len(f.Incoming) - 1
		if i < 0 || f.Incoming[i].Schema != schema || f.Incoming[i].Table != table || f.Incoming[i].Name != name {
			f.Incoming = append(f.Incoming, tableedit.Incoming{Schema: schema, Table: table, Name: name})
			i++
		}
		f.Incoming[i].Columns = append(f.Incoming[i].Columns, myText(row, 3))
	}
	for _, query := range []string{`SELECT VIEW_SCHEMA,VIEW_NAME FROM information_schema.VIEW_TABLE_USAGE WHERE TABLE_SCHEMA=? AND TABLE_NAME=?`, `SELECT TRIGGER_SCHEMA,TRIGGER_NAME FROM information_schema.TRIGGERS WHERE EVENT_OBJECT_SCHEMA=? AND EVENT_OBJECT_TABLE=?`} {
		rows, e := r.rows(query, t.Schema, t.Table)
		if e != nil {
			return nil, tableedit.ErrUnsupported
		}
		for _, v := range rows {
			f.Dependents[""] = append(f.Dependents[""], myText(v, 0)+"."+myText(v, 1))
		}
	}
	routines, e := r.rows("SELECT ROUTINE_SCHEMA,ROUTINE_NAME FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA=?", t.Schema)
	if e != nil {
		return nil, tableedit.ErrUnsupported
	}
	for _, v := range routines {
		f.Dependents[""] = append(f.Dependents[""], myText(v, 0)+"."+myText(v, 1))
	}
	b, _ := json.Marshal(f)
	if len(b) > 2<<20 || len(f.Incoming) > 256 {
		return nil, tableedit.ErrUnsupported
	}
	return f, nil
}

func newStructureFacts(charset, collation string) *tableedit.Facts {
	return &tableedit.Facts{Proof: true, Table: sc.Table{Charset: sc.Known(charset), Collation: sc.Known(sc.Ref{Kind: "collation", Name: collation}), Columns: sc.Complete[sc.Column](nil), Constraints: sc.Complete[sc.Constraint](nil), Indexes: sc.Complete[sc.Index](nil)}, Dependents: map[string][]string{}}
}
