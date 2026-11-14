package postgres

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

type pgAdvancedCopyLayout struct {
	NameSeed       string
	Orders         map[string][]string
	Replaced       map[string]bool
	Parents        map[string][]string
	CreateInherits map[string]bool
	Targets        map[string]tableedit.Target
	Temporary      map[string]tableedit.Target
	CreateOrder    []string
}

type pgAdvancedCopyPolicy struct {
	Name       string
	Command    string
	Permissive bool
	Roles      []string
	Using      string
	Check      string
}

type pgAdvancedCopyDefinitions struct {
	Policies       map[string][]pgAdvancedCopyPolicy
	Triggers       map[string][]string
	PartitionKey   map[string]string
	PartitionBound map[string]string
	Constraints    map[string]map[string]string
	Indexes        map[string]map[string]string
	Tablespaces    map[string]string
	AccessMethods  map[string]string
}

func pgAdvancedCopySafeNode(ctx context.Context, q structureReader, node any) bool {
	q = pgCatalogReader(q)
	if node == nil {
		return true
	}
	text, ok := node.(string)
	if !ok {
		return false
	}
	var path string
	if q.QueryRow(ctx, `SELECT pg_catalog.current_setting('search_path')`).Scan(&path) != nil || path != "pg_catalog" {
		return false
	}
	var safe bool
	err := q.QueryRow(ctx, `SELECT NOT EXISTS(WITH RECURSIVE expression_types AS (SELECT t.oid,t.typtype,t.typbasetype,t.typoutput,t.typmodout FROM pg_catalog.regexp_matches($1::pg_catalog.text,':[[:alpha:]_]*[tT][yY][pP][eE][[:alpha:]_]*[[:space:]]+([0-9]+)','g') m JOIN pg_catalog.pg_type t ON t.oid=(m[1])::pg_catalog.oid UNION SELECT b.oid,b.typtype,b.typbasetype,b.typoutput,b.typmodout FROM expression_types d JOIN pg_catalog.pg_type b ON b.oid=d.typbasetype WHERE d.typtype='d') SELECT 1 FROM expression_types t WHERE t.typtype='p' OR t.typoutput>=16384 OR t.typmodout>=16384 OR (t.oid>=16384 AND t.typtype NOT IN('e','d')))`, text).Scan(&safe)
	return err == nil && safe
}

// The caller establishes search_path=pg_catalog before this metadata-only read.
// Every node tree is guarded before any native deparser can invoke type output.
func pgAdvancedCopyReadDefinitions(ctx context.Context, q structureReader, b tableedit.Baseline, layout *pgAdvancedCopyLayout) (pgAdvancedCopyDefinitions, error) {
	q = pgCatalogReader(q)
	if err := pgAdvancedCopyDependencyBoundary(b, layout); err != nil {
		return pgAdvancedCopyDefinitions{}, err
	}
	out := pgAdvancedCopyDefinitions{Policies: map[string][]pgAdvancedCopyPolicy{}, Triggers: map[string][]string{}, PartitionKey: map[string]string{}, PartitionBound: map[string]string{}, Constraints: map[string]map[string]string{}, Indexes: map[string]map[string]string{}, Tablespaces: map[string]string{}, AccessMethods: map[string]string{}}
	var path string
	if q.QueryRow(ctx, `SELECT pg_catalog.current_setting('search_path')`).Scan(&path) != nil || path != "pg_catalog" {
		return out, errors.New("Native copy definitions require the positively verified fixed pg_catalog search path.")
	}
	roles := map[string]string{"0": "PUBLIC"}
	for _, role := range b.AdvancedEvidence.Rows["global/roles"] {
		id, name := fmt.Sprint(role["oid"]), fmt.Sprint(role["rolname"])
		if !tableedit.Identifier(name) || roles[id] != "" {
			return out, tableedit.ErrUnsupported
		}
		roles[id] = pgx.Identifier{name}.Sanitize()
	}
	for id := range layout.Targets {
		cl := b.AdvancedEvidence.Rows[id+"/class"][0]
		if cl["relispartition"] == true {
			if !pgAdvancedCopySafeNode(ctx, q, cl["relpartbound"]) || q.QueryRow(ctx, `SELECT pg_catalog.pg_get_expr(c.relpartbound,c.oid,false) FROM pg_catalog.pg_class c WHERE c.oid=$1::pg_catalog.oid AND c.relispartition`, id).Scan(&path) != nil || path == "" {
				return out, errors.New("A partition bound cannot be safely deparsed under its complete captured type context.")
			}
			out.PartitionBound[id] = path
		}
		if cl["relkind"] == "p" {
			partition := b.AdvancedEvidence.Rows[id+"/partition"]
			if len(partition) != 1 || !pgAdvancedCopySafeNode(ctx, q, partition[0]["partexprs"]) || q.QueryRow(ctx, `SELECT pg_catalog.pg_get_partkeydef($1::pg_catalog.oid)`, id).Scan(&path) != nil || path == "" {
				return out, errors.New("A partition key cannot be safely deparsed under its complete captured type context.")
			}
			out.PartitionKey[id] = path
		}
		if !layout.Replaced[id] {
			continue
		}
		if q.QueryRow(ctx, `SELECT t.spcname FROM pg_catalog.pg_class c JOIN pg_catalog.pg_tablespace t ON t.oid=CASE WHEN c.reltablespace=0 THEN (SELECT d.dattablespace FROM pg_catalog.pg_database d WHERE d.datname=pg_catalog.current_database()) ELSE c.reltablespace END WHERE c.oid=$1::pg_catalog.oid AND (t.oid=(SELECT d.dattablespace FROM pg_catalog.pg_database d WHERE d.datname=pg_catalog.current_database()) OR pg_catalog.has_tablespace_privilege(t.oid,'CREATE'))`, id).Scan(&path) != nil || !tableedit.Identifier(path) {
			return out, errors.New("Creating the replacement requires current CREATE authority on its exact retained tablespace.")
		}
		out.Tablespaces[id] = path
		if cl["relkind"] == "r" {
			if q.QueryRow(ctx, `SELECT a.amname FROM pg_catalog.pg_am a WHERE a.oid=$1::pg_catalog.oid AND a.amtype='t'`, fmt.Sprint(cl["relam"])).Scan(&path) != nil || !tableedit.Identifier(path) {
				return out, tableedit.ErrUnsupported
			}
			out.AccessMethods[id] = path
		}
		out.Constraints[id], out.Indexes[id] = map[string]string{}, map[string]string{}
		// EXCLUDE deparse also formats its backing index expressions. Guard all
		// index trees before any constraint deparser can reach those constants.
		for _, row := range b.AdvancedEvidence.Rows[id+"/indexes"] {
			index, ok := row["index"].(map[string]any)
			if ok {
				for _, key := range []string{"indexprs", "indpred"} {
					if _, err := pgAdvancedCopyIndexNodeFormats(index[key]); err != nil {
						return out, err
					}
				}
			}
			if !ok || !pgAdvancedCopySafeNode(ctx, q, index["indexprs"]) || !pgAdvancedCopySafeNode(ctx, q, index["indpred"]) {
				return out, errors.New("A retained index expression requires untrusted type output; Preview stopped before all constraint/index deparse.")
			}
		}
		for _, row := range b.AdvancedEvidence.Rows[id+"/constraints"] {
			if fmt.Sprint(row["conrelid"]) != id {
				continue
			}
			if !pgAdvancedCopySafeNode(ctx, q, row["conbin"]) {
				return out, errors.New("A retained constraint requires untrusted type output; Preview stopped before native deparse.")
			}
			var definition string
			if q.QueryRow(ctx, `SELECT pg_catalog.pg_get_constraintdef(c.oid,false) FROM pg_catalog.pg_constraint c WHERE c.oid=$1::pg_catalog.oid AND c.conrelid=$2::pg_catalog.oid`, fmt.Sprint(row["oid"]), id).Scan(&definition) != nil || definition == "" {
				return out, tableedit.ErrUnsupported
			}
			out.Constraints[id][fmt.Sprint(row["oid"])] = definition
		}
		for _, row := range b.AdvancedEvidence.Rows[id+"/indexes"] {
			index, ok := row["index"].(map[string]any)
			class, valid := row["class"].(map[string]any)
			if !ok || !valid || index["indisvalid"] != true || index["indisready"] != true || index["indislive"] != true {
				return out, errors.New("An invalid, unready or dead index requires explicit separately reviewed reconciliation before relation recreation; no failed concurrent build is manufactured to imitate it.")
			}
			if !pgAdvancedCopySafeNode(ctx, q, index["indexprs"]) || !pgAdvancedCopySafeNode(ctx, q, index["indpred"]) {
				return out, errors.New("A retained index expression requires untrusted type output; Preview stopped before native deparse.")
			}
			if q.QueryRow(ctx, `SELECT pg_catalog.pg_get_indexdef($1::pg_catalog.oid)`, fmt.Sprint(class["oid"])).Scan(&path) != nil || path == "" {
				return out, tableedit.ErrUnsupported
			}
			out.Indexes[id][fmt.Sprint(class["oid"])] = path + ";"
			if q.QueryRow(ctx, `SELECT t.spcname FROM pg_catalog.pg_class c JOIN pg_catalog.pg_tablespace t ON t.oid=CASE WHEN c.reltablespace=0 THEN (SELECT d.dattablespace FROM pg_catalog.pg_database d WHERE d.datname=pg_catalog.current_database()) ELSE c.reltablespace END WHERE c.oid=$1::pg_catalog.oid AND (t.oid=(SELECT d.dattablespace FROM pg_catalog.pg_database d WHERE d.datname=pg_catalog.current_database()) OR pg_catalog.has_tablespace_privilege(t.oid,'CREATE'))`, fmt.Sprint(class["oid"])).Scan(&path) != nil || !tableedit.Identifier(path) {
				return out, errors.New("The exact retained index tablespace and current CREATE authority are required.")
			}
			out.Tablespaces[fmt.Sprint(class["oid"])] = path
		}
		for _, row := range b.AdvancedEvidence.Rows[id+"/policies"] {
			if !pgAdvancedCopySafeNode(ctx, q, row["polqual"]) || !pgAdvancedCopySafeNode(ctx, q, row["polwithcheck"]) {
				return out, errors.New("A policy expression requires untrusted type output support; Preview stopped before invoking that support. Its full raw policy remains captured.")
			}
			policy := pgAdvancedCopyPolicy{Name: fmt.Sprint(row["polname"]), Permissive: row["polpermissive"] == true, Command: map[string]string{"*": "ALL", "r": "SELECT", "a": "INSERT", "w": "UPDATE", "d": "DELETE"}[fmt.Sprint(row["polcmd"])], Roles: []string{}}
			if !tableedit.Identifier(policy.Name) || policy.Command == "" {
				return out, tableedit.ErrUnsupported
			}
			members, ok := row["polroles"].([]any)
			if !ok || len(members) == 0 {
				return out, tableedit.ErrUnsupported
			}
			for _, member := range members {
				role := roles[fmt.Sprint(member)]
				if role == "" {
					return out, errors.New("Every policy role must have a complete captured catalog identity.")
				}
				policy.Roles = append(policy.Roles, role)
			}
			if q.QueryRow(ctx, `SELECT COALESCE(pg_catalog.pg_get_expr(p.polqual,p.polrelid,false),''),COALESCE(pg_catalog.pg_get_expr(p.polwithcheck,p.polrelid,false),'') FROM pg_catalog.pg_policy p WHERE p.oid=$1::pg_catalog.oid AND p.polrelid=$2::pg_catalog.oid`, fmt.Sprint(row["oid"]), id).Scan(&policy.Using, &policy.Check) != nil {
				return out, tableedit.ErrUnsupported
			}
			out.Policies[id] = append(out.Policies[id], policy)
		}
		for _, row := range b.AdvancedEvidence.Rows[id+"/triggers"] {
			if fmt.Sprint(row["tgparentid"]) != "0" || row["tgisinternal"] == true {
				continue // Native attachment recreates exact proven parent clones/RI.
			}
			if !pgAdvancedCopySafeNode(ctx, q, row["tgqual"]) {
				return out, errors.New("A trigger condition requires untrusted type output support; Preview stopped before native trigger deparse.")
			}
			var definition string
			if q.QueryRow(ctx, `SELECT pg_catalog.pg_get_triggerdef(t.oid,false) FROM pg_catalog.pg_trigger t WHERE t.oid=$1::pg_catalog.oid AND t.tgrelid=$2::pg_catalog.oid`, fmt.Sprint(row["oid"]), id).Scan(&definition) != nil || definition == "" {
				return out, tableedit.ErrUnsupported
			}
			out.Triggers[id] = append(out.Triggers[id], definition+";")
		}
	}
	return out, nil
}

func (p pgAdvancedCopyPolicy) SQL(target tableedit.Target) string {
	mode := "RESTRICTIVE"
	if p.Permissive {
		mode = "PERMISSIVE"
	}
	sql := "CREATE POLICY " + pgx.Identifier{p.Name}.Sanitize() + " ON " + pgPhysicalName(target) + " AS " + mode + " FOR " + p.Command + " TO " + strings.Join(p.Roles, ",")
	if p.Using != "" {
		sql += " USING (" + p.Using + ")"
	}
	if p.Check != "" {
		sql += " WITH CHECK (" + p.Check + ")"
	}
	return sql + ";"
}

func pgAdvancedCopyColumnSQL(ctx context.Context, facts *tableedit.Facts, column sc.Column) (string, error) {
	types := map[sc.Ref]sc.TypeDefinition{}
	for _, typ := range facts.Types {
		types[typ.Ref] = typ
	}
	renderer := pgDefinition{w: &sc.DefinitionWriter{Context: ctx}, types: types}
	renderer.column(column, false)
	definition, err := renderer.w.Finish()
	if err != nil || definition.Limited || definition.SQL == "" {
		return "", errors.New("The complete native column type/default/generated/identity definition is not available for explicit reconstruction.")
	}
	return definition.SQL, nil
}

func pgAdvancedCopyRoles(b tableedit.Baseline) (map[string]string, error) {
	out := map[string]string{"0": "PUBLIC"}
	for _, row := range b.AdvancedEvidence.Rows["global/roles"] {
		id, name := fmt.Sprint(row["oid"]), fmt.Sprint(row["rolname"])
		if !tableedit.Identifier(name) || out[id] != "" {
			return nil, tableedit.ErrUnsupported
		}
		out[id] = pgx.Identifier{name}.Sanitize()
	}
	return out, nil
}

func pgAdvancedCopyOptions(options any, prefix string) (string, error) {
	if options == nil {
		return "", nil
	}
	items, ok := options.([]any)
	if !ok {
		return "", tableedit.ErrUnsupported
	}
	out := []string{}
	for _, item := range items {
		text, ok := item.(string)
		if !ok {
			return "", tableedit.ErrUnsupported
		}
		name, value, ok := strings.Cut(text, "=")
		if !ok || !tableedit.Identifier(name) || strings.ContainsAny(name, ".\x00") {
			return "", errors.New("A native storage option cannot be reproduced as one exact catalog option/value.")
		}
		out = append(out, prefix+pgx.Identifier{name}.Sanitize()+"="+postgresTextLiteral(value))
	}
	return strings.Join(out, ","), nil
}

func pgAdvancedCopyAttributeSQL(b tableedit.Baseline, id string, target tableedit.Target) ([]string, error) {
	out := []string{}
	qualified := pgPhysicalName(target)
	for _, a := range b.AdvancedEvidence.Rows[id+"/attributes"] {
		name, ok := a["attname"].(string)
		if !ok || !tableedit.Identifier(name) || a["attisdropped"] == true || a["attfdwoptions"] != nil {
			return nil, tableedit.ErrUnsupported
		}
		prefix := "ALTER TABLE ONLY " + qualified + " ALTER COLUMN " + pgx.Identifier{name}.Sanitize()
		storage := map[string]string{"p": "PLAIN", "e": "EXTERNAL", "m": "MAIN", "x": "EXTENDED"}[fmt.Sprint(a["attstorage"])]
		if storage == "" {
			return nil, errors.New("A retained native column storage kind is not available for exact reconstruction.")
		}
		out = append(out, prefix+" SET STORAGE "+storage+";")
		compression := map[string]string{"": "default", "\x00": "default", "p": "pglz", "l": "lz4"}[fmt.Sprint(a["attcompression"])]
		if compression == "" {
			return nil, errors.New("A retained native compression method is not available for exact reconstruction.")
		}
		out = append(out, prefix+" SET COMPRESSION "+compression+";")
		if a["attstattarget"] != nil {
			n, ok := pgPhysicalNumber(a["attstattarget"])
			if !ok || n < -1 || n > 10000 {
				return nil, tableedit.ErrUnsupported
			}
			out = append(out, prefix+" SET STATISTICS "+strconv.Itoa(n)+";")
		}
		options, err := pgAdvancedCopyOptions(tableedit.SemanticPostgresAttributeOptions(a["attoptions"]), "")
		if err != nil {
			return nil, err
		}
		if options != "" {
			out = append(out, prefix+" SET ("+options+");")
		}
	}
	return out, nil
}

func pgAdvancedCopyACL(ctx context.Context, q structureReader, b tableedit.Baseline, kind, object, owner string, grants []map[string]any) ([]string, error) {
	roles, err := pgAdvancedCopyRoles(b)
	if err != nil || roles[owner] == "" || owner == "0" {
		return nil, tableedit.ErrUnsupported
	}
	allowed := map[string]bool{}
	switch kind {
	case "TABLE":
		for _, p := range []string{"SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES", "TRIGGER", "MAINTAIN"} {
			allowed[p] = true
		}
	case "SEQUENCE":
		for _, p := range []string{"SELECT", "UPDATE", "USAGE"} {
			allowed[p] = true
		}
	case "TYPE":
		allowed["USAGE"] = true
	default:
		return nil, tableedit.ErrUnsupported
	}
	type grant struct {
		grantor, grantee, column string
		option                   bool
		privileges               []string
	}
	grouped := map[string]*grant{}
	revoke, grantors := map[string]bool{"0": true, owner: true}, map[string]bool{owner: true}
	for _, row := range grants {
		grantor, grantee := fmt.Sprint(row["grantor"]), fmt.Sprint(row["grantee"])
		column, cok := row["column"].(string)
		privilege, pok := row["privilege"].(string)
		option, ook := row["grantable"].(bool)
		if !cok || !pok || !ook || roles[grantor] == "" || grantor == "0" || roles[grantee] == "" || !allowed[privilege] || column != "" && (!tableedit.Identifier(column) || kind != "TABLE" || privilege != "SELECT" && privilege != "INSERT" && privilege != "UPDATE" && privilege != "REFERENCES") {
			return nil, errors.New("A retained privilege has no complete bounded native replay shape.")
		}
		key := tableedit.Fingerprint([]any{grantor, grantee, column, option})
		if grouped[key] == nil {
			grouped[key] = &grant{grantor: grantor, grantee: grantee, column: column, option: option}
		}
		grouped[key].privileges = append(grouped[key].privileges, privilege)
		revoke[grantee], grantors[grantor] = true, true
	}
	for _, row := range b.AdvancedEvidence.Rows["global/copyDefaultGrants"] {
		grantee := fmt.Sprint(row["grantee"])
		if roles[grantee] == "" {
			return nil, tableedit.ErrUnsupported
		}
		revoke[grantee] = true
	}
	roleMode := "MEMBER"
	if b.Facts.ServerVersion >= 160000 {
		roleMode = "SET"
	}
	q = pgCatalogReader(q)
	var actor string
	if q.QueryRow(ctx, `SELECT current_user::pg_catalog.text`).Scan(&actor) != nil || !tableedit.Identifier(actor) {
		return nil, tableedit.ErrUnsupported
	}
	restore := "SET LOCAL ROLE " + pgx.Identifier{actor}.Sanitize() + ";"
	for role := range grantors {
		var canSet bool
		if q.QueryRow(ctx, `SELECT pg_catalog.pg_has_role($1::pg_catalog.oid,$2::pg_catalog.text)`, role, roleMode).Scan(&canSet) != nil || !canSet {
			return nil, errors.New("Replaying an exact captured ACL grantor requires existing SET ROLE authority; no membership or privilege is added implicitly.")
		}
	}
	principals := []string{}
	for role := range revoke {
		principals = append(principals, roles[role])
	}
	sort.Strings(principals)
	out := []string{"SET LOCAL ROLE " + roles[owner] + ";", "REVOKE ALL PRIVILEGES ON " + kind + " " + object + " FROM " + strings.Join(principals, ",") + " RESTRICT;", restore}
	// Replay grant chains from their owner roots. A dangling historical grantor
	// cannot be manufactured by temporary privileges or outside-role changes.
	available := map[string]bool{}
	for p := range allowed {
		available[owner+"/"+p+"/"] = true
	}
	for len(grouped) > 0 {
		ready := []string{}
		for key, g := range grouped {
			can := true
			for _, p := range g.privileges {
				can = can && (available[g.grantor+"/"+p+"/"] || available[g.grantor+"/"+p+"/"+g.column])
			}
			if can {
				ready = append(ready, key)
			}
		}
		if len(ready) == 0 {
			return nil, errors.New("The captured ACL grant chain cannot be recreated from its owner without temporary privileges; review an explicit privilege migration first.")
		}
		sort.Strings(ready)
		for _, key := range ready {
			g := grouped[key]
			delete(grouped, key)
			sort.Strings(g.privileges)
			privileges := []string{}
			for _, p := range g.privileges {
				clause := p
				if g.column != "" {
					clause += " (" + pgx.Identifier{g.column}.Sanitize() + ")"
				}
				privileges = append(privileges, clause)
				if g.option {
					available[g.grantee+"/"+p+"/"+g.column] = true
				}
			}
			option := ""
			if g.option {
				option = " WITH GRANT OPTION"
			}
			out = append(out, "SET LOCAL ROLE "+roles[g.grantor]+";", "GRANT "+strings.Join(privileges, ",")+" ON "+kind+" "+object+" TO "+roles[g.grantee]+option+";", restore)
		}
	}
	return out, nil
}

func pgAdvancedCopyColumns(b tableedit.Baseline, id string) ([]string, error) {
	facts := b.AdvancedEvidence.Facts[id]
	if facts == nil || !facts.Proof || !facts.Table.Columns.Complete {
		return nil, tableedit.ErrUnsupported
	}
	out := []string{}
	for _, c := range facts.Table.Columns.Items {
		if !tableedit.Identifier(c.Ref.Name) {
			return nil, tableedit.ErrUnsupported
		}
		out = append(out, c.Ref.Name)
	}
	return out, nil
}

// Declarative attachment restores its nonlocal attribute/constraint flags.
// Traditional NO INHERIT does not: nonlocal descendants must be recreated by
// CREATE ... INHERITS, with their complete native parent declaration order.
func pgAdvancedCopyGraph(b tableedit.Baseline, requested []string, nameSeed ...string) (*pgAdvancedCopyLayout, error) {
	if b.Advanced == nil || b.AdvancedEvidence == nil || len(b.Fingerprint) < 12 {
		return nil, tableedit.ErrUnsupported
	}
	seed := b.Fingerprint
	if len(nameSeed) > 1 {
		return nil, tableedit.ErrInvalid
	}
	if len(nameSeed) == 1 {
		seed = nameSeed[0]
	}
	if len(seed) != 64 || strings.Trim(seed, "0123456789abcdef") != "" {
		return nil, errors.New("The reviewed replacement-name seed is not a complete server-derived digest.")
	}
	proof := b.AdvancedEvidence
	l := &pgAdvancedCopyLayout{NameSeed: seed, Orders: map[string][]string{}, Replaced: map[string]bool{b.Identity: true}, Parents: map[string][]string{}, CreateInherits: map[string]bool{}, Targets: map[string]tableedit.Target{}, Temporary: map[string]tableedit.Target{}, CreateOrder: []string{}}
	for id, facts := range proof.Facts {
		classes := proof.Rows[id+"/class"]
		if facts == nil || len(classes) != 1 {
			return nil, tableedit.ErrUnsupported
		}
		cl := classes[0]
		if cl["relkind"] != "r" && cl["relkind"] != "p" || cl["relpersistence"] != "p" && cl["relpersistence"] != "u" {
			return nil, tableedit.ErrUnsupported
		}
		l.Targets[id] = tableedit.Target{Schema: facts.Table.Ref.Schema, Table: facts.Table.Ref.Name}
		order, err := pgAdvancedCopyColumns(b, id)
		if err != nil || len(order) == 0 {
			return nil, tableedit.ErrUnsupported
		}
		l.Orders[id] = order
		type parent struct {
			id    string
			order int
		}
		parents := []parent{}
		for _, edge := range proof.Rows[id+"/inherits"] {
			if fmt.Sprint(edge["inhrelid"]) != id || len(proof.Rows[fmt.Sprint(edge["inhparent"])+"/class"]) != 1 {
				continue
			}
			if edge["inhdetachpending"] == true {
				return nil, errors.New("A pending native partition detach must be explicitly finalized or reconciled before graph recreation.")
			}
			n, ok := pgPhysicalNumber(edge["inhseqno"])
			if !ok || n < 1 {
				return nil, tableedit.ErrUnsupported
			}
			parents = append(parents, parent{id: fmt.Sprint(edge["inhparent"]), order: n})
		}
		sort.Slice(parents, func(i, j int) bool { return parents[i].order < parents[j].order })
		for i, parent := range parents {
			if parent.order != i+1 {
				return nil, tableedit.ErrUnsupported
			}
			l.Parents[id] = append(l.Parents[id], parent.id)
		}
		if cl["relispartition"] == true && len(parents) != 1 {
			return nil, tableedit.ErrUnsupported
		}
	}
	if len(l.Targets) != len(proof.Targets) || l.Targets[b.Identity] != b.Target {
		return nil, tableedit.ErrUnsupported
	}
	if len(requested) != len(l.Orders[b.Identity]) {
		return nil, tableedit.ErrInvalid
	}
	selected := map[string]bool{}
	for _, name := range l.Orders[b.Identity] {
		selected[name] = true
	}
	for _, name := range requested {
		if !selected[name] {
			return nil, tableedit.ErrInvalid
		}
		delete(selected, name)
	}
	for changed := true; changed; {
		changed = false
		for id, parents := range l.Parents {
			if l.Replaced[id] || proof.Rows[id+"/class"][0]["relispartition"] == true {
				continue
			}
			for _, parent := range parents {
				if l.Replaced[parent] {
					l.Replaced[id], changed = true, true
				}
			}
		}
	}
	remaining := map[string]bool{}
	for id := range l.Replaced {
		remaining[id] = true
		cl := proof.Rows[id+"/class"][0]
		if fmt.Sprint(cl["reloftype"]) != "0" {
			return nil, errors.New("A PostgreSQL typed table takes its physical column shape from its bound composite type. Reordering that binding requires an explicitly reviewed ALTER TYPE operation affecting every bound table; this table operation does not detach its native type binding.")
		}
	}
	for len(remaining) > 0 {
		ready := []string{}
		for id := range remaining {
			blocked := false
			for _, parent := range l.Parents[id] {
				blocked = blocked || remaining[parent]
			}
			if !blocked {
				ready = append(ready, id)
			}
		}
		if len(ready) == 0 {
			return nil, tableedit.ErrUnsupported
		}
		sort.Strings(ready)
		for _, id := range ready {
			delete(remaining, id)
			l.CreateOrder = append(l.CreateOrder, id)
			cl := proof.Rows[id+"/class"][0]
			nonlocal := false
			for _, attr := range proof.Rows[id+"/attributes"] {
				if attr["attisdropped"] == true {
					return nil, errors.New("Dropped physical attribute slots require a separately reviewed native layout migration; graph recreation never invents or silently erases their catalog state.")
				}
				if attr["attinhcount"] != float64(0) && attr["attislocal"] == false {
					nonlocal = true
				}
			}
			l.CreateInherits[id] = cl["relispartition"] != true && nonlocal
			if l.CreateInherits[id] {
				prefix, seen := []string{}, map[string]bool{}
				for _, parent := range l.Parents[id] {
					for _, name := range l.Orders[parent] {
						if !seen[name] {
							prefix, seen[name] = append(prefix, name), true
						}
					}
				}
				if id == b.Identity {
					if len(requested) < len(prefix) {
						return nil, tableedit.ErrInvalid
					}
					for i, name := range prefix {
						if requested[i] != name {
							return nil, errors.New("Native CREATE INHERITS declares nonlocal inherited columns in parent declaration order. Reorder their declaring parent family explicitly; this selected child operation preserves its nonlocal inheritance semantics.")
						}
					}
				} else {
					for _, name := range l.Orders[id] {
						if !seen[name] {
							prefix, seen[name] = append(prefix, name), true
						}
					}
					l.Orders[id] = prefix
				}
			}
			if id == b.Identity {
				l.Orders[id] = append([]string(nil), requested...)
			}
			target := l.Targets[id]
			target.Table = "__dbeer_copy_" + seed[:12] + "_" + id
			l.Temporary[id] = target
		}
	}
	return l, nil
}

// Copy metadata is private reviewed-plan evidence. It enriches a cloned native
// baseline; ordinary metadata observation and portable drafts do not acquire it.
func pgAdvancedCopyMetadata(ctx context.Context, q structureReader, b *tableedit.Baseline) error {
	q = pgCatalogReader(q)
	if b == nil || b.AdvancedEvidence == nil {
		return tableedit.ErrUnsupported
	}
	var path string
	if q.QueryRow(ctx, `SELECT pg_catalog.current_setting('search_path')`).Scan(&path) != nil || path != "pg_catalog" {
		return errors.New("Copy metadata requires the positively verified fixed pg_catalog search path before catalog interpretation.")
	}
	if err := pgAdvancedNativeExtras(ctx, q, b); err != nil {
		return err
	}
	ids := []uint32{}
	for key, rows := range b.AdvancedEvidence.Rows {
		if !strings.HasSuffix(key, "/class") {
			continue
		}
		id, err := strconv.ParseUint(strings.TrimSuffix(key, "/class"), 10, 32)
		if err != nil || id == 0 || len(rows) != 1 {
			return tableedit.ErrUnsupported
		}
		ids = append(ids, uint32(id))
	}
	if len(ids) != len(b.AdvancedEvidence.Targets) {
		return tableedit.ErrUnsupported
	}
	for _, id := range ids {
		sequences, err := pgAdvancedGenerationCatalog(ctx, q, id)
		if err != nil {
			return err
		}
		b.AdvancedEvidence.Rows[fmt.Sprint(id)+"/sequences"] = sequences
		// NULL table ACL is its exact effective owner default; NULL column ACL
		// has no explicit column grant. No aclitem text parsing is necessary.
		rows, err := pgAdvancedRows(ctx, q, `WITH grants AS (SELECT ''::pg_catalog.text AS column_name,x.grantor,x.grantee,x.privilege_type,x.is_grantable FROM pg_catalog.pg_class c CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(c.relacl,pg_catalog.acldefault('r',c.relowner))) x WHERE c.oid=$1 UNION ALL SELECT a.attname::pg_catalog.text,x.grantor,x.grantee,x.privilege_type,x.is_grantable FROM pg_catalog.pg_attribute a CROSS JOIN LATERAL pg_catalog.aclexplode(a.attacl) x WHERE a.attrelid=$1 AND a.attnum>0 AND NOT a.attisdropped) SELECT pg_catalog.json_build_object('column',g.column_name,'grantor',g.grantor::pg_catalog.text,'grantee',g.grantee::pg_catalog.text,'privilege',g.privilege_type,'grantable',g.is_grantable)::pg_catalog.text FROM grants g ORDER BY g.column_name COLLATE pg_catalog."C",g.grantor,g.grantee,g.privilege_type COLLATE pg_catalog."C",g.is_grantable LIMIT 2049`, id)
		if err != nil || len(rows) > 2048 {
			return errors.New("Complete effective table/column privilege proof exceeds its bounded catalog envelope.")
		}
		b.AdvancedEvidence.Rows[fmt.Sprint(id)+"/copyPrivileges"] = rows
		for _, seq := range b.AdvancedEvidence.Rows[fmt.Sprint(id)+"/sequences"] {
			cl, ok := seq["class"].(map[string]any)
			if !ok {
				return tableedit.ErrUnsupported
			}
			privileges, err := pgAdvancedRows(ctx, q, `SELECT pg_catalog.json_build_object('column','','grantor',x.grantor::pg_catalog.text,'grantee',x.grantee::pg_catalog.text,'privilege',x.privilege_type,'grantable',x.is_grantable)::pg_catalog.text FROM pg_catalog.pg_class c CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(c.relacl,pg_catalog.acldefault('s',c.relowner))) x WHERE c.oid=$1::pg_catalog.oid AND c.relkind='S' ORDER BY x.grantor,x.grantee,x.privilege_type COLLATE pg_catalog."C",x.is_grantable LIMIT 2049`, fmt.Sprint(cl["oid"]))
			if err != nil || len(privileges) > 2048 {
				return errors.New("Complete effective sequence privileges are required before identity recreation.")
			}
			seq["copyPrivileges"] = privileges
		}
	}
	functions, err := pgAdvancedRows(ctx, q, `SELECT pg_catalog.row_to_json(p)::pg_catalog.text FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace JOIN pg_catalog.pg_language l ON l.oid=p.prolang WHERE n.nspname='pg_catalog' AND l.lanname='internal' AND p.oid<16384 AND p.prosrc=p.proname AND p.prorettype='pg_catalog.trigger'::pg_catalog.regtype AND p.pronargs=0 AND p.pronargdefaults=0 AND p.proconfig IS NULL AND NOT p.prosecdef AND p.proname IN ('RI_FKey_check_ins','RI_FKey_check_upd','RI_FKey_noaction_del','RI_FKey_noaction_upd','RI_FKey_restrict_del','RI_FKey_restrict_upd','RI_FKey_cascade_del','RI_FKey_cascade_upd','RI_FKey_setnull_del','RI_FKey_setnull_upd','RI_FKey_setdefault_del','RI_FKey_setdefault_upd') ORDER BY p.proname COLLATE pg_catalog."C"`)
	if err != nil || len(functions) != 12 {
		return errors.New("Complete built-in referential-integrity function identities are required before graph recreation.")
	}
	b.AdvancedEvidence.Rows["global/copyRIFunctions"] = functions
	defaults, err := pgAdvancedRows(ctx, q, `SELECT pg_catalog.row_to_json(d)::pg_catalog.text FROM pg_catalog.pg_default_acl d ORDER BY d.defaclrole,d.defaclnamespace,d.defaclobjtype LIMIT 2049`)
	if err != nil || len(defaults) > 2048 {
		return errors.New("Complete default-privilege metadata is required before creating replacement objects.")
	}
	b.AdvancedEvidence.Rows["global/copyDefaultPrivileges"] = defaults
	defaultGrants, err := pgAdvancedRows(ctx, q, `SELECT pg_catalog.json_build_object('owner',d.defaclrole::pg_catalog.text,'schema',d.defaclnamespace::pg_catalog.text,'kind',d.defaclobjtype::pg_catalog.text,'grantor',x.grantor::pg_catalog.text,'grantee',x.grantee::pg_catalog.text,'privilege',x.privilege_type,'grantable',x.is_grantable)::pg_catalog.text FROM pg_catalog.pg_default_acl d CROSS JOIN LATERAL pg_catalog.aclexplode(d.defaclacl) x ORDER BY d.defaclrole,d.defaclnamespace,d.defaclobjtype,x.grantor,x.grantee,x.privilege_type COLLATE pg_catalog."C" LIMIT 2049`)
	if err != nil || len(defaultGrants) > 2048 {
		return errors.New("Complete default-grant principals are required to restore only the captured replacement-object permissions.")
	}
	b.AdvancedEvidence.Rows["global/copyDefaultGrants"] = defaultGrants
	return nil
}

type pgAdvancedCopyEnvelope struct {
	Actor             string
	SearchPath        string
	DefaultTablespace string
	Evidence          *tableedit.AdvancedEvidence
	Layout            *pgAdvancedCopyLayout
	Family            *pgAdvancedCopyFamilySteps
	Repairs           []pgAdvancedCopyRepair
	RepairEvidence    *tableedit.AdvancedEvidence
	CopyStep          int
	DropStep          int
}

// Native ATTACH creates inherited keys with their server-owned locality flags.
// Creating a local key first leaves a different connoinherit property behind.
func pgAdvancedCopyInheritedKeys(b tableedit.Baseline, l *pgAdvancedCopyLayout) (map[string]bool, []string, error) {
	deferred := map[string]bool{}
	statements := []string{}
	for _, id := range l.CreateOrder {
		if b.AdvancedEvidence.Rows[id+"/class"][0]["relispartition"] != true {
			continue
		}
		for _, key := range b.AdvancedEvidence.Rows[id+"/constraints"] {
			if pgPhysicalOID(key["conrelid"]) != id || key["contype"] != "p" && key["contype"] != "u" || pgPhysicalOID(key["conparentid"]) == "" {
				continue
			}
			var parent map[string]any
			for _, owner := range l.Parents[id] {
				for _, row := range b.AdvancedEvidence.Rows[owner+"/constraints"] {
					if pgPhysicalOID(row["oid"]) == pgPhysicalOID(key["conparentid"]) && pgPhysicalOID(row["conrelid"]) == owner && row["contype"] == key["contype"] {
						parent = row
					}
				}
			}
			var index map[string]any
			for _, row := range b.AdvancedEvidence.Rows[id+"/indexes"] {
				class, ok := row["class"].(map[string]any)
				if ok && pgPhysicalOID(class["oid"]) == pgPhysicalOID(key["conindid"]) {
					index = class
				}
			}
			name, ok := key["conname"].(string)
			if parent == nil || index == nil || !ok || !tableedit.Identifier(name) || index["relname"] != name || !tableedit.Identifier(fmt.Sprint(parent["conname"])) {
				return nil, nil, errors.New("The inherited key requires its exact native parent and matching captured constraint/index name before recreation.")
			}
			deferred[pgPhysicalOID(key["conindid"])] = true
			target, ancestor := l.Targets[id], l.Targets[pgPhysicalOID(parent["conrelid"])]
			body := `DECLARE captured pg_catalog.name; BEGIN SELECT c.conname INTO STRICT captured FROM pg_catalog.pg_constraint c JOIN pg_catalog.pg_constraint p ON p.oid OPERATOR(pg_catalog.=) c.conparentid WHERE c.conrelid OPERATOR(pg_catalog.=) ` + postgresTextLiteral(pgPhysicalName(target)) + `::pg_catalog.regclass AND p.conrelid OPERATOR(pg_catalog.=) ` + postgresTextLiteral(pgPhysicalName(ancestor)) + `::pg_catalog.regclass AND p.conname OPERATOR(pg_catalog.=) ` + postgresTextLiteral(fmt.Sprint(parent["conname"])) + `::pg_catalog.name AND c.contype OPERATOR(pg_catalog.=) ` + postgresTextLiteral(fmt.Sprint(key["contype"])) + `::pg_catalog."char"; IF captured IS DISTINCT FROM ` + postgresTextLiteral(name) + `::pg_catalog.name THEN EXECUTE pg_catalog.format('ALTER TABLE %I.%I RENAME CONSTRAINT %I TO %I',` + postgresTextLiteral(target.Schema) + `,` + postgresTextLiteral(target.Table) + `,captured,` + postgresTextLiteral(name) + `); END IF; END;`
			statements = append(statements, "DO LANGUAGE plpgsql "+postgresTextLiteral(body)+";")
		}
	}
	return deferred, statements, nil
}

func pgAdvancedCopyNamedAttribute(rows []map[string]any, name string) map[string]any {
	var found map[string]any
	for _, row := range rows {
		if row["attname"] == name {
			if found != nil {
				return nil
			}
			found = row
		}
	}
	return found
}

// Object addresses are rendered from their captured catalog and native names;
// neither object-name text nor an unqualified OID is an authority to rewrite SQL.
func pgAdvancedCopyObjectClause(b tableedit.Baseline, id string, row map[string]any, target tableedit.Target) (string, error) {
	class, object := fmt.Sprint(row["classoid"]), fmt.Sprint(row["objoid"])
	sub, err := strconv.Atoi(fmt.Sprint(row["objsubid"]))
	if err != nil {
		return "", tableedit.ErrUnsupported
	}
	if class == "1259" && object == id {
		if sub == 0 {
			return "TABLE " + pgPhysicalName(target), nil
		}
		for _, a := range b.AdvancedEvidence.Rows[id+"/attributes"] {
			if fmt.Sprint(a["attnum"]) == fmt.Sprint(sub) {
				return "COLUMN " + pgPhysicalName(target) + "." + pgx.Identifier{fmt.Sprint(a["attname"])}.Sanitize(), nil
			}
		}
	}
	if sub != 0 {
		return "", tableedit.ErrUnsupported
	}
	if class == "1247" {
		for _, t := range b.AdvancedEvidence.Rows[id+"/types"] {
			if fmt.Sprint(t["oid"]) == object && fmt.Sprint(t["typrelid"]) == id {
				return "TYPE " + pgPhysicalName(target), nil
			}
			if fmt.Sprint(t["typrelid"]) == id && fmt.Sprint(t["typarray"]) == object {
				return "TYPE " + pgPhysicalName(target) + "[]", nil
			}
		}
	}
	for _, spec := range []struct{ category, catalog, name, keyword string }{{"constraints", "2606", "conname", "CONSTRAINT"}, {"triggers", "2620", "tgname", "TRIGGER"}, {"policies", "3256", "polname", "POLICY"}} {
		if class != spec.catalog {
			continue
		}
		for _, objectRow := range b.AdvancedEvidence.Rows[id+"/"+spec.category] {
			if fmt.Sprint(objectRow["oid"]) == object {
				return spec.keyword + " " + pgx.Identifier{fmt.Sprint(objectRow[spec.name])}.Sanitize() + " ON " + pgPhysicalName(target), nil
			}
		}
	}
	if class == "1259" {
		for _, r := range b.AdvancedEvidence.Rows[id+"/indexes"] {
			c, ok := r["class"].(map[string]any)
			if ok && fmt.Sprint(c["oid"]) == object {
				return "INDEX " + pgx.Identifier{target.Schema, fmt.Sprint(c["relname"])}.Sanitize(), nil
			}
		}
	}
	return "", errors.New("A captured comment or security-label object requires an explicit additional native object migration before reconstruction.")
}

// A replacement TOAST index OID/name is allocated only during Apply. This
// reviewed block resolves just that table's unique native storage index under
// the fixed pg_catalog context; captured text is always a format argument.
func pgAdvancedCopyToastIndexSQL(target tableedit.Target, command string, values ...string) string {
	body := `DECLARE n pg_catalog.name; r pg_catalog.name; BEGIN SELECT ns.nspname,ic.relname INTO STRICT n,r FROM pg_catalog.pg_class c JOIN pg_catalog.pg_index ix ON ix.indrelid OPERATOR(pg_catalog.=) c.reltoastrelid JOIN pg_catalog.pg_class ic ON ic.oid OPERATOR(pg_catalog.=) ix.indexrelid JOIN pg_catalog.pg_namespace ns ON ns.oid OPERATOR(pg_catalog.=) ic.relnamespace WHERE c.oid OPERATOR(pg_catalog.=) ` + postgresTextLiteral(pgPhysicalName(target)) + `::pg_catalog.regclass AND ix.indisunique AND ix.indisvalid AND ix.indisready AND ix.indislive; EXECUTE pg_catalog.format(` + postgresTextLiteral(command) + `,n,r`
	for _, value := range values {
		body += "," + postgresTextLiteral(value)
	}
	return "DO LANGUAGE plpgsql " + postgresTextLiteral(body+`); END;`) + ";"
}

func pgAdvancedCopyStorageComment(b tableedit.Baseline, id string, row map[string]any, target tableedit.Target) (string, bool, error) {
	if fmt.Sprint(row["classoid"]) != "1259" {
		return "", false, nil
	}
	for _, toast := range b.AdvancedEvidence.Rows[id+"/toast"] {
		for _, raw := range toast["indexes"].([]any) {
			index := raw.(map[string]any)
			class := index["class"].(map[string]any)
			if fmt.Sprint(class["oid"]) != fmt.Sprint(row["objoid"]) {
				continue
			}
			text, ok := row["description"].(string)
			if !ok || fmt.Sprint(row["objsubid"]) != "0" || len(toast["indexes"].([]any)) != 1 {
				return "", true, errors.New("The complete unique native TOAST-index comment address is unavailable.")
			}
			_ = text
			return "", true, nil // Restored by the standalone native-index property renderer.
		}
	}
	return "", false, nil
}

func pgAdvancedCopyIndexSettings(b tableedit.Baseline, id string, target tableedit.Target, d pgAdvancedCopyDefinitions) ([]string, error) {
	out, err := pgAdvancedNativeIndexRestoreSQL(b, id, target)
	if err != nil {
		return nil, err
	}
	for _, row := range b.AdvancedEvidence.Rows[id+"/indexes"] {
		class := row["class"].(map[string]any)
		if class["relkind"] != "i" || fmt.Sprint(class["reltablespace"]) == "0" {
			continue
		}
		space := d.Tablespaces[fmt.Sprint(class["oid"])]
		if !tableedit.Identifier(space) {
			return nil, tableedit.ErrUnsupported
		}
		out = append(out, "ALTER INDEX "+pgx.Identifier{target.Schema, fmt.Sprint(class["relname"])}.Sanitize()+" SET TABLESPACE "+pgx.Identifier{space}.Sanitize()+";")
	}
	return out, nil
}

func pgAdvancedCopyCompose(ctx context.Context, q structureReader, b tableedit.Baseline, e *pgAdvancedCopyEnvelope, d pgAdvancedCopyDefinitions) ([]string, error) {
	l := e.Layout
	family, err := pgAdvancedCopyFamilyPlan(b, l, d)
	if err != nil {
		return nil, err
	}
	e.Family = family
	inheritedKeys, keyNames, err := pgAdvancedCopyInheritedKeys(b, l)
	if err != nil {
		return nil, err
	}
	groups := make([][]string, 8)
	validations := map[string][]string{}
	groups[1] = []string{"SET LOCAL default_tablespace='';"}
	groups[1] = append(groups[1], family.BeforeCreate...)
	groups[0] = []string{"SET LOCAL search_path=pg_catalog;"}
	roles, err := pgAdvancedCopyRoles(b)
	if err != nil {
		return nil, err
	}
	for _, id := range l.CreateOrder {
		cl, target := b.AdvancedEvidence.Rows[id+"/class"][0], family.Destinations[id]
		if len(b.AdvancedEvidence.Rows[id+"/rules"])+len(b.AdvancedEvidence.Rows[id+"/statistics"])+len(b.AdvancedEvidence.Rows[id+"/publication"]) != 0 {
			return nil, errors.New("Recreating rules, extended-statistics and publication memberships requires their separately reviewed object-identity mapping; the current complete proof does not discard or silently normalize those objects.")
		}
		for _, row := range b.AdvancedEvidence.Rows[id+"/constraints"] {
			if row["contype"] == "f" {
				return nil, errors.New("Foreign-key graph recreation requires the complete source/reference repair envelope. Review those dependencies through the existing explicit migration workflow before this copy plan; no outside foreign key is dropped automatically.")
			}
		}
		for _, seq := range b.AdvancedEvidence.Rows[id+"/sequences"] {
			identity, err := pgAdvancedCopySequenceOrigin(seq, id, b.AdvancedEvidence.Rows[id+"/attributes"])
			if err != nil {
				return nil, err
			}
			if identity {
				return nil, errors.New("An identity-owned sequence cannot be detached from its native internal ownership by ALTER SEQUENCE. Recreating it changes its OID and other backends' private currval/cache state, which no catalog or row copy can transfer. Review a separate identity/session migration, or retain native identities with same-order reconstruction.")
			}
			class := seq["class"].(map[string]any)
			if class["relnamespace"] != cl["relnamespace"] || class["relowner"] != cl["relowner"] || !tableedit.Identifier(fmt.Sprint(class["relname"])) {
				return nil, errors.New("Retaining a serial sequence requires its exact native same-owner/schema ownership binding.")
			}
			sequence := pgx.Identifier{l.Targets[id].Schema, fmt.Sprint(class["relname"])}.Sanitize()
			groups[3] = append(groups[3], "ALTER SEQUENCE "+sequence+" OWNED BY NONE;")
			groups[6] = append(groups[6], "ALTER SEQUENCE "+sequence+" OWNED BY "+pgPhysicalName(l.Targets[id])+"."+pgx.Identifier{fmt.Sprint(seq["column"])}.Sanitize()+";")
		}
		facts := b.AdvancedEvidence.Facts[id]
		columns := map[string]sc.Column{}
		for _, c := range facts.Table.Columns.Items {
			columns[c.Ref.Name] = c
		}
		definitions := []string{}
		for _, name := range l.Orders[id] {
			c, ok := columns[name]
			a := pgAdvancedCopyNamedAttribute(b.AdvancedEvidence.Rows[id+"/attributes"], name)
			if !ok || a == nil {
				return nil, errors.New("A reviewed column is absent from its complete typed/attribute capture.")
			}
			if l.CreateInherits[id] && a["attislocal"] == false {
				continue
			}
			c.Default, c.Identity, c.Nullable = sc.Known(sc.Default{Kind: "none"}), sc.Known(sc.Identity{Kind: "none"}), sc.Known(true)
			definition, err := pgAdvancedCopyColumnSQL(ctx, facts, c)
			if err != nil {
				return nil, err
			}
			if a["attnotnull"] == true {
				clause := family.InlineNotNull[id][name]
				if clause == "" {
					return nil, errors.New("The exact reviewed native NOT NULL definition is unavailable.")
				}
				definition += " " + clause
			}
			definitions = append(definitions, definition)
		}
		persistence := ""
		if cl["relpersistence"] == "u" {
			persistence = "UNLOGGED "
		}
		create := "CREATE " + persistence + "TABLE " + pgPhysicalName(target) + " (" + strings.Join(definitions, ",") + ")"
		if l.CreateInherits[id] {
			parents := []string{}
			for _, parent := range l.Parents[id] {
				t := l.Targets[parent]
				if l.Replaced[parent] {
					t = family.Destinations[parent]
				}
				parents = append(parents, pgPhysicalName(t))
			}
			create += " INHERITS (" + strings.Join(parents, ",") + ")"
		}
		if cl["relkind"] == "p" {
			create += " PARTITION BY " + d.PartitionKey[id]
		} else {
			create += " USING " + pgx.Identifier{d.AccessMethods[id]}.Sanitize()
		}
		options, err := pgAdvancedCopyOptions(cl["reloptions"], "")
		if err != nil {
			return nil, err
		}
		for _, toast := range b.AdvancedEvidence.Rows[id+"/toast"] {
			to, ok := toast["class"].(map[string]any)
			if !ok {
				return nil, errors.New("The captured native TOAST class is incomplete.")
			}
			value, err := pgAdvancedCopyOptions(to["reloptions"], "toast.")
			if err != nil {
				return nil, err
			}
			if value != "" {
				if options != "" {
					options += ","
				}
				options += value
			}
		}
		if options != "" {
			create += " WITH (" + options + ")"
		}
		if cl["relkind"] != "p" || fmt.Sprint(cl["reltablespace"]) != "0" {
			create += " TABLESPACE " + pgx.Identifier{d.Tablespaces[id]}.Sanitize()
		}
		create += ";"
		groups[1] = append(groups[1], create)
		attrs, err := pgAdvancedCopyAttributeSQL(b, id, target)
		if err != nil {
			return nil, fmt.Errorf("Native column storage/options: %w", err)
		}
		groups[1] = append(groups[1], attrs...)
		for _, p := range d.Policies[id] {
			groups[1] = append(groups[1], p.SQL(target))
		}
		for _, property := range []struct{ name, clause string }{{"relrowsecurity", "ENABLE ROW LEVEL SECURITY"}, {"relforcerowsecurity", "FORCE ROW LEVEL SECURITY"}} {
			if cl[property.name] == true {
				groups[1] = append(groups[1], "ALTER TABLE ONLY "+pgPhysicalName(target)+" "+property.clause+";")
			}
		}
		owner := fmt.Sprint(cl["relowner"])
		if roles[owner] == "" {
			return nil, errors.New("The temporary table owner has no captured role identity.")
		}
		groups[1] = append(groups[1], "ALTER TABLE ONLY "+pgPhysicalName(target)+" OWNER TO "+roles[owner]+";")
		acl, err := pgAdvancedCopyACL(ctx, q, b, "TABLE", pgPhysicalName(target), owner, b.AdvancedEvidence.Rows[id+"/copyPrivileges"])
		if err != nil {
			return nil, fmt.Errorf("Replacement privileges: %w", err)
		}
		groups[1] = append(groups[1], acl...)
		for _, label := range b.AdvancedEvidence.Rows[id+"/labels"] {
			object, err := pgAdvancedCopyObjectClause(b, id, label, target)
			if err != nil || !strings.HasPrefix(object, "TABLE ") && !strings.HasPrefix(object, "COLUMN ") && !strings.HasPrefix(object, "TYPE ") {
				return nil, errors.New("A retained security label requires its provider-specific native migration before copy; no unsupported object label is dropped or bypassed implicitly.")
			}
			provider, pok := label["provider"].(string)
			value, vok := label["label"].(string)
			if !pok || !vok || !tableedit.Identifier(provider) {
				return nil, tableedit.ErrUnsupported
			}
			groups[1] = append(groups[1], "SECURITY LABEL FOR "+pgx.Identifier{provider}.Sanitize()+" ON "+object+" IS "+postgresTextLiteral(value)+";")
		}
		if cl["relkind"] != "p" {
			names := []string{}
			for _, c := range facts.Table.Columns.Items {
				if c.Generated.Value != nil && c.Generated.Value.Kind != "none" {
					continue
				}
				names = append(names, pgx.Identifier{c.Ref.Name}.Sanitize())
			}
			if len(names) == 0 {
				groups[2] = append(groups[2], "INSERT INTO "+pgPhysicalName(target)+" SELECT FROM ONLY "+pgPhysicalName(family.RowSources[id])+";")
			} else {
				groups[2] = append(groups[2], "INSERT INTO "+pgPhysicalName(target)+" ("+strings.Join(names, ",")+") SELECT "+strings.Join(names, ",")+" FROM ONLY "+pgPhysicalName(family.RowSources[id])+";")
			}
		}
	}
	groups[1] = append(groups[1], family.BeforeCopy...)
	groups[3] = append(groups[3], family.BeforeDrop...)
	for i := len(l.CreateOrder) - 1; i >= 0; i-- {
		id := l.CreateOrder[i]
		groups[3] = append(groups[3], "DROP TABLE "+pgPhysicalName(family.RowSources[id])+" RESTRICT;")
	}
	groups[3] = append(groups[3], family.AfterDrop...)
	groups[5] = append(groups[5], family.AfterIndexes...)
	groups[5] = append(groups[5], keyNames...)
	// Local checks first, then recursive ancestor checks, preserve both
	// conislocal and coninhcount. Validation is restored only after all copies.
	for i := len(l.CreateOrder) - 1; i >= 0; i-- {
		id := l.CreateOrder[i]
		for _, c := range b.AdvancedEvidence.Rows[id+"/constraints"] {
			if fmt.Sprint(c["conrelid"]) != id || c["contype"] != "c" || c["conislocal"] != true && b.AdvancedEvidence.Rows[id+"/class"][0]["relispartition"] != true {
				continue
			}
			definition := strings.TrimSuffix(d.Constraints[id][fmt.Sprint(c["oid"])], " NOT VALID")
			groups[4] = append(groups[4], "ALTER TABLE "+pgPhysicalName(l.Targets[id])+" ADD CONSTRAINT "+pgx.Identifier{fmt.Sprint(c["conname"])}.Sanitize()+" "+definition+" NOT VALID;")
		}
	}
	for _, id := range l.CreateOrder {
		target := pgPhysicalName(l.Targets[id])
		backing := map[string]bool{}
		for _, c := range b.AdvancedEvidence.Rows[id+"/constraints"] {
			if pgPhysicalOID(c["conrelid"]) == id && inheritedKeys[pgPhysicalOID(c["conindid"])] {
				backing[pgPhysicalOID(c["conindid"])] = true
				continue
			}
			if fmt.Sprint(c["conrelid"]) != id || (c["conislocal"] != true || fmt.Sprint(c["conparentid"]) != "0") && b.AdvancedEvidence.Rows[id+"/class"][0]["relispartition"] != true {
				continue
			}
			if c["contype"] == "p" || c["contype"] == "u" || c["contype"] == "x" {
				groups[4] = append(groups[4], "ALTER TABLE "+target+" ADD CONSTRAINT "+pgx.Identifier{fmt.Sprint(c["conname"])}.Sanitize()+" "+d.Constraints[id][fmt.Sprint(c["oid"])]+";")
				backing[fmt.Sprint(c["conindid"])] = true
			}
		}
		for _, index := range b.AdvancedEvidence.Rows[id+"/indexes"] {
			cl := index["class"].(map[string]any)
			if !backing[fmt.Sprint(cl["oid"])] {
				groups[4] = append(groups[4], d.Indexes[id][fmt.Sprint(cl["oid"])])
			}
			if index["index"].(map[string]any)["indisclustered"] == true {
				groups[6] = append(groups[6], "ALTER TABLE ONLY "+target+" CLUSTER ON "+pgx.Identifier{fmt.Sprint(cl["relname"])}.Sanitize()+";")
			}
		}
		for _, column := range b.AdvancedEvidence.Facts[id].Table.Columns.Items {
			if column.Default.Value != nil && column.Default.Value.Kind != "none" && (column.Generated.Value == nil || column.Generated.Value.Kind == "none") {
				r := pgDefinition{w: &sc.DefinitionWriter{Context: ctx}}
				r.defaultSQL(*column.Default.Value)
				definition, err := r.w.Finish()
				if err != nil || definition.Limited {
					return nil, errors.New("The captured default cannot be rendered as a complete native SQL definition.")
				}
				groups[6] = append(groups[6], "ALTER TABLE ONLY "+target+" ALTER COLUMN "+pgx.Identifier{column.Ref.Name}.Sanitize()+" SET"+definition.SQL+";")
			}
		}
		groups[6] = append(groups[6], d.Triggers[id]...)
		for _, trigger := range b.AdvancedEvidence.Rows[id+"/triggers"] {
			if trigger["tgisinternal"] == true || fmt.Sprint(trigger["tgparentid"]) != "0" {
				continue
			}
			mode := map[string]string{"O": "ENABLE TRIGGER", "D": "DISABLE TRIGGER", "R": "ENABLE REPLICA TRIGGER", "A": "ENABLE ALWAYS TRIGGER"}[fmt.Sprint(trigger["tgenabled"])]
			if mode == "" {
				return nil, errors.New("A retained native trigger has no complete enabled-mode definition.")
			}
			groups[6] = append(groups[6], "ALTER TABLE ONLY "+target+" "+mode+" "+pgx.Identifier{fmt.Sprint(trigger["tgname"])}.Sanitize()+";")
		}
		indexSettings, err := pgAdvancedCopyIndexSettings(b, id, l.Targets[id], d)
		if err != nil {
			return nil, err
		}
		groups[6] = append(groups[6], indexSettings...)
		replica := fmt.Sprint(b.AdvancedEvidence.Rows[id+"/class"][0]["relreplident"])
		replicaSQL := map[string]string{"d": "DEFAULT", "n": "NOTHING", "f": "FULL"}[replica]
		if replica == "i" {
			for _, index := range b.AdvancedEvidence.Rows[id+"/indexes"] {
				if index["index"].(map[string]any)["indisreplident"] == true {
					if replicaSQL != "" {
						return nil, tableedit.ErrUnsupported
					}
					replicaSQL = "USING INDEX " + pgx.Identifier{fmt.Sprint(index["class"].(map[string]any)["relname"])}.Sanitize()
				}
			}
		}
		if replicaSQL == "" {
			return nil, errors.New("The complete native replica-identity index binding is unavailable.")
		}
		groups[6] = append(groups[6], "ALTER TABLE ONLY "+target+" REPLICA IDENTITY "+replicaSQL+";")
		for _, c := range b.AdvancedEvidence.Rows[id+"/constraints"] {
			if fmt.Sprint(c["conrelid"]) == id && c["contype"] == "c" && c["convalidated"] == true {
				validationTarget := target
				if c["connoinherit"] == true {
					validationTarget = "ONLY " + target
				}
				validations[id] = append(validations[id], "ALTER TABLE "+validationTarget+" VALIDATE CONSTRAINT "+pgx.Identifier{fmt.Sprint(c["conname"])}.Sanitize()+";")
			}
		}
		owner := fmt.Sprint(b.AdvancedEvidence.Rows[id+"/class"][0]["relowner"])
		if roles[owner] == "" {
			return nil, errors.New("The final table owner has no captured role identity.")
		}
		groups[6] = append(groups[6], "ALTER TABLE ONLY "+target+" OWNER TO "+roles[owner]+";")
		acl, err := pgAdvancedCopyACL(ctx, q, b, "TABLE", target, owner, b.AdvancedEvidence.Rows[id+"/copyPrivileges"])
		if err != nil {
			return nil, err
		}
		groups[6] = append(groups[6], acl...)
		for _, category := range []string{"comments", "labels"} {
			if category == "labels" {
				continue // Labels were restored on the native destinations before COPY.
			}
			for _, row := range b.AdvancedEvidence.Rows[id+"/"+category] {
				if category == "comments" {
					statement, handled, err := pgAdvancedCopyStorageComment(b, id, row, l.Targets[id])
					if err != nil {
						return nil, err
					}
					if handled {
						if statement != "" {
							groups[6] = append(groups[6], statement)
						}
						continue
					}
				}
				object, err := pgAdvancedCopyObjectClause(b, id, row, l.Targets[id])
				if err != nil {
					return nil, err
				}
				if category == "comments" {
					value, ok := row["description"].(string)
					if !ok {
						return nil, errors.New("A captured object comment is not native text.")
					}
					groups[6] = append(groups[6], "COMMENT ON "+object+" IS "+postgresTextLiteral(value)+";")
				} else {
					provider, ok := row["provider"].(string)
					value, vok := row["label"].(string)
					if !ok || !vok || !tableedit.Identifier(provider) {
						return nil, errors.New("A captured security label or provider has no native replay shape.")
					}
					groups[6] = append(groups[6], "SECURITY LABEL FOR "+pgx.Identifier{provider}.Sanitize()+" ON "+object+" IS "+postgresTextLiteral(value)+";")
				}
			}
		}
	}
	for i := len(l.CreateOrder) - 1; i >= 0; i-- {
		groups[4] = append(groups[4], validations[l.CreateOrder[i]]...)
	}
	groups[6] = append(groups[6], family.AfterRestore...)
	groups[7] = []string{"SELECT pg_catalog.set_config('default_tablespace'," + postgresTextLiteral(e.DefaultTablespace) + ",true);", "SELECT pg_catalog.set_config('search_path'," + postgresTextLiteral(e.SearchPath) + ",true);"}
	out := []string{}
	e.CopyStep, e.DropStep = 0, 0
	for i, group := range groups {
		if len(group) == 0 {
			continue
		}
		if i == 1 || i == 2 {
			e.CopyStep = len(out)
		}
		if i == 3 {
			e.DropStep = len(out)
		}
		out = append(out, strings.Join(group, "\n"))
	}
	return out, nil
}

func (s *Session) preparePGAdvancedCopy(ctx context.Context, b tableedit.Baseline, order []string) (tableedit.Prepared, error) {
	return s.preparePGAdvancedCopyWithRepairs(ctx, b, order, nil)
}

func (s *Session) preparePGAdvancedCopyMigration(ctx context.Context, b tableedit.Baseline, order []string, load func(tableedit.Target) (tableedit.Baseline, error)) (tableedit.Prepared, error) {
	if load == nil {
		return tableedit.Prepared{}, tableedit.ErrUnsupported
	}
	return s.preparePGAdvancedCopyWithRepairs(ctx, b, order, load)
}

func (s *Session) preparePGAdvancedCopyWithRepairs(ctx context.Context, b tableedit.Baseline, order []string, load func(tableedit.Target) (tableedit.Baseline, error)) (tableedit.Prepared, error) {
	var p tableedit.Prepared
	if b.Advanced == nil || b.AdvancedEvidence == nil || s.TransactionStatus() != "idle" {
		return p, tableedit.ErrUnsupported
	}
	tx, err := s.conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return p, err
	}
	defer structureRollback(tx)
	current, err := readStructure(ctx, tx, b.Target)
	if err != nil || current.Fingerprint != b.Fingerprint {
		return p, tableedit.ErrStale
	}
	e := &pgAdvancedCopyEnvelope{}
	q := pgCatalogReader(tx)
	if q.QueryRow(ctx, `SELECT current_user::pg_catalog.text,pg_catalog.current_setting('search_path'),pg_catalog.current_setting('default_tablespace')`).Scan(&e.Actor, &e.SearchPath, &e.DefaultTablespace) != nil {
		return p, tableedit.ErrUnsupported
	}
	if _, err = tx.Exec(ctx, "SET LOCAL search_path=pg_catalog"); err != nil {
		return p, err
	}
	current, err = readStructure(ctx, tx, b.Target)
	if err != nil || pgAdvancedCopyMetadata(ctx, tx, &current) != nil || pgAdvancedDataVisibility(ctx, tx, current) != nil {
		return p, errors.New("Complete fixed-context catalog metadata and natural row visibility are required before copy reconstruction.")
	}
	current.Scope = b.Scope
	dataBaseline := current
	observed, planning, repairs, repairEvidence, err := pgAdvancedCopyPrepareRepairs(ctx, tx, current, order, e.SearchPath, load)
	if err != nil {
		return p, err
	}
	e.Evidence = tableedit.CloneAdvancedEvidence(observed.AdvancedEvidence)
	e.Repairs = repairs
	e.RepairEvidence = repairEvidence
	e.Layout, err = pgAdvancedCopyGraph(planning, order)
	if err != nil {
		return p, err
	}
	for _, target := range e.Layout.Temporary {
		var absent, allowed bool
		if q.QueryRow(ctx, `SELECT NOT EXISTS(SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname=$2),pg_catalog.has_schema_privilege($1::pg_catalog.text,'USAGE') AND pg_catalog.has_schema_privilege($1::pg_catalog.text,'CREATE')`, target.Schema, target.Table).Scan(&absent, &allowed) != nil || !absent || !allowed {
			return p, errors.New("Every exact replacement destination must be absent with current schema USAGE and CREATE authority.")
		}
	}
	definitions, err := pgAdvancedCopyReadDefinitions(ctx, tx, planning, e.Layout)
	if err != nil {
		return p, fmt.Errorf("Native copy definitions: %w", err)
	}
	p.SQL, err = pgAdvancedCopyCompose(ctx, tx, planning, e, definitions)
	if err != nil {
		return p, fmt.Errorf("Native copy statements: %w", err)
	}
	dataTypes := pgAdvancedDataTypes(dataBaseline)
	typeProof, err := pgAdvancedBinaryTypes(ctx, tx, dataTypes)
	if err != nil {
		return p, err
	}
	raw, err := json.Marshal(e)
	if err != nil || len(raw) > 8<<20 {
		return p, errors.New("The complete private graph-copy proof exceeds its eight MiB bound.")
	}
	p.Reconstruction = &tableedit.Reconstruction{Method: "postgresql-advanced-copy", ColumnOrder: append([]string(nil), order...), ExpectedDefinition: string(raw), AdvancedDataTypes: dataTypes, AdvancedDataProof: typeProof}
	p.Risks = []string{"This reviewed transaction recreates only the listed bounded relations and native objects. Physical relation and row-type identities change. Every connected table is locked and rechecked; no external foreign key or other dependency is dropped automatically. DROP uses RESTRICT.", "Preview reads catalogs only. Apply copies complete physical-member rows under naturally complete visibility without changing policies, FORCE, row_security or memberships. Generated expressions and constraints may run existing user code; support-function or sequence effects can survive rollback. All retained native values and duplicate counts must match before the first DROP and again before COMMIT.", "The complete proof is bounded to 64 connected tables, 100000 rows per physical member and 32 MiB retained binary values. Partial metadata or row observations do not authorize destructive statements. Unknown COMMIT/rollback acknowledgement closes the connection and requires explicit reconciliation without replay."}
	for _, id := range e.Layout.CreateOrder {
		p.Consequences = append(p.Consequences, tableedit.Consequence{Kind: "reconstruction", Object: pgPhysicalName(e.Layout.Targets[id]), Message: "Recreate this physical relation with reviewed column order and preserve its complete native properties and rows."})
		if planning.AdvancedEvidence.Rows[id+"/class"][0]["relpersistence"] == "u" {
			p.Risks = append(p.Risks, "UNLOGGED persistence is retained: rows are not WAL-logged, may be truncated after an unclean shutdown and are not replicated to standbys.")
		}
	}
	if err = tx.Commit(ctx); err != nil {
		return tableedit.Prepared{}, err
	}
	return p, nil
}

func pgAdvancedCopyVerifyRows(ctx context.Context, q structureReader, proof *pgAdvancedDataProof, targets map[tableedit.Target]tableedit.Target, catalogMapped ...bool) error {
	q = pgCatalogReader(q)
	if proof == nil {
		return tableedit.ErrUnsupported
	}
	current, err := pgAdvancedBinaryTypes(ctx, q, proof.Types)
	if err != nil || current != proof.TypeProof {
		return tableedit.ErrStale
	}
	remaining := pgAdvancedDataMaxBytes
	for _, relation := range proof.Relations {
		target := relation.Target
		if next, ok := targets[target]; ok {
			target = next
		}
		var visible bool
		if q.QueryRow(ctx, `SELECT NOT pg_catalog.row_security_active(c.oid) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname=$2`, target.Schema, target.Table).Scan(&visible) != nil || !visible {
			return errors.New("A copy destination does not have naturally complete row visibility.")
		}
		rows, err := pgAdvancedReadData(ctx, q, target, relation.Columns, &remaining)
		if err != nil || !reflect.DeepEqual(rows, relation.Rows) {
			return errors.New("A native copy changed a retained value, NULL, physical-member row count or duplicate multiplicity.")
		}
	}
	for target, old := range proof.Sequences {
		next, err := pgAdvancedReadSequence(ctx, q, target)
		preserved := err == nil && pgAdvancedSequencePreserved(old, next)
		if len(catalogMapped) == 1 && catalogMapped[0] {
			// Called only after the complete address-qualified catalog mapper
			// proved serial ownership's old-column -> new-column edge. Sequence
			// OID/storage/config/ACL/labels remain exact there; observe counters
			// and the owning backend separately, without any nextval/setval.
			preserved = err == nil && old.Value == next.Value && old.Called == next.Called && old.Session == next.Session
		}
		if !preserved {
			return errors.New("A retained sequence counter or native property changed during reconstruction.")
		}
	}
	return nil
}

func (s *Session) applyPGAdvancedCopy(ctx context.Context, b tableedit.Baseline, p tableedit.Plan) []tableedit.Execution {
	s.advancedCopyCheckpoint = nil
	out := make([]tableedit.Execution, len(p.SQL))
	for i := range out {
		out[i].State = "notStarted"
	}
	fill := func(state, message string) []tableedit.Execution {
		for i := range out {
			out[i] = tableedit.Execution{State: state, Message: message}
		}
		return out
	}
	var e pgAdvancedCopyEnvelope
	if ctx.Err() != nil || s.TransactionStatus() != "idle" || b.Advanced == nil || p.Reconstruction == nil || p.Reconstruction.Method != "postgresql-advanced-copy" || len(p.SQL) < 3 || p.SQL[0] != "SET LOCAL search_path=pg_catalog;" || len(p.Reconstruction.ExpectedDefinition) > 8<<20 || json.Unmarshal([]byte(p.Reconstruction.ExpectedDefinition), &e) != nil || e.Evidence == nil || e.Layout == nil || e.DropStep <= e.CopyStep || e.CopyStep < 1 || e.DropStep >= len(p.SQL)-1 {
		return fill("notStarted", "The retained private graph-copy plan is invalid.")
	}
	tx, err := s.conn.Begin(ctx)
	if err != nil {
		return fill("notStarted", "Cannot begin the graph-copy transaction.")
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if err := tx.Rollback(cleanup); err != nil && !errors.Is(err, pgx.ErrTxClosed) {
			closeConnection(s.conn)
		}
	}()
	rollback := func(message string) []tableedit.Execution {
		cleanup, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if err := tx.Rollback(cleanup); err != nil {
			closeConnection(s.conn)
			return fill("unknown", "Graph-copy rollback acknowledgement was lost. Reconcile explicitly; no replay is authorized.")
		}
		for i := range out {
			if out[i].State == "applied" {
				out[i] = tableedit.Execution{State: "rolledBack", Message: message}
			}
		}
		return out
	}
	if _, err = tx.Exec(ctx, "SET LOCAL lock_timeout='5s'"); err != nil {
		return fill("notStarted", "Cannot establish the bounded graph lock wait.")
	}
	lockTargets := append([]tableedit.Target(nil), e.Evidence.Targets...)
	if len(e.Repairs) > 0 {
		if e.RepairEvidence == nil {
			return fill("notStarted", "The complete selected-repair catalog proof is missing.")
		}
		seen := map[tableedit.Target]bool{}
		for _, target := range lockTargets {
			seen[target] = true
		}
		for _, target := range e.RepairEvidence.Targets {
			if !seen[target] {
				lockTargets = append(lockTargets, target)
				seen[target] = true
			}
		}
		sort.Slice(lockTargets, func(i, j int) bool {
			return lockTargets[i].Schema+"\x00"+lockTargets[i].Table < lockTargets[j].Schema+"\x00"+lockTargets[j].Table
		})
	}
	for _, target := range lockTargets {
		if _, err = tx.Exec(ctx, "LOCK TABLE ONLY "+pgPhysicalName(target)+" IN ACCESS EXCLUSIVE MODE"); err != nil {
			return fill("notStarted", "Cannot lock every reviewed graph member; no copy statement was sent.")
		}
	}
	current, err := readStructure(ctx, tx, b.Target)
	if err != nil || current.Fingerprint != b.Fingerprint {
		return fill("notStarted", "The complete source graph changed; prepare a new preview.")
	}
	var actor, path, defaultTablespace string
	if pgCatalogReader(tx).QueryRow(ctx, `SELECT current_user::pg_catalog.text,pg_catalog.current_setting('search_path'),pg_catalog.current_setting('default_tablespace')`).Scan(&actor, &path, &defaultTablespace) != nil || actor != e.Actor || path != e.SearchPath || defaultTablespace != e.DefaultTablespace {
		return fill("notStarted", "The reviewed role, search path or default tablespace changed.")
	}
	proof, err := pgAdvancedBoundDataCapture(ctx, tx, b, tableedit.Condition{Operation: tableedit.Operation{Kind: "reorder"}, AdvancedDataTypes: p.Reconstruction.AdvancedDataTypes, AdvancedDataProof: p.Reconstruction.AdvancedDataProof})
	if err != nil {
		return fill("notStarted", "Complete native value/counter proof is unavailable; no copy statement was sent.")
	}
	if _, err = tx.Exec(ctx, p.SQL[0]); err != nil {
		return fill("notStarted", "Cannot establish the reviewed catalog interpretation context.")
	}
	current, err = readStructure(ctx, tx, b.Target)
	if err != nil || pgAdvancedCopyMetadata(ctx, tx, &current) != nil {
		return fill("notStarted", "The complete native copy metadata changed; prepare a new preview.")
	}
	combinedBefore, err := pgAdvancedCopyRepairCapture(ctx, tx, current, e.Repairs)
	if err != nil || len(e.Repairs) == 0 && tableedit.Fingerprint(current.AdvancedEvidence) != tableedit.Fingerprint(e.Evidence) || len(e.Repairs) > 0 && pgAdvancedCopyRepairsPreserved(e.RepairEvidence, combinedBefore.AdvancedEvidence, e.Repairs) != nil {
		return fill("notStarted", "The exact selected foreign-key removals or retained native copy metadata changed; prepare a new preview.")
	}
	current.Scope = b.Scope
	layout, err := pgAdvancedCopyGraph(current, p.Reconstruction.ColumnOrder, e.Layout.NameSeed)
	if err != nil || !reflect.DeepEqual(layout, e.Layout) {
		return fill("notStarted", "The reviewed replacement graph changed.")
	}
	definitions, err := pgAdvancedCopyReadDefinitions(ctx, tx, current, layout)
	if err != nil {
		return fill("notStarted", "The native copy definitions cannot be re-proven.")
	}
	expected := e
	expected.Layout = layout
	sql, err := pgAdvancedCopyCompose(ctx, tx, current, &expected, definitions)
	if err != nil || !reflect.DeepEqual(sql, p.SQL) || expected.CopyStep != e.CopyStep || expected.DropStep != e.DropStep || !reflect.DeepEqual(expected.Family, e.Family) {
		return fill("notStarted", "The exact reviewed copy statements changed.")
	}
	out[0].State = "applied"
	temporary := map[tableedit.Target]tableedit.Target{}
	for id, target := range expected.Family.Destinations {
		temporary[layout.Targets[id]] = target
	}
	for i := 1; i < len(p.SQL)-1; i++ {
		if ctx.Err() != nil {
			return rollback("Graph reconstruction was cancelled and table changes rolled back.")
		}
		if i == e.DropStep && pgAdvancedCopyVerifyRows(ctx, tx, proof, temporary) != nil {
			return rollback("The complete temporary copy did not preserve native values/counters; no source DROP was sent.")
		}
		if _, err = tx.Exec(ctx, p.SQL[i]); err != nil {
			message := "The reviewed graph-copy statement failed."
			var code interface{ SQLState() string }
			if errors.As(err, &code) && len(code.SQLState()) == 5 {
				message += " SQLSTATE " + code.SQLState() + "."
			}
			out[i] = tableedit.Execution{State: "rolledBack", Message: message}
			return rollback("Graph-copy table changes rolled back. User-routine or sequence side effects may survive rollback.")
		}
		out[i].State = "applied"
		if s.afterStructureStep != nil {
			s.afterStructureStep(i)
		}
	}
	after, err := readStructure(ctx, tx, b.Target)
	if err != nil || pgAdvancedCopyMetadata(ctx, tx, &after) != nil {
		return rollback("The complete recreated catalog could not be observed; table changes rolled back.")
	}
	combinedAfter, err := pgAdvancedCopyRepairCapture(ctx, tx, after, e.Repairs)
	if err != nil || len(e.Repairs) > 0 && pgAdvancedCopyRepairOwnersPreserved(combinedBefore.AdvancedEvidence, combinedAfter.AdvancedEvidence, current.AdvancedEvidence, after.AdvancedEvidence) != nil {
		return rollback("The complete retained selected-repair owner catalog changed; table changes rolled back.")
	}
	after.Scope = b.Scope
	if err = pgAdvancedCopyRepairPropertiesPreserved(current, after, combinedBefore, combinedAfter, layout.Orders, layout.Replaced); err != nil {
		return rollback("Complete native property verification failed: " + err.Error() + " Table changes rolled back; external side effects may survive rollback.")
	}
	if pgAdvancedCopyVerifyRows(ctx, tx, proof, nil, true) != nil {
		return rollback("Complete native values, row counts or sequence counters changed; table changes rolled back. External side effects may survive rollback.")
	}
	if _, err = tx.Exec(ctx, p.SQL[len(p.SQL)-1]); err != nil {
		return rollback("The original search path could not be restored; table changes rolled back.")
	}
	out[len(out)-1].State = "applied"
	commit := func() error { return tx.Commit(ctx) }
	if s.structureCommitOverride != nil {
		err = s.structureCommitOverride(commit)
	} else {
		err = commit()
	}
	if err != nil {
		closeConnection(s.conn)
		return fill("unknown", "Graph-copy COMMIT acknowledgement was lost. Reconcile explicitly; no replay is authorized.")
	}
	s.advancedCopyCheckpoint = pgAdvancedCopyAcknowledgedCheckpoint(p, s.conn.PgConn().PID(), current, after, combinedBefore, combinedAfter, layout, e.Repairs)
	return out
}
