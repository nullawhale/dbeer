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
)

func pgAdvancedKind(class map[string]any, parents, children bool) []string {
	kinds := []string{}
	if class["relpersistence"] == "u" {
		kinds = append(kinds, "unlogged")
	}
	if class["relkind"] == "p" {
		kinds = append(kinds, "partitionParent")
	}
	if class["relispartition"] == true {
		kinds = append(kinds, "partitionMember")
	}
	if parents && class["relispartition"] != true {
		kinds = append(kinds, "inheritanceChild")
	}
	if children && class["relkind"] != "p" {
		kinds = append(kinds, "inheritanceParent")
	}
	if class["relrowsecurity"] == true || class["relforcerowsecurity"] == true {
		kinds = append(kinds, "rowSecurity")
	}
	if fmt.Sprint(class["reloftype"]) != "0" {
		kinds = append(kinds, "typed")
	}
	return kinds
}
func pgAdvancedRows(ctx context.Context, q structureReader, sql string, args ...any) ([]map[string]any, error) {
	q = pgCatalogReader(q)
	rows, e := pgPhysicalRows(ctx, q, sql, args...)
	if e != nil {
		return nil, e
	}
	out := []map[string]any{}
	for _, raw := range rows {
		var v map[string]any
		if json.Unmarshal(raw, &v) != nil {
			return nil, tableedit.ErrUnsupported
		}
		out = append(out, v)
	}
	return out, nil
}
func pgAdvancedCapture(ctx context.Context, q structureReader, oid uint32, class map[string]any, force ...bool) (*tableedit.AdvancedKindSupport, *tableedit.AdvancedEvidence, error) {
	q = pgCatalogReader(q)
	var parents, children, eventTriggers bool
	if q.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_catalog.pg_inherits WHERE inhrelid=$1),EXISTS(SELECT 1 FROM pg_catalog.pg_inherits WHERE inhparent=$1),EXISTS(SELECT 1 FROM pg_catalog.pg_event_trigger WHERE evtenabled<>'D')`, oid).Scan(&parents, &children, &eventTriggers) != nil {
		return nil, nil, tableedit.ErrUnsupported
	}
	kinds := pgAdvancedKind(class, parents, children)
	if len(kinds) == 0 && (len(force) == 0 || !force[0]) {
		return nil, nil, nil
	}
	var version int
	if q.QueryRow(ctx, `SELECT pg_catalog.current_setting('server_version_num')::pg_catalog.int4`).Scan(&version) != nil || version < 140000 || version >= 190000 {
		return nil, nil, errors.New("Advanced PostgreSQL authoring is proven for versions 14 through 18.")
	}

	var owned bool
	if (len(force) == 0 || !force[0]) && (q.QueryRow(ctx, `SELECT pg_catalog.pg_has_role(c.relowner,'USAGE') FROM pg_catalog.pg_class c WHERE c.oid=$1`, oid).Scan(&owned) != nil || !owned) {
		return nil, nil, errors.New("Advanced authoring requires the owning role; metadata visibility alone is not DDL authority.")
	}
	if eventTriggers {
		return nil, nil, errors.New("Advanced structure preservation requires no enabled database event triggers; DDL event code can change unrelated properties or external state.")
	}
	if (class["relpersistence"] != "p" && class["relpersistence"] != "u") || (class["relkind"] != "r" && class["relkind"] != "p") {
		return nil, nil, errors.New("Advanced authoring supports permanent and unlogged local tables. Temporary tables require their original owning physical session; foreign/view objects have distinct native DDL models.")
	}
	rows, e := q.Query(ctx, `WITH RECURSIVE family(oid) AS (SELECT $1::pg_catalog.oid UNION SELECT CASE WHEN i.inhrelid=f.oid THEN i.inhparent ELSE i.inhrelid END FROM family f JOIN pg_catalog.pg_inherits i ON i.inhrelid=f.oid OR i.inhparent=f.oid) SELECT c.oid,n.nspname,c.relname FROM family f JOIN pg_catalog.pg_class c ON c.oid=f.oid JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace ORDER BY n.nspname COLLATE pg_catalog."C",c.relname COLLATE pg_catalog."C" LIMIT 65`, oid)
	if e != nil {
		return nil, nil, tableedit.ErrUnsupported
	}
	type relation struct {
		oid uint32
		t   tableedit.Target
	}
	family := []relation{}
	for rows.Next() {
		var x relation
		if rows.Scan(&x.oid, &x.t.Schema, &x.t.Table) != nil {
			rows.Close()
			return nil, nil, tableedit.ErrUnsupported
		}
		family = append(family, x)
	}
	e = rows.Err()
	rows.Close()
	if e != nil || len(family) == 0 || len(family) > 64 {
		return nil, nil, errors.New("Advanced hierarchy proof is bounded to 64 complete connected relations.")
	}
	proof := &tableedit.AdvancedEvidence{Facts: map[string]*tableedit.Facts{}, Rows: map[string][]map[string]any{}, Targets: []tableedit.Target{}}
	for _, r := range family {
		proof.Targets = append(proof.Targets, r.t)
		prefix := strconv.FormatUint(uint64(r.oid), 10) + "/"
		var safe bool
		// Guard every family member before any full attribute row can format a missing datum.
		if q.QueryRow(ctx, `SELECT NOT EXISTS(SELECT 1 FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_type t ON t.oid=a.atttypid WHERE (a.attrelid=$1 OR a.attrelid=(SELECT t.typrelid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_type t ON t.oid=c.reloftype WHERE c.oid=$1)) AND a.attnum>0 AND a.atthasmissing AND (t.oid>=16384 OR t.typoutput>=16384 OR t.typmodout>=16384 OR t.typtype='p'))`, r.oid).Scan(&safe) != nil || !safe {
			return nil, nil, errors.New("Hierarchy fast-default metadata requires custom output support; observation stopped before formatting that datum.")
		}
		queries := map[string]string{
			"class":          `SELECT pg_catalog.row_to_json(c)::pg_catalog.text FROM pg_catalog.pg_class c WHERE c.oid=$1`,
			"attributes":     `SELECT CASE WHEN a.atthasmissing AND (t.oid>=16384 OR t.typoutput>=16384 OR t.typmodout>=16384 OR t.typtype='p') THEN NULL::pg_catalog.text ELSE pg_catalog.row_to_json(a)::pg_catalog.text END FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_type t ON t.oid=a.atttypid WHERE a.attrelid=$1 AND a.attnum>0 ORDER BY a.attnum LIMIT 130`,
			"toast":          `SELECT pg_catalog.json_build_object('class',pg_catalog.to_jsonb(tc),'attributes',COALESCE((SELECT pg_catalog.json_agg(CASE WHEN a.atthasmissing THEN NULL ELSE pg_catalog.to_jsonb(a) END ORDER BY a.attnum) FROM pg_catalog.pg_attribute a WHERE a.attrelid=tc.oid AND a.attnum>0),'[]'),'indexes',COALESCE((SELECT pg_catalog.json_agg(pg_catalog.json_build_object('class',pg_catalog.to_jsonb(ic),'index',pg_catalog.to_jsonb(ix)) ORDER BY ic.oid) FROM pg_catalog.pg_index ix JOIN pg_catalog.pg_class ic ON ic.oid=ix.indexrelid WHERE ix.indrelid=tc.oid),'[]'))::pg_catalog.text FROM pg_catalog.pg_class c JOIN pg_catalog.pg_class tc ON tc.oid=c.reltoastrelid WHERE c.oid=$1`,
			"defaults":       `SELECT pg_catalog.row_to_json(d)::pg_catalog.text FROM pg_catalog.pg_attrdef d WHERE d.adrelid=$1 ORDER BY d.adnum LIMIT 130`,
			"constraints":    `SELECT pg_catalog.row_to_json(c)::pg_catalog.text FROM pg_catalog.pg_constraint c WHERE c.conrelid=$1 OR c.confrelid=$1 ORDER BY c.oid LIMIT 2049`,
			"indexes":        `SELECT pg_catalog.json_build_object('index',pg_catalog.row_to_json(i),'class',pg_catalog.row_to_json(c),'parents',COALESCE((SELECT pg_catalog.json_agg(h.inhparent ORDER BY h.inhparent) FROM pg_catalog.pg_inherits h WHERE h.inhrelid=c.oid),'[]'))::pg_catalog.text FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class c ON c.oid=i.indexrelid WHERE i.indrelid=$1 ORDER BY c.oid LIMIT 130`,
			"triggers":       `SELECT pg_catalog.row_to_json(t)::pg_catalog.text FROM pg_catalog.pg_trigger t WHERE t.tgrelid=$1 ORDER BY t.oid LIMIT 2049`,
			"policies":       `SELECT pg_catalog.row_to_json(p)::pg_catalog.text FROM pg_catalog.pg_policy p WHERE p.polrelid=$1 ORDER BY p.oid LIMIT 130`,
			"inherits":       `SELECT pg_catalog.row_to_json(i)::pg_catalog.text FROM pg_catalog.pg_inherits i WHERE i.inhparent=$1 OR i.inhrelid=$1 OR i.inhrelid IN (SELECT indexrelid FROM pg_catalog.pg_index WHERE indrelid=$1) OR i.inhparent IN (SELECT indexrelid FROM pg_catalog.pg_index WHERE indrelid=$1) ORDER BY i.inhparent,i.inhrelid LIMIT 2049`,
			"partition":      `SELECT pg_catalog.row_to_json(p)::pg_catalog.text FROM pg_catalog.pg_partitioned_table p WHERE p.partrelid=$1`,
			"types":          `SELECT pg_catalog.row_to_json(t)::pg_catalog.text FROM pg_catalog.pg_type t WHERE t.oid IN (SELECT c.reltype FROM pg_catalog.pg_class c WHERE c.oid=$1 UNION SELECT c.reloftype FROM pg_catalog.pg_class c WHERE c.oid=$1 UNION SELECT a.atttypid FROM pg_catalog.pg_attribute a WHERE a.attrelid=$1 AND a.attnum>0 UNION SELECT rt.typarray FROM pg_catalog.pg_class c JOIN pg_catalog.pg_type rt ON rt.oid=c.reltype WHERE c.oid=$1) ORDER BY t.oid LIMIT 257`,
			"typeBinding":    `SELECT pg_catalog.json_build_object('schema',n.nspname,'name',t.typname)::pg_catalog.text FROM pg_catalog.pg_class c JOIN pg_catalog.pg_type t ON t.oid=c.reloftype JOIN pg_catalog.pg_namespace n ON n.oid=t.typnamespace WHERE c.oid=$1`,
			"typeAttributes": `SELECT CASE WHEN a.atthasmissing AND (t.oid>=16384 OR t.typoutput>=16384 OR t.typmodout>=16384 OR t.typtype='p') THEN NULL::pg_catalog.text ELSE pg_catalog.row_to_json(a)::pg_catalog.text END FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_type t ON t.oid=a.atttypid WHERE a.attrelid=(SELECT t.typrelid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_type t ON t.oid=c.reloftype WHERE c.oid=$1) AND a.attnum>0 ORDER BY a.attnum LIMIT 130`,
			"statistics":     `SELECT pg_catalog.row_to_json(s)::pg_catalog.text FROM pg_catalog.pg_statistic_ext s WHERE s.stxrelid=$1 ORDER BY s.oid LIMIT 130`,
			"rules":          `SELECT pg_catalog.row_to_json(r)::pg_catalog.text FROM pg_catalog.pg_rewrite r WHERE r.ev_class=$1 ORDER BY r.oid LIMIT 130`,
			"publication":    `SELECT pg_catalog.row_to_json(p)::pg_catalog.text FROM pg_catalog.pg_publication_rel p WHERE p.prrelid=$1 ORDER BY p.oid LIMIT 130`,
		}
		// Capture member-object dependencies, comments and security labels without deparsing SQL expressions.
		members := `WITH objects(classid,objid) AS (SELECT 'pg_catalog.pg_class'::pg_catalog.regclass::pg_catalog.oid,$1::pg_catalog.oid UNION SELECT 'pg_catalog.pg_class'::pg_catalog.regclass::pg_catalog.oid,indexrelid FROM pg_catalog.pg_index WHERE indrelid=$1 UNION SELECT 'pg_catalog.pg_attrdef'::pg_catalog.regclass::pg_catalog.oid,oid FROM pg_catalog.pg_attrdef WHERE adrelid=$1 UNION SELECT 'pg_catalog.pg_constraint'::pg_catalog.regclass::pg_catalog.oid,oid FROM pg_catalog.pg_constraint WHERE conrelid=$1 OR confrelid=$1 UNION SELECT 'pg_catalog.pg_trigger'::pg_catalog.regclass::pg_catalog.oid,oid FROM pg_catalog.pg_trigger WHERE tgrelid=$1 UNION SELECT 'pg_catalog.pg_policy'::pg_catalog.regclass::pg_catalog.oid,oid FROM pg_catalog.pg_policy WHERE polrelid=$1 UNION SELECT 'pg_catalog.pg_type'::pg_catalog.regclass::pg_catalog.oid,reloftype FROM pg_catalog.pg_class WHERE oid=$1 UNION SELECT 'pg_catalog.pg_type'::pg_catalog.regclass::pg_catalog.oid,reltype FROM pg_catalog.pg_class WHERE oid=$1) `
		queries["dependencies"] = members + `SELECT (pg_catalog.to_jsonb(d)||pg_catalog.jsonb_build_object('classid',d.classid::pg_catalog.oid::pg_catalog.text,'objid',d.objid::pg_catalog.oid::pg_catalog.text,'refclassid',d.refclassid::pg_catalog.oid::pg_catalog.text,'refobjid',d.refobjid::pg_catalog.oid::pg_catalog.text))::pg_catalog.text FROM pg_catalog.pg_depend d WHERE EXISTS(SELECT 1 FROM objects o WHERE (d.classid=o.classid AND d.objid=o.objid) OR (d.refclassid=o.classid AND d.refobjid=o.objid)) ORDER BY d.classid,d.objid,d.objsubid,d.refclassid,d.refobjid,d.refobjsubid LIMIT 2049`
		queries["comments"] = members + `SELECT pg_catalog.row_to_json(d)::pg_catalog.text FROM pg_catalog.pg_description d JOIN objects o ON o.classid=d.classoid AND o.objid=d.objoid ORDER BY d.classoid,d.objoid,d.objsubid LIMIT 2049`
		queries["labels"] = members + `SELECT pg_catalog.row_to_json(d)::pg_catalog.text FROM pg_catalog.pg_seclabel d JOIN objects o ON o.classid=d.classoid AND o.objid=d.objoid ORDER BY d.classoid,d.objoid,d.objsubid,d.provider LIMIT 2049`
		for category, sql := range queries {
			v, e := pgAdvancedRows(ctx, q, sql, r.oid)
			if e != nil {
				return nil, nil, e
			}
			if category == "attributes" && len(v) > 128 || category == "typeAttributes" && len(v) > 128 || category == "types" && len(v) > 256 {
				return nil, nil, tableedit.ErrUnsupported
			}
			for _, row := range v {
				if row == nil {
					return nil, nil, tableedit.ErrUnsupported
				}
				if category == "class" {
					if (row["relpersistence"] != "p" && row["relpersistence"] != "u") || (row["relkind"] != "r" && row["relkind"] != "p") {
						return nil, nil, errors.New("Every connected hierarchy member must be a permanent or unlogged local table for complete native preservation proof.")
					}
					pgAdvancedStripStats(row)
				}
				if category == "toast" {
					cl, ok := row["class"].(map[string]any)
					if !ok {
						return nil, nil, tableedit.ErrUnsupported
					}
					pgAdvancedStripStats(cl)
					for _, entry := range row["indexes"].([]any) {
						index := entry.(map[string]any)
						pgAdvancedStripStats(index["class"].(map[string]any))
					}
					for _, entry := range row["attributes"].([]any) {
						if entry == nil {
							return nil, nil, errors.New("Internal TOAST missing-value metadata cannot be formatted during observation.")
						}
					}
				}
				if category == "indexes" {
					pgAdvancedStripStats(row["class"].(map[string]any))
				}
			}
			proof.Rows[prefix+category] = v
		}
		facts, err := readStructureFacts(ctx, q, r.t, r.oid, true)
		if err != nil {
			return nil, nil, err
		}
		if classes := proof.Rows[prefix+"class"]; len(classes) == 1 {
			facts.Table.Kind = sc.Known(fmt.Sprint(classes[0]["relkind"]))
		}
		proof.Facts[strings.TrimSuffix(prefix, "/")] = facts
		proof.Rows[prefix+"sequences"], err = pgAdvancedGenerationCatalog(ctx, q, r.oid)
		if err != nil {
			return nil, nil, err
		}
	}
	for key, sql := range map[string]string{"global/roles": `SELECT pg_catalog.row_to_json(r)::pg_catalog.text FROM pg_catalog.pg_roles r ORDER BY r.oid LIMIT 2049`, "global/memberships": `SELECT pg_catalog.row_to_json(m)::pg_catalog.text FROM pg_catalog.pg_auth_members m ORDER BY m.roleid,m.member LIMIT 2049`} {
		rows, err := pgAdvancedRows(ctx, q, sql)
		if err != nil {
			return nil, nil, err
		}
		proof.Rows[key] = rows
	}
	enriched := tableedit.Baseline{AdvancedEvidence: proof}
	if err := pgAdvancedNativeExtras(ctx, q, &enriched); err != nil {
		return nil, nil, err
	}
	proof = enriched.AdvancedEvidence
	raw, _ := json.Marshal(proof)
	if len(raw) > 3<<20 {
		return nil, nil, tableedit.ErrUnsupported
	}
	reasons := map[string]string{"hierarchy": "Use the separately reviewed physical workflow for declarative partition actions; traditional inheritance/type/policy edits require an explicit migration and are not authored here."}
	if class["relispartition"] == true {
		reasons["addColumn"] = "PostgreSQL does not permit adding a column directly to a declarative partition; alter its parent hierarchy."
		reasons["renameColumn"] = "PostgreSQL requires inherited partition column names to match their parent; rename through the parent hierarchy."
		reasons["dropColumn"] = "PostgreSQL does not permit dropping an inherited partition column directly."
		reasons["type"] = "PostgreSQL requires an attached partition's column types to match its declaring parent; review the parent hierarchy."
	}
	if fmt.Sprint(class["reloftype"]) != "0" {
		for _, kind := range []string{"addColumn", "dropColumn", "renameColumn", "type"} {
			reasons[kind] = "PostgreSQL typed-table column names and types belong to the composite type. ALTER TYPE would affect other bound tables and is never generated implicitly."
		}
	}
	if len(kinds) == 0 {
		return nil, proof, nil
	}
	scope := "only"
	if children {
		scope = "operation"
	}
	support := tableedit.NewAdvancedSupport(kinds, scope, len(family), false, reasons)
	if err := pgAdvancedPublicFacts(support, proof); err != nil {
		return nil, nil, err
	}
	return support, proof, nil
}
func pgAdvancedStripStats(row map[string]any) {
	for _, k := range []string{"relpages", "reltuples", "relallvisible", "relallfrozen", "relfrozenxid", "relminmxid", "relhasindex"} {
		delete(row, k)
	}
}
func pgAdvancedPrepare(b tableedit.Baseline, d tableedit.Draft) error {
	if b.Advanced == nil {
		return nil
	}
	if e := tableedit.CheckAdvancedDraft(b, d); e != nil {
		return e
	}
	for _, c := range d.Changes {
		if c.Identity != nil && b.Facts.ServerVersion >= 170000 {
			for _, kind := range b.Advanced.Kinds {
				if kind == "partitionMember" {
					return errors.New("PostgreSQL partitions inherit identity ownership and mode from their partitioned root (SQLSTATE 42P16). Review the root identity action; a separate partition identity is not generated.")
				}
			}
		}
		if c.Conversion() {
			old, ok := tableedit.FindColumn(b, c.Name)
			if !ok || c.Type == nil || !tableedit.CanWiden(old, *c.Type) || c.UsingExpression != nil || c.Unsigned != nil || c.Charset != nil || c.Collation != nil {
				return errors.New("Advanced type authoring currently supports lossless integer-to-bigint and varchar widening only; value-changing conversions and custom support effects need a separately implemented native proof.")
			}
		}
		attrs := b.Attributes[c.Name]
		if attrs == nil {
			return tableedit.ErrInvalid
		}
		if (c.Drop || c.RenameTo != nil || c.Type != nil) && attrs["attinhcount"] != float64(0) {
			return errors.New("This inherited column cannot be renamed or removed locally; alter its declaring parent hierarchy.")
		}

	}
	if err := pgAdvancedHierarchyDraft(b, d); err != nil {
		return err
	}
	parent := b.Facts.Table.Kind.Value != nil && *b.Facts.Table.Kind.Value == "p"
	for _, change := range d.Changes {
		if change.Type != nil || change.Drop {
			num := b.Attributes[change.Name]["attnum"]
			for _, row := range b.AdvancedEvidence.Rows[b.Identity+"/dependencies"] {
				if fmt.Sprint(row["classid"]) == "3256" && fmt.Sprint(row["refobjid"]) == b.Identity && row["refobjsubid"] == num {
					return errors.New("PostgreSQL policy dependencies prevent this column type/removal change. Policy removal or rewriting is never implicit.")
				}
			}
		}
	}
	if parent {
		unique := [][]string{}
		for _, x := range d.Indexes {
			if x.Unique && x.Action != "drop" {
				names := append([]string(nil), x.Columns...)
				if x.Definition != nil {
					names = []string{}
					for _, term := range x.Definition.Terms {
						if term.Column != nil {
							names = append(names, *term.Column)
						}
					}
				}
				unique = append(unique, names)
			}
		}
		for _, k := range d.Keys {
			if k.Action != "drop" && (k.Kind == "primary" || k.Kind == "unique") {
				unique = append(unique, k.Columns)
			}
		}
		affected := pgAdvancedDescendants(b)
		for _, names := range unique {
			for key, parts := range b.AdvancedEvidence.Rows {
				if !strings.HasSuffix(key, "/partition") || !affected[strings.TrimSuffix(key, "/partition")] {
					continue
				}
				attrs := b.AdvancedEvidence.Rows[strings.TrimSuffix(key, "partition")+"attributes"]
				for _, part := range parts {
					for _, number := range pgAdvancedAttnums(part["partattrs"]) {
						if number == "0" {
							return errors.New("PostgreSQL partitioned UNIQUE/PRIMARY keys cannot cover an expression partition key; use a nonunique index or separately reviewed schema change.")
						}
						name := ""
						for _, attr := range attrs {
							if fmt.Sprint(attr["attnum"]) == number {
								name, _ = attr["attname"].(string)
							}
						}
						found := false
						for _, candidate := range names {
							found = found || candidate == name
						}
						if !found || name == "" {
							return errors.New("A partitioned UNIQUE/PRIMARY key must include every direct key column of every affected partitioned hierarchy member.")
						}
					}
				}
			}
		}
	}
	return nil
}
func pgAdvancedLocalPreservationError(before, after tableedit.Baseline, c tableedit.Condition, family ...*tableedit.AdvancedEvidence) error {
	if before.Advanced == nil {
		if after.Advanced == nil {
			return nil
		}
		return errors.New("Advanced kind changed unexpectedly.")
	}
	if after.Advanced == nil || before.AdvancedEvidence == nil || after.AdvancedEvidence == nil {
		return errors.New("The advanced catalog transition is invalid.")
	}
	a, b := tableedit.CloneAdvancedEvidence(before.AdvancedEvidence), tableedit.CloneAdvancedEvidence(after.AdvancedEvidence)
	if len(a.Targets) != len(b.Targets) {
		return errors.New("The advanced catalog transition is invalid.")
	}
	op := c.Operation
	if err := pgAdvancedGenerationNormalize(before, after, c, a, b); err != nil {
		return err
	}
	prefix := before.Identity + "/"
	// All non-target hierarchy members retain their complete catalog records. New
	// partition-index clones are checked separately against their exact origin.
	if err := pgAdvancedIndexHierarchyError(before, after, c, a, b); err != nil {
		return err
	}
	targetRowsA, targetRowsB := a.Rows[prefix+"attributes"], b.Rows[prefix+"attributes"]
	stripObject := func(e *tableedit.AdvancedEvidence, category string, match func(map[string]any) bool) {
		out := []map[string]any{}
		for _, r := range e.Rows[prefix+category] {
			if !match(r) {
				out = append(out, r)
			}
		}
		e.Rows[prefix+category] = out
	}
	removed := map[string]bool{}
	columnNumber := func(name string) any {
		for _, r := range targetRowsA {
			if r["attname"] == name {
				return r["attnum"]
			}
		}
		return nil
	}
	stripDefaults := func(num any) {
		for _, e := range []*tableedit.AdvancedEvidence{a, b} {
			stripObject(e, "defaults", func(r map[string]any) bool {
				if r["adnum"] == num {
					removed[fmt.Sprint(r["oid"])] = true
					return true
				}
				return false
			})
		}
	}
	switch op.Kind {
	case "renameTable":
		if op.Name == nil {
			return errors.New("The advanced catalog transition is invalid.")
		}
		a.Targets = append([]tableedit.Target(nil), b.Targets...)
		for _, r := range a.Rows[prefix+"class"] {
			r["relname"] = *op.Name
		}
		for _, r := range a.Rows[prefix+"types"] {
			if fmt.Sprint(r["typrelid"]) == before.Identity {
				r["typname"] = *op.Name
			}
			if r["typelem"] != float64(0) && r["typname"] == "_"+before.Target.Table {
				r["typname"] = "_" + *op.Name
			}
		}
	case "renameColumn":
		if op.Change == nil || op.Change.RenameTo == nil {
			return errors.New("The advanced catalog transition is invalid.")
		}
		for _, r := range targetRowsA {
			if r["attname"] == op.Change.Name {
				r["attname"] = *op.Change.RenameTo
			}
		}
	case "addColumn":
		if op.Column == nil {
			return errors.New("The advanced catalog transition is invalid.")
		}
		name := op.Column.Name
		var number any
		for _, r := range targetRowsB {
			if r["attname"] == name {
				number = r["attnum"]
			}
		}
		if number == nil {
			return errors.New("The advanced catalog transition is invalid.")
		}
		stripObject(b, "attributes", func(r map[string]any) bool { return r["attnum"] == number })
		for _, r := range a.Rows[prefix+"class"] {
			r["relnatts"] = r["relnatts"].(float64) + 1
		}
		// New built-in type dependencies are validated by the typed transition.
		if !pgAdvancedNormalizeTypes(a, b, prefix, before, after, op) {
			return errors.New("An unaffected native type property changed unexpectedly.")
		}
	case "dropColumn":
		if op.Change == nil {
			return errors.New("The advanced catalog transition is invalid.")
		}
		num := columnNumber(op.Change.Name)
		fullA, fullB := before.AdvancedEvidence, after.AdvancedEvidence
		if len(family) == 2 {
			fullA, fullB = family[0], family[1]
		}
		if err := pgAdvancedNotNullDelta(a, b, fullA, fullB, prefix, []string{op.Change.Name}, false, true); err != nil {
			return err
		}
		stripDefaults(num)
		for _, e := range []*tableedit.AdvancedEvidence{a, b} {
			stripObject(e, "attributes", func(r map[string]any) bool { return r["attnum"] == num })
		}
		if !pgAdvancedNormalizeTypes(a, b, prefix, before, after, op) {
			return errors.New("An unaffected native type property changed unexpectedly.")
		}
	case "changeColumn":
		if op.Change == nil {
			return errors.New("The advanced catalog transition is invalid.")
		}
		num := columnNumber(op.Change.Name)
		if op.Change.Default != nil {
			stripDefaults(num)
			for _, rows := range [][]map[string]any{targetRowsA, targetRowsB} {
				for _, r := range rows {
					if r["attnum"] == num {
						delete(r, "atthasdef")
					}
				}
			}
		}
		if op.Change.Nullable != nil {
			for _, rows := range [][]map[string]any{targetRowsA, targetRowsB} {
				for _, r := range rows {
					if r["attnum"] == num {
						delete(r, "attnotnull")
					}
				}
			}
			fullA, fullB := before.AdvancedEvidence, after.AdvancedEvidence
			if len(family) == 2 {
				fullA, fullB = family[0], family[1]
			}
			if err := pgAdvancedNotNullDelta(a, b, fullA, fullB, prefix, []string{op.Change.Name}, !*op.Change.Nullable, *op.Change.Nullable); err != nil {
				return err
			}
		}
		if op.Change.Type != nil {
			fullA, fullB := before.AdvancedEvidence, after.AdvancedEvidence
			if len(family) == 2 {
				fullA, fullB = family[0], family[1]
			}
			if err := pgAdvancedNotNullTypeDelta(a, b, fullA, fullB, prefix, op.Change.Name); err != nil {
				return err
			}
			if !pgAdvancedToastPreserved(a, b, prefix) {
				return errors.New("Internal TOAST properties changed beyond the reviewed physical-identity replacement.")
			}

			for _, row := range a.Rows[prefix+"indexes"] {
				cl := row["class"].(map[string]any)
				for _, next := range b.Rows[prefix+"indexes"] {
					nc := next["class"].(map[string]any)
					if cl["oid"] == nc["oid"] {
						cl["relfilenode"] = nc["relfilenode"]
					}
				}
			}
			for _, row := range a.Rows[prefix+"class"] {
				for _, next := range b.Rows[prefix+"class"] {
					row["relfilenode"] = next["relfilenode"]
				}
			}
			for _, rows := range [][]map[string]any{targetRowsA, targetRowsB} {
				for _, r := range rows {
					// Native heap rewrites refresh every attribute's tuple-layout identity.
					// Raw fingerprints retain it; only validated pg_attver is nonsemantic.
					r["attoptions"] = tableedit.SemanticPostgresAttributeOptions(r["attoptions"])
					if r["attnum"] == num {
						for _, key := range []string{"atttypid", "attlen", "atttypmod", "attbyval", "attalign", "attstorage", "attcompression", "attcollation"} {
							delete(r, key)
						}
					}
				}
			}
			if !pgAdvancedNormalizeTypes(a, b, prefix, before, after, op) {
				return errors.New("An unaffected native type property changed unexpectedly.")
			}
		}
	case "addIndex", "dropIndex", "addKey", "dropKey", "backfill":
		// Exact target semantics are checked by VerifyTransition, while hierarchy
		// cloning and every retained raw member property are checked above/below.
	default:
		return errors.New("The advanced catalog transition is invalid.")
	}
	affectedNumber := any(nil)
	if op.Kind == "addColumn" && op.Column != nil {
		for _, row := range targetRowsB {
			if row["attname"] == op.Column.Name {
				affectedNumber = row["attnum"]
			}
		}
	}
	if op.Kind == "dropColumn" && op.Change != nil || op.Kind == "changeColumn" && op.Change != nil && op.Change.Type != nil {
		affectedNumber = columnNumber(op.Change.Name)
	}
	if affectedNumber != nil {
		for _, e := range []*tableedit.AdvancedEvidence{a, b} {
			stripObject(e, "dependencies", func(row map[string]any) bool {
				return fmt.Sprint(row["classid"]) == "1259" && fmt.Sprint(row["objid"]) == before.Identity && row["objsubid"] == affectedNumber
			})
		}
	}
	if op.Kind == "dropColumn" && op.Change != nil {
		num := columnNumber(op.Change.Name)
		for _, e := range []*tableedit.AdvancedEvidence{a, b} {
			for _, category := range []string{"comments", "labels"} {
				stripObject(e, category, func(row map[string]any) bool {
					return fmt.Sprint(row["classoid"]) == "1259" && fmt.Sprint(row["objoid"]) == before.Identity && row["objsubid"] == num
				})
			}
		}
	}
	// A changed attrdef has a new OID. Strip only that object's dependency edges;
	// dependency edges of the target attribute remain compared for all other edits.
	for _, e := range []*tableedit.AdvancedEvidence{a, b} {
		stripObject(e, "dependencies", func(r map[string]any) bool {
			return fmt.Sprint(r["classid"]) == "2604" && removed[fmt.Sprint(r["objid"])]
		})
	}
	sortEvidence := func(e *tableedit.AdvancedEvidence) {
		for _, rows := range e.Rows {
			sort.Slice(rows, func(i, j int) bool { return tableedit.Fingerprint(rows[i]) < tableedit.Fingerprint(rows[j]) })
		}
	}
	sortEvidence(a)
	sortEvidence(b)
	if !reflect.DeepEqual(a.Targets, b.Targets) {
		return errors.New("The connected hierarchy targets changed unexpectedly.")
	}
	for key, rows := range a.Rows {
		if !reflect.DeepEqual(rows, b.Rows[key]) {
			parts := strings.Split(key, "/")
			if strings.HasSuffix(key, "/class") && len(rows) == 1 && len(b.Rows[key]) == 1 {
				for property, value := range rows[0] {
					if !reflect.DeepEqual(value, b.Rows[key][0][property]) {
						return fmt.Errorf("Unexpected advanced class property %s changed.", property)
					}
				}
			}
			return fmt.Errorf("Unexpected advanced %s properties changed.", parts[len(parts)-1])
		}
	}
	if len(a.Rows) != len(b.Rows) {
		return errors.New("The advanced property categories changed unexpectedly.")
	}
	return nil
}

func pgAdvancedPreserved(before, after tableedit.Baseline, c tableedit.Condition) bool {
	return pgAdvancedPreservationError(before, after, c) == nil
}

func pgAdvancedIndexHierarchyError(before, after tableedit.Baseline, c tableedit.Condition, a, b *tableedit.AdvancedEvidence) error {
	op := c.Operation
	if op.Kind != "addIndex" && op.Kind != "dropIndex" && op.Kind != "addKey" && op.Kind != "dropKey" {
		return nil
	}
	name := ""
	constraint := ""
	adding := op.Kind == "addIndex" || op.Kind == "addKey"
	if op.Index != nil {
		name = op.Index.Name
	}
	if op.Key != nil {
		name = op.Key.Name
		constraint = name
	}
	if name == "" {
		return errors.New("Native index hierarchy proof stage 1 did not match.")
	}
	// For a new partitioned index, PostgreSQL may either create each child index
	// or attach an exactly matching existing one. Every link is proven by OID.
	prefix := before.Identity + "/"
	selected := b
	if !adding {
		selected = a
	}
	var root map[string]any
	for _, r := range selected.Rows[prefix+"indexes"] {
		if r["class"].(map[string]any)["relname"] == name {
			root = r
		}
	}
	if root == nil {
		return errors.New("Native index hierarchy proof stage 2 did not match.")
	}
	type member struct {
		prefix string
		row    map[string]any
		parent string
	}
	affected := map[string]member{}
	rootID := fmt.Sprint(root["index"].(map[string]any)["indexrelid"])
	affected[rootID] = member{prefix: prefix, row: root}
	for changed := true; changed; {
		changed = false
		for key, rows := range selected.Rows {
			if !strings.HasSuffix(key, "indexes") {
				continue
			}
			p := strings.TrimSuffix(key, "indexes")
			for _, r := range rows {
				idx := r["index"].(map[string]any)
				id := fmt.Sprint(idx["indexrelid"])
				if _, ok := affected[id]; ok {
					continue
				}
				for _, link := range selected.Rows[p+"inherits"] {
					parent := fmt.Sprint(link["inhparent"])
					if fmt.Sprint(link["inhrelid"]) == id {
						if _, ok := affected[parent]; ok {
							affected[id] = member{prefix: p, row: r, parent: parent}
							changed = true
						}
					}
				}
			}
		}
	}
	if adding && before.Facts.Table.Kind.Value != nil && *before.Facts.Table.Kind.Value == "p" {
		// Only descendants of the selected parent are affected; ancestor/sibling
		// relations in the connected family remain byte-for-byte unchanged.
		descendants := map[string]bool{before.Identity: true}
		for changed := true; changed; {
			changed = false
			for key, rows := range b.Rows {
				if !strings.HasSuffix(key, "inherits") {
					continue
				}
				for _, link := range rows {
					p, ch := fmt.Sprint(link["inhparent"]), fmt.Sprint(link["inhrelid"])
					if descendants[p] && !descendants[ch] {
						for _, r := range b.Rows[ch+"/class"] {
							if r["relkind"] == "r" || r["relkind"] == "p" {
								descendants[ch] = true
								changed = true
							}
						}
					}
				}
			}
		}
		perRelation := map[string]int{}
		for id, m := range affected {
			relationID := strings.TrimSuffix(m.prefix, "/")
			perRelation[relationID]++
			if id == rootID {
				continue
			}
			parent, ok := affected[m.parent]
			if !ok {
				return errors.New("The native clone parent index is absent.")
			}
			if err := pgAdvancedCloneIndexError(parent.row, m.row, b.Rows[parent.prefix+"attributes"], b.Rows[m.prefix+"attributes"], b.Rows[parent.prefix+"class"][0], b.Rows[m.prefix+"class"][0]); err != nil {
				return err
			}
			tableLinked := false
			for _, link := range b.Rows[m.prefix+"inherits"] {
				if fmt.Sprint(link["inhparent"]) == strings.TrimSuffix(parent.prefix, "/") && fmt.Sprint(link["inhrelid"]) == relationID {
					tableLinked = true
				}
			}
			if !tableLinked {
				return errors.New("Native index hierarchy proof stage 4 did not match.")
			}
		}
		for relationID := range descendants {
			if perRelation[relationID] != 1 {
				return errors.New("Native index hierarchy proof stage 5 did not match.")
			}
		}
	}
	if !adding {
		for key, rows := range b.Rows {
			if strings.HasSuffix(key, "indexes") {
				for _, row := range rows {
					if _, found := affected[pgPhysicalOID(row["class"].(map[string]any)["oid"])]; found {
						return errors.New("A reviewed descendant index remained after parent removal.")
					}
				}
			}
		}
	}
	constraintIDs := map[string]bool{}
	indexIDs := map[string]bool{}
	for id, m := range affected {
		indexIDs[id] = true
		if constraint != "" {
			var own map[string]any
			for _, row := range selected.Rows[m.prefix+"constraints"] {
				if fmt.Sprint(row["conindid"]) == id && fmt.Sprint(row["conrelid"]) == strings.TrimSuffix(m.prefix, "/") {
					if own != nil {
						return errors.New("Native index hierarchy proof stage 6 did not match.")
					}
					own = row
				}
			}
			if own == nil || (own["contype"] != "p" && own["contype"] != "u") || own["convalidated"] != true {
				return errors.New("Native index hierarchy proof stage 7 did not match.")
			}
			constraintIDs[fmt.Sprint(own["oid"])] = true
			if m.parent != "" {
				parent := affected[m.parent]
				var parentConstraint map[string]any
				for _, row := range selected.Rows[parent.prefix+"constraints"] {
					if fmt.Sprint(row["conindid"]) == m.parent {
						parentConstraint = row
					}
				}
				if parentConstraint == nil || fmt.Sprint(own["conparentid"]) != fmt.Sprint(parentConstraint["oid"]) || own["contype"] != parentConstraint["contype"] || own["condeferrable"] != parentConstraint["condeferrable"] || own["condeferred"] != parentConstraint["condeferred"] || own["conislocal"] != false {
					return errors.New("Native index hierarchy proof stage 8 did not match.")
				}
				parentRelation := pgAdvancedRelation(parent.prefix, b)
				childRelation := pgAdvancedRelation(m.prefix, b)
				mapping, ok := pgPhysicalAttributeMap(parentRelation, childRelation)
				if !ok || !pgPhysicalConstraintClone(parentConstraint, own, parentRelation, childRelation, mapping, map[string]any{m.parent: own["conindid"]}, false) {
					return errors.New("A native descendant constraint differs from its exact parent origin and mapped semantics.")
				}

			}
		}
		if constraint != "" {
			for _, oldConstraint := range a.Rows[m.prefix+"constraints"] {
				if constraintIDs[fmt.Sprint(oldConstraint["oid"])] {
					for _, nextConstraint := range b.Rows[m.prefix+"constraints"] {
						if oldConstraint["oid"] == nextConstraint["oid"] {
							oldCopy := pgPhysicalCopy(oldConstraint)
							for _, key := range []string{"conparentid", "coninhcount", "conislocal", "connoinherit"} {
								oldCopy[key] = nextConstraint[key]
							}
							if !reflect.DeepEqual(oldCopy, nextConstraint) {
								return errors.New("An attached preexisting descendant constraint lost native properties.")
							}
						}
					}
				}
			}
		}
		var old map[string]any
		for _, row := range a.Rows[m.prefix+"indexes"] {
			if fmt.Sprint(row["index"].(map[string]any)["indexrelid"]) == id {
				old = row
			}
		}
		if adding && old != nil {
			// Attachment must preserve every preexisting native index property except
			// the exact server-owned partition marker/link.
			oldClass := old["class"].(map[string]any)
			nextClass := m.row["class"].(map[string]any)
			oldClass["relispartition"] = nextClass["relispartition"]
			oldClass["relpartbound"] = nextClass["relpartbound"]
			old["parents"] = m.row["parents"]
			if !reflect.DeepEqual(old, m.row) {
				return errors.New("Native index hierarchy proof stage 9 did not match.")
			}
		} else if adding {
			if err := pgAdvancedCreatedIndexAttributes(b.Rows[m.prefix+"indexAttributes"], m.row, b.Rows[m.prefix+"attributes"]); err != nil {
				return fmt.Errorf("A newly created native index has incomplete or unreviewed attributes: %w", err)
			}
			idx := m.row["index"].(map[string]any)
			cl := m.row["class"].(map[string]any)
			if idx["indisvalid"] != true || idx["indisready"] != true || idx["indislive"] != true || idx["indisclustered"] != false || idx["indisreplident"] != false || cl["relacl"] != nil {
				return errors.New("Native index hierarchy proof stage 10 did not match.")
			}
			// New objects cannot silently inherit unreviewed comments/security labels.
			for _, category := range []string{"comments", "labels"} {
				for _, row := range b.Rows[m.prefix+category] {
					if fmt.Sprint(row["classoid"]) == "1259" && fmt.Sprint(row["objoid"]) == id {
						return errors.New("Native index hierarchy proof stage 11 did not match.")
					}
				}
			}
		}
	}
	if adding && op.Key != nil && op.Key.Kind == "primary" {
		seen := map[string]bool{}
		for _, member := range affected {
			if !seen[member.prefix] {
				seen[member.prefix] = true
				if err := pgAdvancedNotNullDelta(a, b, before.AdvancedEvidence, after.AdvancedEvidence, member.prefix, op.Key.Columns, true, false); err != nil {
					return err
				}
			}
		}
	}
	for _, e := range []*tableedit.AdvancedEvidence{a, b} {
		for key, rows := range e.Rows {
			out := []map[string]any{}
			for _, row := range rows {
				remove := false
				switch {
				case strings.HasSuffix(key, "indexes"):
					remove = indexIDs[fmt.Sprint(row["index"].(map[string]any)["indexrelid"])]
				case strings.HasSuffix(key, "constraints"):
					remove = constraintIDs[fmt.Sprint(row["oid"])]
				case strings.HasSuffix(key, "/indexAttributes"):
					id := fmt.Sprint(row["attrelid"])
					if indexIDs[id] {
						m := affected[id]
						existed := false
						for _, previous := range before.AdvancedEvidence.Rows[m.prefix+"indexes"] {
							existed = existed || fmt.Sprint(previous["class"].(map[string]any)["oid"]) == id
						}
						// Existing attached indexes retain every exact attribute. Only
						// newly proved/default attributes or explicitly removed objects
						// belong to the reviewed native index effect.
						remove = !adding || !existed
					}

				case strings.HasSuffix(key, "inherits"):
					remove = indexIDs[fmt.Sprint(row["inhrelid"])] || indexIDs[fmt.Sprint(row["inhparent"])]
				case strings.HasSuffix(key, "dependencies"):
					remove = fmt.Sprint(row["classid"]) == "1259" && indexIDs[fmt.Sprint(row["objid"])] || fmt.Sprint(row["refclassid"]) == "1259" && indexIDs[fmt.Sprint(row["refobjid"])] || fmt.Sprint(row["classid"]) == "2606" && constraintIDs[fmt.Sprint(row["objid"])] || fmt.Sprint(row["refclassid"]) == "2606" && constraintIDs[fmt.Sprint(row["refobjid"])]
				}
				if !remove {
					out = append(out, row)
				}
			}
			e.Rows[key] = out
		}
		if adding && op.Key != nil && op.Key.Kind == "primary" {
			for _, m := range affected {
				for _, row := range e.Rows[m.prefix+"attributes"] {
					for _, name := range op.Key.Columns {
						if row["attname"] == name {
							delete(row, "attnotnull")
						}
					}
				}
			}
		}
	}
	return nil
}
func pgAdvancedIndexHierarchy(before, after tableedit.Baseline, c tableedit.Condition, a, b *tableedit.AdvancedEvidence) bool {
	return pgAdvancedIndexHierarchyError(before, after, c, a, b) == nil
}

func pgAdvancedConstraintColumns(c map[string]any, attrs []map[string]any, names []string) bool {
	nums, ok := c["conkey"].([]any)
	if !ok || len(nums) != 1 {
		return false
	}
	for _, a := range attrs {
		if a["attnum"] == nums[0] {
			for _, name := range names {
				if a["attname"] == name {
					return true
				}
			}
		}
	}
	return false
}
func pgAdvancedCloneIndexError(parent, child map[string]any, parentAttrs, childAttrs []map[string]any, parentClass, childClass map[string]any) error {
	relation := func(class map[string]any, attrs []map[string]any) pgPhysicalRelation {
		id, _ := strconv.ParseUint(fmt.Sprint(class["oid"]), 10, 32)
		return pgPhysicalRelation{OID: uint32(id), Class: class, Columns: attrs}
	}
	p, c := relation(parentClass, parentAttrs), relation(childClass, childAttrs)
	mapping, ok := pgPhysicalAttributeMap(p, c)
	if !ok {
		return errors.New("The clone column-name/type mapping is incomplete.")
	}
	pr, _ := json.Marshal(parent)
	cr, _ := json.Marshal(child)
	pc, pi, _, ok := pgPhysicalIndexParts(pr)
	if !ok {
		return errors.New("The parent native index record is incomplete.")
	}
	cc, ci, origins, ok := pgPhysicalIndexParts(cr)
	if !ok || len(origins) != 1 || pgPhysicalOID(origins[0]) != pgPhysicalOID(pc["oid"]) || cc["relispartition"] != true {
		return errors.New("The clone's native parent origin is unproven.")
	}
	if cc["relkind"] == "i" && pgPhysicalIndexClone(pr, cr, p, c, mapping) {
		return nil
	}
	if cc["relkind"] != "i" && cc["relkind"] != "I" {
		return errors.New("The clone has an unexpected relation kind.")
	}
	expectedClass := pgPhysicalCopy(pc)
	for _, key := range []string{"oid", "relname", "relfilenode"} {
		expectedClass[key] = cc[key]
	}
	expectedClass["relnamespace"], expectedClass["relowner"], expectedClass["relkind"], expectedClass["relispartition"] = cc["relnamespace"], cc["relowner"], cc["relkind"], true
	expectedClass["relhassubclass"] = false
	if cc["relkind"] == "I" {
		if fmt.Sprint(cc["relfilenode"]) != "0" {
			return errors.New("An intermediate partitioned index unexpectedly has physical storage.")
		}
		expectedClass["relhassubclass"] = childClass["relhassubclass"]
	}
	expectedIndex := pgPhysicalCopy(pi)
	expectedIndex["indexrelid"] = cc["oid"]
	expectedIndex["indrelid"] = childClass["oid"]
	mapped, ok := pgPhysicalMapAttnums(pi["indkey"], mapping)
	if !ok {
		return errors.New("Native index key mapping is incomplete.")
	}
	expectedIndex["indkey"] = mapped
	for _, key := range []string{"indexprs", "indpred"} {
		value, ok := pgPhysicalMapNode(pi[key], mapping)
		if !ok {
			return errors.New("Native index expression mapping is incomplete.")
		}
		expectedIndex[key] = value
		ci = pgPhysicalCopy(ci)
		ci[key] = pgPhysicalNodePositions(ci[key])
	}
	for key, value := range expectedClass {
		if !reflect.DeepEqual(value, cc[key]) {
			return fmt.Errorf("The clone index class property %s differs from its reviewed origin.", key)
		}
	}
	for key, value := range expectedIndex {
		if !reflect.DeepEqual(value, ci[key]) {
			return fmt.Errorf("The clone native index property %s differs from its reviewed origin.", key)
		}
	}
	if len(expectedClass) != len(cc) || len(expectedIndex) != len(ci) {
		return errors.New("The clone native catalog fields changed unexpectedly.")
	}
	return nil
}

func (*Session) SupportsAdvancedKinds() bool { return true }

func pgAdvancedReview(b tableedit.Baseline, d tableedit.Draft, out *tableedit.Prepared) error {
	if b.Advanced == nil {
		return nil
	}
	for _, kind := range b.Advanced.Kinds {
		if kind == "unlogged" {
			out.Risks = append(out.Risks, "UNLOGGED persistence remains unchanged. Row data is not WAL-logged, may be truncated after an unclean server shutdown and is not replicated to standbys; no durability conversion is implicit.")
		}
	}
	out.Consequences = append(out.Consequences, tableedit.Consequence{Kind: "advancedProperties", Object: pgPhysicalName(b.Target), Message: "The complete connected hierarchy, RLS/FORCE flags, policy node trees and roles, table/column ACLs, composite-type binding, native constraints/indexes/triggers/comments/storage/options and dependency provenance are retained. Local ALTER statements use ONLY; no policy, role or composite type is edited, and no hidden row copy, CASCADE or descendant column DDL is generated."})
	for i, check := range out.ValidationChecks {
		if check.SQL != nil {
			out.ValidationChecks[i] = pgUnavailableCheck(check.ID, check.Summary, "Additional advanced-table row validation is not implemented. Policy-filtered/inherited SELECT cannot establish whole-table proof. The reviewed DDL enforces native NOT NULL, uniqueness and type acceptance; no bypass-RLS read or hidden row copy runs.")
		}
	}
	for i, consequence := range out.Consequences {
		if consequence.Kind == "conversion" {
			out.Consequences[i].Message = "This explicitly reviewed local built-in widening preserves representable integer/varchar values. PostgreSQL DDL validates acceptance and may rewrite/lock the table. No USING expression, policy-filtered validation or hidden row copy is generated."
		}
	}
	for _, change := range d.Changes {
		if change.Drop {
			column, ok := tableedit.FindColumn(b, change.Name)
			if !ok {
				return tableedit.ErrUnsupported
			}
			description, _ := json.Marshal(column)
			if len(description) > 3800 {
				return errors.New("The selected column's complete affected-property description exceeds the review bound.")
			}
			out.Consequences = append(out.Consequences, tableedit.Consequence{Kind: "columnProperties", Object: change.Name, Message: "The selected local column and these exact type/default/generation/identity/collation/comment properties are permanently removed: " + string(description)})
		}
	}
	parent := b.Facts.Table.Kind.Value != nil && *b.Facts.Table.Kind.Value == "p"
	if !parent {
		return nil
	}
	hasCreate := false
	for _, x := range d.Indexes {
		hasCreate = hasCreate || x.Action != "drop"
	}
	for _, x := range d.Keys {
		hasCreate = hasCreate || x.Action != "drop" && (x.Kind == "primary" || x.Kind == "unique")
	}
	if !hasCreate {
		return nil
	}
	descendants := map[string]bool{b.Identity: true}
	for changed := true; changed; {
		changed = false
		for key, rows := range b.AdvancedEvidence.Rows {
			if !strings.HasSuffix(key, "inherits") {
				continue
			}
			for _, link := range rows {
				p, ch := fmt.Sprint(link["inhparent"]), fmt.Sprint(link["inhrelid"])
				if descendants[p] && !descendants[ch] && len(b.AdvancedEvidence.Rows[ch+"/class"]) == 1 {
					descendants[ch] = true
					changed = true
				}
			}
		}
	}
	for id := range descendants {
		rows := b.AdvancedEvidence.Rows[id+"/class"]
		if len(rows) != 1 {
			return tableedit.ErrUnsupported
		}
		cl := rows[0]
		name := fmt.Sprint(cl["relname"])
		indexes := []string{}
		for _, x := range b.AdvancedEvidence.Rows[id+"/indexes"] {
			indexes = append(indexes, fmt.Sprint(x["class"].(map[string]any)["relname"]))
		}
		sort.Strings(indexes)
		message := "PostgreSQL creates the reviewed normal index/PRIMARY/UNIQUE structure on this hierarchy member, or attaches an exactly matching existing index. Exact OID parent links and name/type-mapped key/expression semantics are checked before COMMIT; preexisting native properties remain unchanged except disclosed partition attachment. Current candidate index names: " + strings.Join(indexes, ", ") + ". PRIMARY KEY also enforces NOT NULL on its selected key columns through the hierarchy; validation is performed by server DDL and is never inferred from policy-filtered rows."
		if len(message) > 4096 {
			return errors.New("The complete descendant index-effect description exceeds the bounded review envelope.")
		}
		out.Consequences = append(out.Consequences, tableedit.Consequence{Kind: "nativeHierarchy", Object: name, Message: message})
	}
	return nil
}

func pgAdvancedNormalizeTypes(a, b *tableedit.AdvancedEvidence, prefix string, before, after tableedit.Baseline, op tableedit.Operation) bool {
	allowed := map[string]bool{}
	add := func(attrs map[string]any) {
		if attrs == nil {
			return
		}
		id := fmt.Sprint(attrs["atttypid"])
		n, e := strconv.ParseUint(id, 10, 32)
		if e == nil && n > 0 && n < 16384 {
			allowed[id] = true
		}
	}
	if op.Column != nil {
		add(after.Attributes[op.Column.Name])
	}
	if op.Change != nil {
		add(before.Attributes[op.Change.Name])
		add(after.Attributes[op.Change.Name])
	}
	left, right := map[string]map[string]any{}, map[string]map[string]any{}
	for _, row := range a.Rows[prefix+"types"] {
		left[fmt.Sprint(row["oid"])] = row
	}
	for _, row := range b.Rows[prefix+"types"] {
		right[fmt.Sprint(row["oid"])] = row
	}
	for id, row := range left {
		if next, ok := right[id]; ok {
			if !reflect.DeepEqual(row, next) {
				return false
			}
		} else if !allowed[id] {
			return false
		}
	}
	for id := range right {
		if _, ok := left[id]; !ok && !allowed[id] {
			return false
		}
	}
	for _, e := range []*tableedit.AdvancedEvidence{a, b} {
		out := []map[string]any{}
		for _, row := range e.Rows[prefix+"types"] {
			id := fmt.Sprint(row["oid"])
			if left[id] != nil && right[id] != nil {
				out = append(out, row)
			}
		}
		e.Rows[prefix+"types"] = out
	}
	return true
}

func pgAdvancedRelation(prefix string, e *tableedit.AdvancedEvidence) pgPhysicalRelation {
	rows := e.Rows[prefix+"class"]
	if len(rows) != 1 {
		return pgPhysicalRelation{}
	}
	id, _ := strconv.ParseUint(fmt.Sprint(rows[0]["oid"]), 10, 32)
	relation := pgPhysicalRelation{OID: uint32(id), Class: rows[0], Columns: e.Rows[prefix+"attributes"]}
	for _, row := range e.Rows[prefix+"inherits"] {
		raw, err := json.Marshal(row)
		if err != nil {
			return pgPhysicalRelation{}
		}
		relation.Inherits = append(relation.Inherits, raw)
	}
	return relation
}

func pgAdvancedAttnums(value any) []string {
	if value == nil {
		return nil
	}
	out := []string{}
	if values, ok := value.([]any); ok {
		for _, v := range values {
			out = append(out, fmt.Sprint(v))
		}
		return out
	}
	return strings.Fields(fmt.Sprint(value))
}

func pgAdvancedRemovalReview(b tableedit.Baseline, d tableedit.Draft, out *tableedit.Prepared) error {
	if b.Advanced == nil {
		return nil
	}
	selected := map[string]bool{}
	for _, x := range d.Indexes {
		if x.Action != "add" {
			selected[x.Name] = true
		}
	}
	for _, k := range d.Keys {
		if k.Action != "add" && (k.Kind == "primary" || k.Kind == "unique") {
			selected[k.Name] = true
		}
	}
	indexes := map[string]map[string]any{}
	relation := map[string]string{}
	for key, rows := range b.AdvancedEvidence.Rows {
		if !strings.HasSuffix(key, "/indexes") {
			continue
		}
		for _, row := range rows {
			cl := row["class"].(map[string]any)
			id := pgPhysicalOID(cl["oid"])
			indexes[id] = row
			relation[id] = strings.TrimSuffix(key, "indexes")
		}
	}
	affected := map[string]bool{}
	for id, row := range indexes {
		if relation[id] == b.Identity+"/" && selected[fmt.Sprint(row["class"].(map[string]any)["relname"])] {
			affected[id] = true
		}
	}
	for changed := true; changed; {
		changed = false
		for id, row := range indexes {
			if affected[id] {
				continue
			}
			parents, ok := row["parents"].([]any)
			if !ok {
				return tableedit.ErrUnsupported
			}
			for _, parent := range parents {
				if affected[pgPhysicalOID(parent)] {
					affected[id] = true
					changed = true
				}
			}
		}
	}
	for id := range affected {
		row := indexes[id]
		prefix := relation[id]
		properties := map[string]any{"index": row, "constraints": []map[string]any{}, "comments": []map[string]any{}, "securityLabels": []map[string]any{}}
		constraints := map[string]bool{}
		for _, constraint := range b.AdvancedEvidence.Rows[prefix+"constraints"] {
			if pgPhysicalOID(constraint["conindid"]) == id {
				properties["constraints"] = append(properties["constraints"].([]map[string]any), constraint)
				constraints[pgPhysicalOID(constraint["oid"])] = true
			}
		}
		for category, outkey := range map[string]string{"comments": "comments", "labels": "securityLabels"} {
			for _, entry := range b.AdvancedEvidence.Rows[prefix+category] {
				if fmt.Sprint(entry["classoid"]) == "1259" && pgPhysicalOID(entry["objoid"]) == id || fmt.Sprint(entry["classoid"]) == "2606" && constraints[pgPhysicalOID(entry["objoid"])] {
					properties[outkey] = append(properties[outkey].([]map[string]any), entry)
				}
			}
		}
		for _, attr := range b.AdvancedEvidence.Rows[prefix+"indexAttributes"] {
			if pgPhysicalOID(attr["attrelid"]) != id {
				continue
			}
			raw, _ := json.Marshal(attr)
			message := "Removing this exact native index also removes the captured index-column type, layout, statistics and options: " + string(raw)
			if len(message) > 4096 {
				return errors.New("The complete native index-column removal description exceeds its review bound.")
			}
			out.Consequences = append(out.Consequences, tableedit.Consequence{Kind: "nativeRemoval", Object: fmt.Sprint(row["class"].(map[string]any)["relname"]) + " column " + fmt.Sprint(attr["attnum"]), Message: message})
		}
		raw, _ := json.Marshal(properties)
		message := "This explicitly reviewed parent/local removal permanently removes this exact index and any listed owned constraints, including origin-linked native descendants. No unrelated index, constraint or foreign key is removed; RESTRICT remains active. Exact affected native properties: " + string(raw)
		if len(message) > 4096 {
			return errors.New("The complete native descendant-removal property description exceeds the review bound; split the operation into explicit reviewed migration steps.")
		}
		out.Consequences = append(out.Consequences, tableedit.Consequence{Kind: "nativeRemoval", Object: fmt.Sprint(row["class"].(map[string]any)["relname"]), Message: message})
	}
	return nil
}

func pgAdvancedPreservationError(before, after tableedit.Baseline, c tableedit.Condition) error {
	if pgAdvancedRecursiveCondition(before, c) {
		return pgAdvancedRecursivePreservationError(before, after, c)
	}
	return pgAdvancedLocalPreservationError(before, after, c)
}
