package mysql

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"sort"
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
	keywords, keywordErr := r.rows(`SELECT WORD FROM information_schema.KEYWORDS WHERE RESERVED=1`)
	if keywordErr != nil {
		return nil, tableedit.ErrUnsupported
	}
	f.ExpressionKeywords = []string{}
	for _, keyword := range keywords {
		f.ExpressionKeywords = append(f.ExpressionKeywords, myText(keyword, 0))
	}
	sort.Strings(f.ExpressionKeywords)
	triggerProof := false
	if user, host, ok := strings.Cut(principal, "@"); ok && strings.Count(principal, "@") == 1 && role == "NONE" && partial == 0 {
		grantee := "'" + strings.ReplaceAll(user, "'", "''") + "'@'" + strings.ReplaceAll(host, "'", "''") + "'"
		grants, e := r.rows("SELECT PRIVILEGE_TYPE FROM information_schema.USER_PRIVILEGES WHERE GRANTEE=? AND PRIVILEGE_TYPE IN ('SELECT','TRIGGER')", grantee)
		if e != nil {
			return nil, tableedit.ErrUnsupported
		}
		for _, grant := range grants {
			f.Proof = f.Proof || myText(grant, 0) == "SELECT"
			triggerProof = triggerProof || myText(grant, 0) == "TRIGGER"
		}
	}
	incoming, e := r.rows(`SELECT TABLE_SCHEMA,TABLE_NAME,CONSTRAINT_NAME,REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE BINARY REFERENCED_TABLE_SCHEMA=BINARY ? AND BINARY REFERENCED_TABLE_NAME=BINARY ? ORDER BY BINARY TABLE_SCHEMA,BINARY TABLE_NAME,BINARY CONSTRAINT_NAME,ORDINAL_POSITION`, t.Schema, t.Table)
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
	views, e := r.rows(`SELECT VIEW_SCHEMA,VIEW_NAME FROM information_schema.VIEW_TABLE_USAGE WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? ORDER BY BINARY VIEW_SCHEMA,BINARY VIEW_NAME`, t.Schema, t.Table)
	if e != nil {
		return nil, tableedit.ErrUnsupported
	}
	for _, v := range views {
		f.Dependents[""] = append(f.Dependents[""], myText(v, 0)+"."+myText(v, 1))
	}
	f.Proof = f.Proof && triggerProof
	if !triggerProof {
		f.Dependents[""] = append(f.Dependents[""], "Trigger dependency visibility is incomplete; global TRIGGER metadata access is required for rename/type dependency proof.")
	}
	triggers, e := r.rows(`SELECT TRIGGER_SCHEMA,TRIGGER_NAME,EVENT_OBJECT_SCHEMA,EVENT_OBJECT_TABLE,ACTION_STATEMENT,SQL_MODE FROM information_schema.TRIGGERS WHERE (BINARY EVENT_OBJECT_SCHEMA=BINARY ? AND BINARY EVENT_OBJECT_TABLE=BINARY ?) OR (BINARY TRIGGER_SCHEMA=BINARY ? AND (LOCATE(LOWER(?),LOWER(ACTION_STATEMENT))>0 OR LOCATE(LOWER(?),LOWER(ACTION_STATEMENT))>0)) OR LOCATE(LOWER(?),LOWER(ACTION_STATEMENT))>0 OR LOCATE(LOWER(?),LOWER(ACTION_STATEMENT))>0 ORDER BY BINARY TRIGGER_SCHEMA,BINARY TRIGGER_NAME`, t.Schema, t.Table, t.Schema, t.Table, QuoteIdentifier(t.Table), t.Schema, QuoteIdentifier(t.Schema))
	if e != nil {
		return nil, tableedit.ErrUnsupported
	}
	for _, v := range triggers {
		if myText(v, 2) == t.Schema && myText(v, 3) == t.Table || mysqlMayReferenceTable(myText(v, 4), myText(v, 0), t, myText(v, 5)) {
			f.Dependents[""] = append(f.Dependents[""], myText(v, 0)+"."+myText(v, 1))
		}
	}
	routines, e := r.rows(`SELECT ROUTINE_SCHEMA,ROUTINE_NAME,CASE WHEN BINARY ROUTINE_SCHEMA=BINARY ? THEN NULL ELSE ROUTINE_DEFINITION END,SQL_MODE FROM information_schema.ROUTINES WHERE BINARY ROUTINE_SCHEMA=BINARY ? OR ROUTINE_DEFINITION IS NULL OR LOCATE(LOWER(?),LOWER(ROUTINE_DEFINITION))>0 OR LOCATE(LOWER(?),LOWER(ROUTINE_DEFINITION))>0 ORDER BY BINARY ROUTINE_SCHEMA,BINARY ROUTINE_NAME`, t.Schema, t.Schema, t.Schema, QuoteIdentifier(t.Schema))
	if e != nil {
		return nil, tableedit.ErrUnsupported
	}
	for _, v := range routines {
		if myText(v, 0) == t.Schema || len(v) < 3 || v[2] == nil || mysqlMayReferenceTable(myText(v, 2), myText(v, 0), t, myText(v, 3)) {
			f.Dependents[""] = append(f.Dependents[""], myText(v, 0)+"."+myText(v, 1))
		}
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
