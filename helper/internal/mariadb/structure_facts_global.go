package mariadb

import (
	"dbeer/helper/internal/mysql"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"fmt"
	"reflect"
	"sort"
	"strings"
)

// Global metadata uses a fresh authenticated inspector; newly granted privileges
// must not be inferred from the owner's older physical login privilege cache.
func (r *mariaSchemaCapture) globalFacts(target tableedit.Target, facts *tableedit.Facts) error {
	owner, e := r.rows("SELECT CURRENT_USER(),CURRENT_ROLE(),DATABASE()")
	if e != nil || len(owner) != 1 || len(owner[0]) != 3 {
		return tableedit.ErrUnsupported
	}
	control, cleanup, e := r.openMetadataControl(owner[0])
	if e != nil {
		return e
	}
	defer cleanup()
	source := r
	r = &mariaSchemaCapture{s: &Session{work: control}, ctx: source.ctx, spec: source.spec, members: source.members, bytes: source.bytes}
	defer func() { source.members = r.members; source.bytes = r.bytes }()
	grants, e := r.visibility(mariaText(owner[0], 0))
	if e != nil {
		return fmt.Errorf("%w: visibility", tableedit.ErrUnsupported)
	}
	// Direct global SELECT/TRIGGER/SHOW VIEW/EVENT grants prove the catalog scope independently
	// of active roles. Unproven cross-schema metadata is never successful empty.
	facts.Proof = grants["SELECT"] && grants["TRIGGER"] && grants["SHOW VIEW"] && grants["EVENT"]
	if !facts.Proof {
		facts.Dependents[""] = append(facts.Dependents[""], "Global static dependency visibility is incomplete; direct global SELECT, TRIGGER, SHOW VIEW and EVENT metadata access is required.")
	}
	incoming, e := r.tracked("SELECT TABLE_SCHEMA,TABLE_NAME,CONSTRAINT_NAME,REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE BINARY REFERENCED_TABLE_SCHEMA=BINARY ? AND BINARY REFERENCED_TABLE_NAME=BINARY ? ORDER BY BINARY TABLE_SCHEMA,BINARY TABLE_NAME,BINARY CONSTRAINT_NAME,ORDINAL_POSITION", target.Schema, target.Table)
	if e != nil {
		return fmt.Errorf("%w: incoming", tableedit.ErrUnsupported)
	}
	for _, row := range incoming {
		if len(row) != 4 || row[0] == nil || row[1] == nil || row[2] == nil || row[3] == nil {
			return fmt.Errorf("%w: incoming shape", tableedit.ErrUnsupported)
		}
		schema, table, name := *row[0], *row[1], *row[2]
		i := len(facts.Incoming) - 1
		if i < 0 || facts.Incoming[i].Schema != schema || facts.Incoming[i].Table != table || facts.Incoming[i].Name != name {
			facts.Incoming = append(facts.Incoming, tableedit.Incoming{Schema: schema, Table: table, Name: name})
			i++
		}
		facts.Incoming[i].Columns = append(facts.Incoming[i].Columns, *row[3])
	}
	names, e := r.tracked("SELECT TABLE_NAME,CONSTRAINT_NAME FROM information_schema.TABLE_CONSTRAINTS WHERE BINARY CONSTRAINT_SCHEMA=BINARY ? AND CONSTRAINT_TYPE='FOREIGN KEY' ORDER BY BINARY TABLE_NAME,BINARY CONSTRAINT_NAME", target.Schema)
	if e != nil {
		return fmt.Errorf("%w: schema keys", tableedit.ErrUnsupported)
	}
	nameJSON, e := json.Marshal(mysql.CatalogRawRows(names))
	if e != nil {
		return fmt.Errorf("%w: schema key encoding", tableedit.ErrUnsupported)
	}
	facts.EngineContext = append(facts.EngineContext, sc.Option{Name: "schemaForeignKeyNames", Value: string(nameJSON)})
	keywords, e := r.rows("SELECT WORD FROM information_schema.KEYWORDS ORDER BY BINARY WORD")
	if e != nil {
		return fmt.Errorf("%w: keywords", tableedit.ErrUnsupported)
	}
	facts.ExpressionKeywords = []string{}
	for _, row := range keywords {
		if len(row) != 1 || row[0] == nil {
			return fmt.Errorf("%w: keyword shape", tableedit.ErrUnsupported)
		}
		facts.ExpressionKeywords = append(facts.ExpressionKeywords, *row[0])
	}
	sort.Strings(facts.ExpressionKeywords)
	viewInventory, e := r.tracked("SELECT TABLE_SCHEMA,TABLE_NAME FROM information_schema.TABLES WHERE TABLE_TYPE='VIEW' ORDER BY BINARY TABLE_SCHEMA,BINARY TABLE_NAME")
	if e != nil {
		return tableedit.ErrUnsupported
	}
	expectedViews := map[string]bool{}
	for _, v := range viewInventory {
		if len(v) != 2 || v[0] == nil || v[1] == nil {
			return tableedit.ErrUnsupported
		}
		expectedViews[*v[0]+"\x00"+*v[1]] = true
	}
	var triggerColumns []string
	for _, spec := range []struct {
		sql                                               string
		schema, name, body, mode, ownerSchema, ownerTable int
	}{
		{"SELECT TABLE_SCHEMA,TABLE_NAME,VIEW_DEFINITION,'' FROM information_schema.VIEWS ORDER BY BINARY TABLE_SCHEMA,BINARY TABLE_NAME", 0, 1, 2, 3, -1, -1},
		{"SELECT TRIGGER_SCHEMA,TRIGGER_NAME,ACTION_STATEMENT,SQL_MODE,EVENT_OBJECT_SCHEMA,EVENT_OBJECT_TABLE,t.* FROM information_schema.TRIGGERS t ORDER BY BINARY TRIGGER_SCHEMA,BINARY TRIGGER_NAME", 0, 1, 2, 3, 4, 5},
		{"SELECT ROUTINE_SCHEMA,ROUTINE_NAME,ROUTINE_DEFINITION,SQL_MODE FROM information_schema.ROUTINES ORDER BY BINARY ROUTINE_SCHEMA,BINARY ROUTINE_NAME", 0, 1, 2, 3, -1, -1},
		{"SELECT EVENT_SCHEMA,EVENT_NAME,EVENT_DEFINITION,SQL_MODE FROM information_schema.EVENTS ORDER BY BINARY EVENT_SCHEMA,BINARY EVENT_NAME", 0, 1, 2, 3, -1, -1},
	} {
		query := spec.sql
		args := []any{}
		if strings.Contains(query, "information_schema.ROUTINES") || strings.Contains(query, "information_schema.EVENTS") {
			schemaColumn, bodyColumn := "ROUTINE_SCHEMA", "ROUTINE_DEFINITION"
			if strings.Contains(query, "information_schema.EVENTS") {
				schemaColumn, bodyColumn = "EVENT_SCHEMA", "EVENT_DEFINITION"
			}
			// Preserve same-schema/dynamic and unavailable bodies. External
			// static references require a native schema-location candidate.
			order := strings.Index(query, " ORDER BY ")
			if order < 0 {
				return tableedit.ErrUnsupported
			}
			query = query[:order] + " WHERE (BINARY " + schemaColumn + "=BINARY ? OR " + bodyColumn + " IS NULL OR LOCATE(LOWER(?),LOWER(" + bodyColumn + "))>0 OR LOCATE(LOWER(?),LOWER(" + bodyColumn + "))>0)" + query[order:]
			args = []any{target.Schema, target.Schema, QuoteIdentifier(target.Schema)}
		}
		rows, e := r.tracked(query, args...)
		if e != nil {
			return fmt.Errorf("%w: dependency metadata", tableedit.ErrUnsupported)
		}
		if strings.Contains(spec.sql, "information_schema.TRIGGERS") {
			triggerColumns = append([]string(nil), r.columnNames...)
			digest, ok := mariaOwnedTriggerRowsDigest(triggerColumns, rows, target)
			if !ok {
				return tableedit.ErrUnsupported
			}
			facts.EngineContext = append(facts.EngineContext, sc.Option{Name: "ownedTriggerRowsDigest", Value: digest})
		}
		for _, row := range rows {
			if len(row) <= spec.mode || row[spec.schema] == nil || row[spec.name] == nil {
				return fmt.Errorf("%w: dependency shape", tableedit.ErrUnsupported)
			}
			schema, name := *row[spec.schema], *row[spec.name]
			if strings.Contains(spec.sql, "information_schema.VIEWS") {
				delete(expectedViews, schema+"\x00"+name)
			}
			if row[spec.body] == nil {
				facts.Proof = false
				facts.Dependents[""] = append(facts.Dependents[""], schema+"."+name+" (definition unavailable)")
				continue
			}
			owned := spec.ownerSchema >= 0 && len(row) > spec.ownerTable && mariaText(row, spec.ownerSchema) == target.Schema && mariaText(row, spec.ownerTable) == target.Table
			// Routine references retain the existing guarded editor scope: any routine
			// in the selected schema, plus conservatively detected external static refs.
			routineInSchema := (strings.Contains(spec.sql, "information_schema.ROUTINES") || strings.Contains(spec.sql, "information_schema.EVENTS")) && schema == target.Schema
			if owned || routineInSchema || mariaMayReferenceTable(*row[spec.body], schema, target, mariaText(row, spec.mode)) {
				facts.Dependents[""] = append(facts.Dependents[""], schema+"."+name)
			}
		}
	}
	if len(expectedViews) > 0 {
		facts.Proof = false
		facts.Dependents[""] = append(facts.Dependents[""], "Native view definitions are incomplete for the observed table inventory.")
	}
	for _, read := range r.reads {
		rows, e := r.read(read.sql, read.show, read.args...)
		if e != nil {
			return e
		}
		if strings.Contains(read.sql, "information_schema.TRIGGERS") && !reflect.DeepEqual(triggerColumns, r.columnNames) {
			return tableedit.ErrStale
		}
		if mariaRowsDigest(rows) != read.digest {
			return tableedit.ErrStale
		}
	}
	grantJSON, e := json.Marshal(grants)
	if e != nil {
		return tableedit.ErrUnsupported
	}
	facts.EngineContext = append(facts.EngineContext, sc.Option{Name: "dependencyScope", Value: "freshAuthenticatedActorRole"}, sc.Option{Name: "dependencyVisibility", Value: string(grantJSON)})
	return nil
}
