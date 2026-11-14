package mariadb

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"dbeer/helper/internal/mysql"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
)

// The caller already owns executeWith. No owner settings or stored expressions
// are changed or evaluated. Binary defaults may require an owned metadata connection.
func (s *Session) readStructureFacts(target tableedit.Target, engine, collation, options, comment string) (*tableedit.Facts, error) {
	limits := sc.Limits{Nodes: 256, Members: 2048, Bytes: 2 << 20, Scalar: 65536}
	sink := sc.NewCollector(context.Background(), limits)
	r := &mariaSchemaCapture{s: s, ctx: context.Background(), spec: sc.CaptureSpec{Schemas: []string{target.Schema}, Limits: limits}, sink: sink, definitions: map[string]string{}}
	settings, e := r.tracked("SELECT @@sql_mode,@@explicit_defaults_for_timestamp,CURRENT_USER(),CURRENT_ROLE(),@@lower_case_table_names,@@character_set_connection,@@collation_connection,@@character_set_results,@@check_constraint_checks,@@sql_quote_show_create,@@character_set_client")
	if e != nil || len(settings) != 1 || len(settings[0]) != 11 {
		return nil, fmt.Errorf("%w: context", tableedit.ErrUnsupported)
	}
	v := settings[0]
	if mariaText(v, 5) != "utf8mb4" || mariaText(v, 7) != "utf8mb4" || mariaText(v, 10) != "utf8mb4" {
		return nil, tableedit.ErrUnsupported
	}
	r.sqlMode = mariaText(v, 0)
	r.explicitTimestamp = mariaText(v, 1) == "1"
	table, e := r.tracked("SELECT TABLE_NAME,ENGINE,TABLE_COLLATION,CREATE_OPTIONS,TABLE_COMMENT,TABLE_TYPE FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ?", target.Schema, target.Table)
	if e != nil || len(table) != 1 || len(table[0]) != 6 || mariaText(table[0], 1) != engine || mariaText(table[0], 2) != collation || mariaText(table[0], 3) != options || mariaText(table[0], 4) != comment || mariaText(table[0], 5) == "SEQUENCE" {
		return nil, fmt.Errorf("%w: table identity", tableedit.ErrUnsupported)
	}
	ref := sc.Ref{Kind: "table", Schema: target.Schema, Name: target.Table}
	if e = r.table(ref, table[0]); e != nil || len(sink.Capture.Tables) != 1 {
		return nil, fmt.Errorf("%w: table facts: %v", tableedit.ErrUnsupported, e)
	}
	facts := &tableedit.Facts{Table: sink.Capture.Tables[0], Types: sink.Capture.Types, IndexAttributes: r.indexAttributes, Dependents: map[string][]string{}, RawExpressions: map[string]string{}}
	for i, key := range map[int]string{0: "sqlMode", 1: "explicitDefaultsForTimestamp", 2: "principal", 3: "activeRole", 4: "lowerCaseTableNames", 5: "connectionCharset", 6: "connectionCollation", 7: "resultCharset", 8: "checkConstraintChecks", 9: "quoteShowCreate", 10: "clientCharset"} {
		facts.EngineContext = append(facts.EngineContext, sc.Option{Name: key, Value: mariaText(v, i)})
	}
	sortMariaOptions(facts.EngineContext)
	roles, e := r.tracked("SELECT ROLE_NAME FROM information_schema.ENABLED_ROLES ORDER BY BINARY ROLE_NAME")
	if e != nil {
		return nil, fmt.Errorf("%w: roles", tableedit.ErrUnsupported)
	}
	roleJSON, e := json.Marshal(mysql.CatalogRawRows(roles))
	if e != nil {
		return nil, fmt.Errorf("%w: role encoding", tableedit.ErrUnsupported)
	}
	facts.EngineContext = append(facts.EngineContext, sc.Option{Name: "enabledRoles", Value: string(roleJSON)})
	if e := r.globalFacts(target, facts); e != nil {
		facts.Proof = false
		facts.Dependents[""] = append(facts.Dependents[""], "Fresh authenticated global dependency metadata is incomplete or unavailable.")
		facts.EngineContext = append(facts.EngineContext, sc.Option{Name: "dependencyScope", Value: "unavailable"})
	}

	for _, read := range r.reads {
		rows, e := r.read(read.sql, read.show, read.args...)
		if e != nil {
			return nil, fmt.Errorf("%w: metadata recheck", tableedit.ErrUnsupported)
		}
		digest := mariaRowsDigest(rows)
		if read.indexOnly {
			if len(rows) != 1 || len(rows[0]) < 2 || rows[0][1] == nil {
				return nil, fmt.Errorf("%w: definition recheck", tableedit.ErrUnsupported)
			}
			digest = mariaDefinitionIndexDigest(*rows[0][1], r.sqlMode)
		}
		if digest != read.digest {
			return nil, tableedit.ErrStale
		}
	}
	if e := r.nativePeriodsFresh(); e != nil {
		return nil, tableedit.ErrStale
	}
	if e := r.nativeDefaultsFresh(); e != nil {
		return nil, tableedit.ErrStale
	}
	sortMariaOptions(facts.EngineContext)
	sort.Strings(facts.Dependents[""])
	raw, e := json.Marshal(facts)
	if e != nil || len(raw) > limits.Bytes || len(facts.Incoming) > limits.Nodes {
		return nil, fmt.Errorf("%w: fact bounds", tableedit.ErrUnsupported)
	}
	return facts, nil
}

func mariaMayReferenceTable(body, contextSchema string, target tableedit.Target, mode string) bool {
	tokens, ok := mariaIndexMetadataTokens(body, mode, 0)
	if !ok {
		return true
	}
	for i, token := range tokens {
		if token.kind != "word" && token.kind != "identifier" {
			continue
		}
		if !strings.EqualFold(token.value, target.Table) {
			continue
		}
		if contextSchema == target.Schema || i >= 2 && tokens[i-1].value == "." && strings.EqualFold(tokens[i-2].value, target.Schema) {
			return true
		}
	}
	return false
}

// Missing-target facts have no observed objects or hidden dependencies.
func newMariaDBStructureFacts(charset, collation string) *tableedit.Facts {
	return &tableedit.Facts{Proof: true, Table: sc.Table{Kind: sc.Known("table"), Storage: sc.Known("InnoDB"), Charset: sc.Known(charset), Collation: sc.Known(sc.Ref{Kind: "collation", Name: collation}), Options: sc.Complete[sc.Option](nil), Columns: sc.Complete[sc.Column](nil), Constraints: sc.Complete[sc.Constraint](nil), Indexes: sc.Complete[sc.Index](nil), Dependencies: sc.Complete[sc.Dependency](nil)}, Dependents: map[string][]string{}}
}
