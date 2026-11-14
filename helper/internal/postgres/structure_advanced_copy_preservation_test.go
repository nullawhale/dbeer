package postgres

import (
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"fmt"
	"strconv"
	"testing"
)

// A closed, synthetic native-catalog fixture: one selected inheritance parent,
// one retained child, identity ownership, TOAST, RLS/FORCE, ACLs and user code.
// OIDs are deliberate small test identities; no live server or row data is used.
func pgCopyFixture(root, child int, rootOrder, childOrder []string) tableedit.Baseline {
	e := &tableedit.AdvancedEvidence{Facts: map[string]*tableedit.Facts{}, Rows: map[string][]map[string]any{}, Targets: []tableedit.Target{}}
	ids := []int{root, child}
	orders := [][]string{rootOrder, childOrder}
	for i, oid := range ids {
		id, name := strconv.Itoa(oid), []string{"parent", "child"}[i]
		target := tableedit.Target{Schema: "exact_schema", Table: name}
		e.Targets = append(e.Targets, target)
		facts := &tableedit.Facts{Proof: true, ServerVersion: 170000, Table: sc.Table{Ref: sc.Ref{Kind: "table", Schema: target.Schema, Name: name}, Columns: sc.Complete([]sc.Column{})}}
		attrs := []map[string]any{}
		nums := map[string]int{}
		for pos, column := range orders[i] {
			nums[column] = pos + 1
			typ, storage, identity := 23, "p", ""
			if column == "note" {
				typ, storage = 25, "x"
			}
			if column == "id" {
				identity = "a"
			}
			attrs = append(attrs, map[string]any{"attrelid": oid, "attname": column, "atttypid": typ, "attnum": pos + 1, "atttypmod": -1, "attcollation": 0, "attisdropped": false, "attnotnull": column == "id", "attidentity": identity, "attgenerated": "", "attstorage": storage, "attcompression": "", "attacl": nil, "attoptions": nil, "attfdwoptions": nil, "atthasmissing": false, "attmissingval": nil, "attislocal": true, "attinhcount": 0})
			facts.Table.Columns.Items = append(facts.Table.Columns.Items, sc.Column{Ref: sc.Ref{Kind: "column", Schema: target.Schema, Table: name, Name: column}, Ordinal: sc.Known(pos)})
		}
		e.Facts[id] = facts
		for _, category := range []string{"defaults", "constraints", "indexes", "indexAttributes", "triggers", "policies", "inherits", "partition", "types", "typeAttributes", "statistics", "rules", "publication", "dependencies", "comments", "labels", "toast", "sequences", "copyPrivileges"} {
			e.Rows[id+"/"+category] = []map[string]any{}
		}
		cl := pgCopyClass(oid, name, "r")
		cl["reltype"], cl["relrowsecurity"], cl["relforcerowsecurity"], cl["relhassubclass"] = oid+1, true, true, i == 0
		cl["reltoastrelid"] = oid + 16
		e.Rows[id+"/class"] = []map[string]any{cl}
		e.Rows[id+"/attributes"] = attrs
		e.Rows[id+"/types"] = []map[string]any{
			{"oid": oid + 1, "typname": name, "typnamespace": 900, "typowner": 10, "typtype": "c", "typrelid": oid, "typarray": oid + 2, "typelem": 0, "typacl": nil},
			{"oid": oid + 2, "typname": "_" + name, "typnamespace": 900, "typowner": 10, "typtype": "b", "typrelid": 0, "typarray": 0, "typelem": oid + 1, "typacl": nil},
			{"oid": 50000, "typname": "external", "typnamespace": 901, "typowner": 10, "typtype": "d", "typrelid": 0, "typarray": 50002, "typelem": 0, "typbasetype": 23, "typacl": nil},
		}
		e.Rows[id+"/defaults"] = []map[string]any{{"oid": oid + 13, "adrelid": oid, "adnum": nums["note"], "adbin": "{CONST :consttype 25 :location 17 :constvalue 4 [ 100 0 0 0 ]}"}}
		e.Rows[id+"/constraints"] = []map[string]any{{"oid": oid + 11, "conname": name + "_positive", "connamespace": 900, "contype": "c", "conrelid": oid, "contypid": 0, "conindid": 0, "conparentid": 0, "confrelid": 0, "conkey": []any{nums["id"]}, "confkey": nil, "conbin": pgCopyVar(nums["id"]), "conislocal": true, "coninhcount": 0, "connoinherit": false, "convalidated": true}}
		e.Rows[id+"/indexes"] = []map[string]any{{"class": pgCopyClass(oid+10, name+"_index", "i"), "index": map[string]any{"indexrelid": oid + 10, "indrelid": oid, "indnatts": 1, "indkey": fmt.Sprint(nums["id"]), "indexprs": pgCopyVar(nums["note"]), "indpred": nil, "indcollation": "0", "indclass": "1978", "indoption": "0", "indisvalid": true, "indisready": true, "indislive": true, "indisclustered": true, "indisreplident": false}, "parents": []any{}}}
		e.Rows[id+"/policies"] = []map[string]any{{"oid": oid + 12, "polname": "keep", "polrelid": oid, "polcmd": "*", "polpermissive": true, "polroles": []any{10}, "polqual": pgCopyVar(nums["id"]), "polwithcheck": pgCopyVar(nums["note"])}}
		e.Rows[id+"/triggers"] = []map[string]any{pgCopyUserTrigger(oid+15, oid, 0, "keep_user", nums["id"], false)}
		e.Rows[id+"/statistics"] = []map[string]any{{"oid": 51000 + i, "stxrelid": oid, "stxname": "retained", "stxkeys": fmt.Sprintf("%d %d", nums["id"], nums["note"]), "stxexprs": pgCopyVar(nums["id"])}}
		e.Rows[id+"/publication"] = []map[string]any{{"oid": 52000 + i, "prrelid": oid, "prpubid": 53000, "prattrs": []any{nums["note"]}, "prqual": pgCopyVar(nums["id"])}}
		e.Rows[id+"/dependencies"] = []map[string]any{
			pgCopyDep("1259", oid+10, 0, "1259", oid, nums["id"], "a"),
			pgCopyDep("2604", oid+13, 0, "1259", oid, nums["note"], "a"),
			pgCopyDep("2606", oid+11, 0, "1259", oid, nums["id"], "a"),
			pgCopyDep("1247", oid+1, 0, "1259", oid, 0, "i"),
			pgCopyDep("1247", oid+2, 0, "1247", oid+1, 0, "i"),
			pgCopyDep("9999", 100, 0, "1259", oid, 0, "n"),
		}
		e.Rows[id+"/comments"] = []map[string]any{{"classoid": 1259, "objoid": oid, "objsubid": nums["note"], "description": "The literal 100 is unchanged."}, {"classoid": 2606, "objoid": oid + 11, "objsubid": 0, "description": "retained"}}
		e.Rows[id+"/labels"] = []map[string]any{{"classoid": 3256, "objoid": oid + 12, "objsubid": 0, "provider": "fixture", "label": "exact"}}
		e.Rows[id+"/copyPrivileges"] = []map[string]any{pgCopyPrivilege("", "10", "10", "SELECT", false), pgCopyPrivilege("note", "10", "0", "SELECT", true)}
		seqcl := pgCopyClass(oid+14, name+"_id_seq", "S")
		e.Rows[id+"/sequences"] = []map[string]any{{"column": "id", "class": seqcl, "sequence": map[string]any{"seqrelid": oid + 14, "seqtypid": 23, "seqstart": 1, "seqincrement": 7, "seqmax": 2147483647, "seqmin": 1, "seqcache": 3, "seqcycle": false}, "dependencies": []any{pgCopyDep("1259", oid+14, 0, "1259", oid, nums["id"], "i")}, "comments": []any{map[string]any{"classoid": 1259, "objoid": oid + 14, "objsubid": 0, "description": "sequence"}}, "labels": []any{}, "copyPrivileges": []any{pgCopyPrivilege("", "10", "10", "USAGE", false)}}}
		toastcl := pgCopyClass(oid+16, "pg_toast_"+id, "t")
		toastattrs := []any{}
		for pos, n := range []string{"chunk_id", "chunk_seq", "chunk_data"} {
			toastattrs = append(toastattrs, map[string]any{"attrelid": oid + 16, "attname": n, "attnum": pos + 1, "atttypid": []int{26, 23, 17}[pos], "atttypmod": -1, "attcollation": 0, "attisdropped": false, "attacl": nil})
		}
		e.Rows[id+"/toast"] = []map[string]any{{"class": toastcl, "attributes": toastattrs, "indexes": []any{map[string]any{"class": pgCopyClass(oid+17, "pg_toast_"+id+"_index", "i"), "index": map[string]any{"indexrelid": oid + 17, "indrelid": oid + 16, "indnatts": 2, "indkey": "1 2", "indexprs": nil, "indpred": nil}}}}}
		e.Rows[id+"/indexAttributes"] = []map[string]any{pgCopyIndexAttribute(oid+10, 1, 23), pgCopyIndexAttribute(oid+17, 1, 26), pgCopyIndexAttribute(oid+17, 2, 23)}
	}
	edge := map[string]any{"inhrelid": child, "inhparent": root, "inhseqno": 1, "inhdetachpending": false}
	e.Rows[strconv.Itoa(root)+"/inherits"] = []map[string]any{edge}
	e.Rows[strconv.Itoa(child)+"/inherits"] = []map[string]any{edge}
	e.Rows["global/roles"] = []map[string]any{{"oid": 10, "rolname": "owner", "rolsuper": true}}
	e.Rows["global/memberships"] = []map[string]any{}
	e.Rows["global/copyDefaultPrivileges"] = []map[string]any{}
	e.Rows["global/copyRIFunctions"] = []map[string]any{}
	for i, name := range []string{"RI_FKey_check_ins", "RI_FKey_check_upd", "RI_FKey_noaction_del", "RI_FKey_noaction_upd", "RI_FKey_restrict_del", "RI_FKey_restrict_upd", "RI_FKey_cascade_del", "RI_FKey_cascade_upd", "RI_FKey_setnull_del", "RI_FKey_setnull_upd", "RI_FKey_setdefault_del", "RI_FKey_setdefault_upd"} {
		e.Rows["global/copyRIFunctions"] = append(e.Rows["global/copyRIFunctions"], map[string]any{"oid": 1000 + i, "proname": name, "prosrc": name, "pronamespace": 11, "prolang": 12, "prorettype": 2279, "pronargs": 0, "pronargdefaults": 0, "proconfig": nil, "prosecdef": false})
	}
	return tableedit.Baseline{Engine: "postgresql", Identity: strconv.Itoa(root), Scope: "fixture scope", Target: e.Targets[0], Facts: e.Facts[strconv.Itoa(root)], AdvancedEvidence: e, Advanced: &tableedit.AdvancedKindSupport{}}
}
func pgCopyClass(oid int, name, kind string) map[string]any {
	return map[string]any{"oid": strconv.Itoa(oid), "relname": name, "relnamespace": 900, "reltype": 0, "relowner": 10, "relam": 2, "relfilenode": oid + 100000, "reltoastrelid": 0, "relkind": kind, "relpersistence": "p", "relispartition": false, "relhassubclass": false, "relrowsecurity": false, "relforcerowsecurity": false, "reloftype": 0, "relacl": nil, "reloptions": []any{"fillfactor=73"}, "reltablespace": 0, "relreplident": "d", "relpartbound": nil, "unknownOIDLike": 100}
}
func pgCopyIndexAttribute(oid, n, typ int) map[string]any {
	return map[string]any{"attrelid": oid, "attnum": n, "attname": fmt.Sprintf("term_%d", n), "atttypid": typ, "atttypmod": -1, "attcollation": 0, "attstorage": "p", "attcompression": "", "attisdropped": false, "atthasmissing": false, "attmissingval": nil, "attstattarget": 321, "attoptions": nil, "attacl": nil, "attislocal": true, "attinhcount": 0}
}
func pgCopyVar(n int) string {
	return fmt.Sprintf("{VAR :varno 1 :varattno %d :vartype 23 :vartypmod -1 :varcollid 0 :varlevelsup 0 :varnosyn 1 :varattnosyn %d :location 19}", n, n)
}
func pgCopyDep(catalog string, oid, sub int, refcat string, ref, refsub int, kind string) map[string]any {
	return map[string]any{"classid": catalog, "objid": strconv.Itoa(oid), "objsubid": sub, "refclassid": refcat, "refobjid": strconv.Itoa(ref), "refobjsubid": refsub, "deptype": kind}
}
func pgCopyPrivilege(column, grantor, grantee, privilege string, grantable bool) map[string]any {
	return map[string]any{"column": column, "grantor": grantor, "grantee": grantee, "privilege": privilege, "grantable": grantable}
}
func pgCopyUserTrigger(oid, rel, parent int, name string, att int, internal bool) map[string]any {
	return map[string]any{"oid": strconv.Itoa(oid), "tgrelid": strconv.Itoa(rel), "tgparentid": strconv.Itoa(parent), "tgname": name, "tgfoid": "50001", "tgtype": float64(19), "tgenabled": "O", "tgisinternal": internal, "tgconstrrelid": "0", "tgconstrindid": "0", "tgconstraint": "0", "tgdeferrable": false, "tginitdeferred": false, "tgnargs": float64(0), "tgattr": []any{att}, "tgargs": "\\x", "tgqual": pgCopyVar(att), "tgoldtable": nil, "tgnewtable": nil}
}

func TestAdvancedCopyPreservationClosedCatalog(t *testing.T) {
	before := pgCopyFixture(100, 120, []string{"id", "note"}, []string{"id", "note"})
	after := pgCopyFixture(200, 120, []string{"note", "id"}, []string{"id", "note"})
	orders := map[string][]string{"100": {"note", "id"}, "120": {"id", "note"}}
	x, _ := json.Marshal(before.AdvancedEvidence)
	y, _ := json.Marshal(after.AdvancedEvidence)
	for i := 0; i < 25; i++ {
		if err := pgAdvancedCopyPreservationError(before, after, orders, map[string]bool{"100": true}); err != nil {
			t.Fatal(err)
		}
	}
	ux, _ := json.Marshal(before.AdvancedEvidence)
	uy, _ := json.Marshal(after.AdvancedEvidence)
	if string(x) != string(ux) || string(y) != string(uy) {
		t.Fatal("preservation comparison mutated its inputs")
	}
	if err := pgAdvancedCopyPreservationError(before, before, map[string][]string{"100": {"id", "note"}, "120": {"id", "note"}}, nil); err != nil {
		t.Fatal(err)
	}
}

func TestAdvancedCopyPreservationRejectsCatalogDrift(t *testing.T) {
	mutations := map[string]func(*tableedit.Baseline){
		"type":          func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/attributes"][0]["atttypid"] = 1043 },
		"collation":     func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/attributes"][0]["attcollation"] = 950 },
		"unknown field": func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/class"][0]["unknownOIDLike"] = 200 },
		"unknown category": func(b *tableedit.Baseline) {
			b.AdvancedEvidence.Rows["200/newCategory"] = []map[string]any{{"oid": 200}}
		},
		"target":               func(b *tableedit.Baseline) { b.AdvancedEvidence.Facts["200"].Table.Ref.Schema = "other" },
		"partial targets":      func(b *tableedit.Baseline) { b.AdvancedEvidence.Targets = b.AdvancedEvidence.Targets[:1] },
		"missing category":     func(b *tableedit.Baseline) { delete(b.AdvancedEvidence.Rows, "200/dependencies") },
		"missing graph member": func(b *tableedit.Baseline) { delete(b.AdvancedEvidence.Facts, "120") },
		"force RLS":            func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/class"][0]["relforcerowsecurity"] = false },
		"policy roles":         func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/policies"][0]["polroles"] = []any{0} },
		"policy expression":    func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/policies"][0]["polqual"] = pgCopyVar(1) },
		"storage option": func(b *tableedit.Baseline) {
			b.AdvancedEvidence.Rows["200/class"][0]["reloptions"] = []any{"fillfactor=90"}
		},
		"attribute storage":     func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/attributes"][0]["attstorage"] = "p" },
		"zero storage identity": func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/class"][0]["relfilenode"] = 0 },
		"unselected storage":    func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["120/class"][0]["relfilenode"] = 1 },
		"unselected policy OID": func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["120/policies"][0]["oid"] = 999 },
		"external type binding": func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/types"][2]["typbasetype"] = 20 },
		"array origin":          func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/types"][1]["typelem"] = 121 },
		"function binding":      func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/triggers"][0]["tgfoid"] = "50002" },
		"dependency catalog":    func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/dependencies"][5]["objid"] = "200" },
		"dependency target":     func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/dependencies"][0]["refobjsubid"] = 1 },
		"comment bytes": func(b *tableedit.Baseline) {
			b.AdvancedEvidence.Rows["200/comments"][0]["description"] = "The literal 200 is unchanged."
		},
		"effective grant":   func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/copyPrivileges"][0]["privilege"] = "UPDATE" },
		"grant option":      func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/copyPrivileges"][1]["grantable"] = false },
		"grantor":           func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/copyPrivileges"][1]["grantor"] = "11" },
		"missing ACL proof": func(b *tableedit.Baseline) { delete(b.AdvancedEvidence.Rows, "200/copyPrivileges") },
		"unknown ACL field": func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/copyPrivileges"][0]["scope"] = "other" },
		"index ACL": func(b *tableedit.Baseline) {
			b.AdvancedEvidence.Rows["200/indexes"][0]["class"].(map[string]any)["relacl"] = []any{"other=arwd/owner"}
		},
		"type ACL": func(b *tableedit.Baseline) {
			b.AdvancedEvidence.Rows["200/types"][0]["typacl"] = []any{"other=U/owner"}
		},
		"RI function provenance": func(b *tableedit.Baseline) {
			b.AdvancedEvidence.Rows["global/copyRIFunctions"][0]["prosrc"] = "untrusted"
		},
		"sequence ACL": func(b *tableedit.Baseline) {
			b.AdvancedEvidence.Rows["200/sequences"][0]["copyPrivileges"].([]any)[0].(map[string]any)["privilege"] = "SELECT"
		},
		"sequence owner edge": func(b *tableedit.Baseline) {
			b.AdvancedEvidence.Rows["200/sequences"][0]["dependencies"].([]any)[0].(map[string]any)["refobjsubid"] = 1
		},
		"sequence increment": func(b *tableedit.Baseline) {
			b.AdvancedEvidence.Rows["200/sequences"][0]["sequence"].(map[string]any)["seqincrement"] = 1
		},
		"toast unknown field": func(b *tableedit.Baseline) {
			b.AdvancedEvidence.Rows["200/toast"][0]["class"].(map[string]any)["unknownOIDLike"] = 200
		},
	}
	for name, mutate := range mutations {
		t.Run(name, func(t *testing.T) {
			before := pgCopyFixture(100, 120, []string{"id", "note"}, []string{"id", "note"})
			after := pgCopyFixture(200, 120, []string{"note", "id"}, []string{"id", "note"})
			mutate(&after)
			if pgAdvancedCopyPreservationError(before, after, map[string][]string{"100": {"note", "id"}, "120": {"id", "note"}}, map[string]bool{"100": true}) == nil {
				t.Fatal("accepted unreviewed catalog drift")
			}
		})
	}
}

func TestAdvancedCopyPreservationRequiresReviewedGraph(t *testing.T) {
	before := pgCopyFixture(100, 120, []string{"id", "note"}, []string{"id", "note"})
	after := pgCopyFixture(200, 120, []string{"note", "id"}, []string{"id", "note"})
	for name, orders := range map[string]map[string][]string{"missing member": {"100": {"note", "id"}}, "duplicate name": {"100": {"id", "id"}, "120": {"id", "note"}}, "wrong order": {"100": {"id", "note"}, "120": {"id", "note"}}, "unknown member": {"100": {"note", "id"}, "121": {"id", "note"}}} {
		t.Run(name, func(t *testing.T) {
			if pgAdvancedCopyPreservationError(before, after, orders, map[string]bool{"100": true}) == nil {
				t.Fatal("accepted incomplete reviewed orders")
			}
		})
	}
	orders := map[string][]string{"100": {"note", "id"}, "120": {"id", "note"}}
	if pgAdvancedCopyPreservationError(before, after, orders, nil) == nil {
		t.Fatal("accepted unreviewed replacement")
	}
	if pgAdvancedCopyPreservationError(before, after, orders, map[string]bool{"100": true, "999": true}) == nil {
		t.Fatal("accepted unknown replacement")
	}
	after = pgCopyFixture(200, 220, []string{"note", "id"}, []string{"id", "note"})
	if pgAdvancedCopyPreservationError(before, after, orders, map[string]bool{"100": true}) == nil {
		t.Fatal("accepted unselected member OID replacement")
	}
	if err := pgAdvancedCopyPreservationError(before, after, orders, map[string]bool{"100": true, "120": true}); err != nil {
		t.Fatal(err)
	}
	after = pgCopyFixture(200, 120, []string{"note", "id"}, []string{"note", "id"})
	if pgAdvancedCopyPreservationError(before, after, map[string][]string{"100": {"note", "id"}, "120": {"note", "id"}}, map[string]bool{"100": true}) == nil {
		t.Fatal("accepted unselected member attribute reordering")
	}
}

func TestAdvancedCopyPreservationEffectiveACLAndPhysicalNormalizers(t *testing.T) {
	before := pgCopyFixture(100, 120, []string{"id", "note"}, []string{"id", "note"})
	after := pgCopyFixture(200, 120, []string{"note", "id"}, []string{"id", "note"})
	after.AdvancedEvidence.Rows["200/class"][0]["relacl"] = []any{"owner=r/owner"}
	after.AdvancedEvidence.Rows["200/attributes"][0]["attacl"] = []any{"=r*/owner"}
	after.AdvancedEvidence.Rows["200/sequences"][0]["class"].(map[string]any)["relacl"] = []any{"owner=U/owner"}
	before.AdvancedEvidence.Rows["100/attributes"][1]["atthasmissing"] = true
	before.AdvancedEvidence.Rows["100/attributes"][1]["attmissingval"] = []any{"retained datum"}
	before.AdvancedEvidence.Rows["100/attributes"][1]["attoptions"] = []any{"pg_attver=100"}
	after.AdvancedEvidence.Rows["200/attributes"][0]["attoptions"] = []any{"pg_attver=200"}
	if err := pgAdvancedCopyPreservationError(before, after, map[string][]string{"100": {"note", "id"}, "120": {"id", "note"}}, map[string]bool{"100": true}); err != nil {
		t.Fatal(err)
	}
}

func TestAdvancedCopyPreservationMaterializationNeedsNativeDatum(t *testing.T) {
	orders := map[string][]string{"100": {"note", "id"}, "120": {"id", "note"}}
	for _, datum := range []any{"{unproven datum}", []any{}, []any{"one", "two"}, nil} {
		t.Run(fmt.Sprintf("%T-%v", datum, datum), func(t *testing.T) {
			a := pgCopyFixture(100, 120, []string{"id", "note"}, []string{"id", "note"})
			b := pgCopyFixture(200, 120, []string{"note", "id"}, []string{"id", "note"})
			a.AdvancedEvidence.Rows["100/attributes"][1]["atthasmissing"] = true
			a.AdvancedEvidence.Rows["100/attributes"][1]["attmissingval"] = datum
			if pgAdvancedCopyPreservationError(a, b, orders, map[string]bool{"100": true}) == nil {
				t.Fatal("materialized a datum without its native single-element array shape")
			}
		})
	}
}

func TestAdvancedCopyPreservationDependencyDescriptionOrder(t *testing.T) {
	a := pgCopyFixture(100, 120, []string{"id", "note"}, []string{"id", "note"})
	b := pgCopyFixture(200, 120, []string{"note", "id"}, []string{"id", "note"})
	a.AdvancedEvidence.Facts["120"].Dependents = map[string][]string{"id": {"parent trigger", "own trigger", "parent trigger"}}
	b.AdvancedEvidence.Facts["120"].Dependents = map[string][]string{"id": {"parent trigger", "parent trigger", "own trigger"}}
	orders := map[string][]string{"100": {"note", "id"}, "120": {"id", "note"}}
	if err := pgAdvancedCopyPreservationError(a, b, orders, map[string]bool{"100": true}); err != nil {
		t.Fatal(err)
	}
	b.AdvancedEvidence.Facts["120"].Dependents["id"] = []string{"parent trigger", "own trigger"}
	if pgAdvancedCopyPreservationError(a, b, orders, map[string]bool{"100": true}) == nil {
		t.Fatal("lost dependency label multiplicity")
	}
	b.AdvancedEvidence.Facts["120"].Dependents["id"] = []string{"parent trigger", "own trigger", "unreviewed trigger"}
	if pgAdvancedCopyPreservationError(a, b, orders, map[string]bool{"100": true}) == nil {
		t.Fatal("rewrote a retained dependency label")
	}
}

func TestAdvancedCopyPreservationRejectsUnprovenNodeRepairs(t *testing.T) {
	for _, node := range []string{"{VAR :varno 1 :varattno 0 :varattnosyn 0 :varlevelsup 0}", "{VAR :varno 2 :varattno 1 :varattnosyn 1 :varlevelsup 0}", "{VAR :varno 1 :varattno 1 :varattnosyn 1 :varlevelsup 1}", "{SUBLINK :subselect {QUERY :targetList (" + pgCopyVar(1) + ")}}", "{VAR :varattno 1}"} {
		t.Run(node, func(t *testing.T) {
			before := pgCopyFixture(100, 120, []string{"id", "note"}, []string{"id", "note"})
			after := pgCopyFixture(200, 120, []string{"note", "id"}, []string{"id", "note"})
			before.AdvancedEvidence.Rows["100/policies"][0]["polqual"] = node
			after.AdvancedEvidence.Rows["200/policies"][0]["polqual"] = node
			if pgAdvancedCopyPreservationError(before, after, map[string][]string{"100": {"note", "id"}, "120": {"id", "note"}}, map[string]bool{"100": true}) == nil {
				t.Fatal("accepted unproven node mapping")
			}
		})
	}
}

func pgCopyPartitionTriggerFixture(version int) (tableedit.Baseline, tableedit.Baseline) {
	a := pgCopyFixture(100, 120, []string{"id", "note"}, []string{"id", "note"})
	b := pgCopyFixture(200, 120, []string{"note", "id"}, []string{"id", "note"})
	for _, x := range []struct {
		b    *tableedit.Baseline
		root int
	}{{&a, 100}, {&b, 200}} {
		e, id := x.b.AdvancedEvidence, strconv.Itoa(x.root)
		for _, facts := range e.Facts {
			facts.ServerVersion = version
		}
		e.Rows[id+"/class"][0]["relkind"], e.Rows[id+"/class"][0]["relfilenode"], e.Rows[id+"/class"][0]["reltoastrelid"] = "p", 0, 0
		e.Rows[id+"/toast"] = []map[string]any{}
		e.Rows[id+"/indexAttributes"] = e.Rows[id+"/indexAttributes"][:1]
		e.Rows["120/class"][0]["relispartition"] = true
		parentIndex := e.Rows[id+"/indexes"][0]["class"].(map[string]any)
		parentIndex["relkind"], parentIndex["relfilenode"], parentIndex["relhassubclass"] = "I", 0, true
		e.Rows["120/indexes"][0]["class"].(map[string]any)["relispartition"] = true
		e.Rows["120/indexes"][0]["parents"] = []any{x.root + 10}
		triggerOID := 135
		if x.root == 200 {
			triggerOID = 235
		}
		e.Rows["120/triggers"] = []map[string]any{pgCopyUserTrigger(triggerOID, 120, x.root+15, "keep_user", 1, version < 150000)}
	}
	return a, b
}

func TestAdvancedCopyPreservationNativeTriggerCloneCutoff(t *testing.T) {
	orders := map[string][]string{"100": {"note", "id"}, "120": {"id", "note"}}
	for _, version := range []int{140000, 150000, 170000, 180000} {
		t.Run(strconv.Itoa(version), func(t *testing.T) {
			before, after := pgCopyPartitionTriggerFixture(version)
			if err := pgAdvancedCopyPreservationError(before, after, orders, map[string]bool{"100": true}); err != nil {
				t.Fatal(err)
			}
			for _, mutation := range []func(*tableedit.Baseline){
				func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["120/triggers"][0]["tgparentid"] = "9999" },
				func(b *tableedit.Baseline) {
					b.AdvancedEvidence.Rows["120/triggers"][0]["tgisinternal"] = version >= 150000
				},
				func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["120/triggers"][0]["tgfoid"] = "50002" },
				func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["120/triggers"][0]["tgattr"] = []any{2} },
				func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["120/inherits"] = []map[string]any{} },
			} {
				_, bad := pgCopyPartitionTriggerFixture(version)
				mutation(&bad)
				if pgAdvancedCopyPreservationError(before, bad, orders, map[string]bool{"100": true}) == nil {
					t.Fatal("accepted a forged native clone origin")
				}
			}
			before.AdvancedEvidence.Rows["120/triggers"][0]["tgisinternal"] = version >= 150000
			after.AdvancedEvidence.Rows["120/triggers"][0]["tgisinternal"] = version >= 150000
			if pgAdvancedCopyPreservationError(before, after, orders, map[string]bool{"100": true}) == nil {
				t.Fatal("broadened the native version-specific clone flag exception")
			}
		})
	}
}

func pgCopyAddForeignKey(b *tableedit.Baseline, original bool) {
	root, base := 200, 250
	if original {
		root, base = 100, 150
	}
	id := strconv.Itoa(root)
	att := 2
	if original {
		att = 1
	}
	c := map[string]any{"oid": strconv.Itoa(root + 60), "conname": "keep_fk", "connamespace": 900, "contype": "f", "conrelid": strconv.Itoa(root), "contypid": "0", "conindid": "130", "conparentid": "0", "confrelid": "120", "conkey": []any{att}, "confkey": []any{1}, "conbin": nil, "conislocal": true, "coninhcount": 0, "connoinherit": true, "convalidated": true, "condeferrable": true, "condeferred": false, "confdeltype": "a", "confupdtype": "a"}
	e := b.AdvancedEvidence
	e.Rows[id+"/constraints"] = append(e.Rows[id+"/constraints"], c)
	e.Rows["120/constraints"] = append(e.Rows["120/constraints"], c)
	for i, spec := range []struct {
		rel, target, event, function int
		prefix                       string
	}{{root, 120, 5, 1000, "c"}, {root, 120, 17, 1001, "c"}, {120, root, 9, 1002, "a"}, {120, root, 17, 1003, "a"}} {
		oid := base + i
		row := map[string]any{"oid": strconv.Itoa(oid), "tgrelid": strconv.Itoa(spec.rel), "tgparentid": "0", "tgname": fmt.Sprintf("RI_ConstraintTrigger_%s_%d", spec.prefix, oid), "tgfoid": strconv.Itoa(spec.function), "tgtype": float64(spec.event), "tgenabled": "O", "tgisinternal": true, "tgconstrrelid": strconv.Itoa(spec.target), "tgconstrindid": "130", "tgconstraint": strconv.Itoa(root + 60), "tgdeferrable": true, "tginitdeferred": false, "tgnargs": float64(0), "tgattr": []any{}, "tgargs": "\\x", "tgqual": nil, "tgoldtable": nil, "tgnewtable": nil}
		e.Rows[strconv.Itoa(spec.rel)+"/triggers"] = append(e.Rows[strconv.Itoa(spec.rel)+"/triggers"], row)
	}
}

func TestAdvancedCopyPreservationInternalRIUsesExactNativeProof(t *testing.T) {
	orders := map[string][]string{"100": {"note", "id"}, "120": {"id", "note"}}
	for _, version := range []int{140000, 170000} {
		t.Run(strconv.Itoa(version), func(t *testing.T) {
			makePair := func() (tableedit.Baseline, tableedit.Baseline) {
				a := pgCopyFixture(100, 120, []string{"id", "note"}, []string{"id", "note"})
				b := pgCopyFixture(200, 120, []string{"note", "id"}, []string{"id", "note"})
				pgCopyAddForeignKey(&a, true)
				pgCopyAddForeignKey(&b, false)
				for _, e := range []*tableedit.AdvancedEvidence{a.AdvancedEvidence, b.AdvancedEvidence} {
					for _, facts := range e.Facts {
						facts.ServerVersion = version
					}
				}
				return a, b
			}
			before, after := makePair()
			if err := pgAdvancedCopyPreservationError(before, after, orders, map[string]bool{"100": true}); err != nil {
				t.Fatal(err)
			}
			for _, property := range []string{"tgfoid", "tgconstrrelid", "tgconstraint", "tgtype", "tgisinternal", "tgname", "unknownNativeField"} {
				t.Run(property, func(t *testing.T) {
					a, b := makePair()
					row := b.AdvancedEvidence.Rows["120/triggers"][1]
					row[property] = "forged"
					if pgAdvancedCopyPreservationError(a, b, orders, map[string]bool{"100": true}) == nil {
						t.Fatal("accepted changed internal trigger proof")
					}
				})
			}
			before, after = makePair()
			before.AdvancedEvidence.Rows["global/copyRIFunctions"][0]["prosecdef"] = true
			after.AdvancedEvidence.Rows["global/copyRIFunctions"][0]["prosecdef"] = true
			if pgAdvancedCopyPreservationError(before, after, orders, map[string]bool{"100": true}) == nil {
				t.Fatal("trusted a user-code RI binding")
			}
		})
	}
}

func TestAdvancedCopyPreservationUnknownFieldsStayExact(t *testing.T) {
	a := pgCopyFixture(100, 120, []string{"id", "note"}, []string{"id", "note"})
	b := pgCopyFixture(200, 120, []string{"note", "id"}, []string{"id", "note"})
	a.AdvancedEvidence.Rows["100/future"] = []map[string]any{{"oid": 100, "opaque": "100 remains opaque"}}
	b.AdvancedEvidence.Rows["200/future"] = []map[string]any{{"oid": 100, "opaque": "100 remains opaque"}}
	for _, e := range []*tableedit.AdvancedEvidence{a.AdvancedEvidence, b.AdvancedEvidence} {
		e.Rows["120/attributes"] = append(e.Rows["120/attributes"], map[string]any{"attrelid": 120, "attnum": 3, "attname": "dropped tombstone", "atttypid": 0, "atttypmod": -1, "attcollation": 0, "attisdropped": true, "attacl": nil})
	}
	if err := pgAdvancedCopyPreservationError(a, b, map[string][]string{"100": {"note", "id"}, "120": {"id", "note"}}, map[string]bool{"100": true}); err != nil {
		t.Fatal(err)
	}
	b.AdvancedEvidence.Rows["200/future"][0]["oid"] = 200
	if pgAdvancedCopyPreservationError(a, b, map[string][]string{"100": {"note", "id"}, "120": {"id", "note"}}, map[string]bool{"100": true}) == nil {
		t.Fatal("rewrote an unknown OID-shaped field")
	}
	b.AdvancedEvidence.Rows["200/future"][0]["oid"] = 100
	a.AdvancedEvidence.Rows["100/unknownEmpty"] = []map[string]any{}
	b.AdvancedEvidence.Rows["200/unknownEmpty"] = nil
	if pgAdvancedCopyPreservationError(a, b, map[string][]string{"100": {"note", "id"}, "120": {"id", "note"}}, map[string]bool{"100": true}) == nil {
		t.Fatal("collapsed an unknown category's NULL and empty array")
	}
}

func TestAdvancedCopyPreservationSerialSequenceIdentityRemainsExact(t *testing.T) {
	a := pgCopyFixture(100, 120, []string{"id", "note"}, []string{"id", "note"})
	b := pgCopyFixture(200, 120, []string{"note", "id"}, []string{"id", "note"})
	for _, x := range []struct {
		b    *tableedit.Baseline
		root string
	}{{&a, "100"}, {&b, "200"}} {
		for _, attr := range x.b.AdvancedEvidence.Rows[x.root+"/attributes"] {
			if attr["attname"] == "id" {
				attr["attidentity"] = ""
			}
		}
		x.b.AdvancedEvidence.Rows[x.root+"/sequences"][0]["dependencies"].([]any)[0].(map[string]any)["deptype"] = "a"
	}
	orders := map[string][]string{"100": {"note", "id"}, "120": {"id", "note"}}
	if pgAdvancedCopyPreservationError(a, b, orders, map[string]bool{"100": true}) == nil {
		t.Fatal("recreated an ordinary serial sequence without authority")
	}
	seq := b.AdvancedEvidence.Rows["200/sequences"][0]
	seq["class"].(map[string]any)["oid"] = "114"
	seq["class"].(map[string]any)["relfilenode"] = 100114
	seq["sequence"].(map[string]any)["seqrelid"] = 114
	seq["dependencies"].([]any)[0].(map[string]any)["objid"] = "114"
	seq["comments"].([]any)[0].(map[string]any)["objoid"] = 114
	if err := pgAdvancedCopyPreservationError(a, b, orders, map[string]bool{"100": true}); err != nil {
		t.Fatal(err)
	}
	seq["class"].(map[string]any)["relfilenode"] = 100999
	if pgAdvancedCopyPreservationError(a, b, orders, map[string]bool{"100": true}) == nil {
		t.Fatal("rewrote an unreviewed serial sequence file")
	}
}

func TestAdvancedCopyPreservationRequiresCompleteGraphOnBothSides(t *testing.T) {
	a := pgCopyFixture(100, 120, []string{"id", "note"}, []string{"id", "note"})
	b := pgCopyFixture(200, 120, []string{"note", "id"}, []string{"id", "note"})
	for _, e := range []*tableedit.AdvancedEvidence{a.AdvancedEvidence, b.AdvancedEvidence} {
		delete(e.Facts, "120")
		e.Targets = e.Targets[:1]
		for key := range e.Rows {
			if len(key) > 4 && key[:4] == "120/" {
				delete(e.Rows, key)
			}
		}
	}
	if pgAdvancedCopyPreservationError(a, b, map[string][]string{"100": {"note", "id"}}, map[string]bool{"100": true}) == nil {
		t.Fatal("accepted two partial connected-graph captures")
	}
}

func TestAdvancedCopyPreservationConstraintCloneOrigin(t *testing.T) {
	makePair := func() (tableedit.Baseline, tableedit.Baseline) {
		a, b := pgCopyPartitionTriggerFixture(170000)
		for _, x := range []struct {
			b                   *tableedit.Baseline
			root, newConstraint int
		}{{&a, 100, 131}, {&b, 200, 331}} {
			e, id := x.b.AdvancedEvidence, strconv.Itoa(x.root)
			p := e.Rows[id+"/constraints"][0]
			p["contype"], p["conindid"], p["conbin"] = "u", x.root+10, nil
			c := e.Rows["120/constraints"][0]
			c["oid"], c["contype"], c["conindid"], c["conparentid"], c["conbin"], c["conislocal"], c["coninhcount"] = x.newConstraint, "u", 130, x.root+11, nil, false, 1
			e.Rows["120/comments"][1]["objoid"] = x.newConstraint
			e.Rows["120/dependencies"][2]["objid"] = strconv.Itoa(x.newConstraint)
		}
		return a, b
	}
	a, b := makePair()
	orders := map[string][]string{"100": {"note", "id"}, "120": {"id", "note"}}
	if err := pgAdvancedCopyPreservationError(a, b, orders, map[string]bool{"100": true}); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"conparentid", "conrelid", "conkey", "conislocal", "coninhcount", "connoinherit"} {
		t.Run(key, func(t *testing.T) {
			a, b := makePair()
			b.AdvancedEvidence.Rows["120/constraints"][0][key] = "forged"
			if pgAdvancedCopyPreservationError(a, b, orders, map[string]bool{"100": true}) == nil {
				t.Fatal("accepted changed cloned constraint origin")
			}
		})
	}
	a, b = makePair()
	a.AdvancedEvidence.Rows["120/constraints"][0]["conislocal"] = true
	b.AdvancedEvidence.Rows["120/constraints"][0]["conislocal"] = true
	if pgAdvancedCopyPreservationError(a, b, orders, map[string]bool{"100": true}) == nil {
		t.Fatal("treated an unproven local constraint as a native clone")
	}
}

func pgCopyAddExtras(a, b *tableedit.Baseline) {
	for _, x := range []struct {
		b   *tableedit.Baseline
		oid int
	}{{a, 100}, {b, 200}} {
		e, id := x.b.AdvancedEvidence, strconv.Itoa(x.oid)
		e.Rows[id+"/comments"] = append(e.Rows[id+"/comments"], map[string]any{"classoid": 1247, "objoid": x.oid + 2, "objsubid": 0, "description": "retained row-array"}, map[string]any{"classoid": 1259, "objoid": x.oid + 17, "objsubid": 1, "description": "retained toast index term"})
		e.Rows[id+"/labels"] = append(e.Rows[id+"/labels"], map[string]any{"classoid": 1247, "objoid": x.oid + 2, "objsubid": 0, "provider": "fixture", "label": "retained array label"}, map[string]any{"classoid": 1259, "objoid": x.oid + 17, "objsubid": 2, "provider": "fixture", "label": "retained toast index label"})
		e.Rows[id+"/dependencies"] = append(e.Rows[id+"/dependencies"], pgCopyDep("1247", x.oid+2, 0, "1247", x.oid+1, 0, "i"), pgCopyDep("1259", x.oid+16, 0, "1259", x.oid, 0, "i"), pgCopyDep("1259", x.oid+17, 0, "1259", x.oid+16, 1, "a"), pgCopyDep("1259", x.oid+10, 1, "1259", x.oid+17, 2, "n"))
	}
}

func TestAdvancedCopyPreservationNativeExtraAddresses(t *testing.T) {
	a := pgCopyFixture(100, 120, []string{"id", "note"}, []string{"id", "note"})
	b := pgCopyFixture(200, 120, []string{"note", "id"}, []string{"id", "note"})
	pgCopyAddExtras(&a, &b)
	a.AdvancedEvidence.Rows["100/indexAttributes"][0]["attoptions"] = []any{"pg_attver=100", "n_distinct=0.5"}
	b.AdvancedEvidence.Rows["200/indexAttributes"][0]["attoptions"] = []any{"pg_attver=200", "n_distinct=0.5"}
	if err := pgAdvancedCopyPreservationError(a, b, map[string][]string{"100": {"note", "id"}, "120": {"id", "note"}}, map[string]bool{"100": true}); err != nil {
		t.Fatal(err)
	}
	if a.AdvancedEvidence.Rows["100/indexAttributes"][0]["attnum"] != 1 || b.AdvancedEvidence.Rows["200/indexAttributes"][0]["attnum"] != 1 {
		t.Fatal("an index term ordinal was treated as a table attribute position")
	}
}

func TestAdvancedCopyPreservationNativeExtraDrift(t *testing.T) {
	mutations := map[string]func(*tableedit.Baseline){
		"missing category": func(b *tableedit.Baseline) { delete(b.AdvancedEvidence.Rows, "200/indexAttributes") },
		"missing index term": func(b *tableedit.Baseline) {
			b.AdvancedEvidence.Rows["200/indexAttributes"] = b.AdvancedEvidence.Rows["200/indexAttributes"][:2]
		},
		"stray index":    func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/indexAttributes"][0]["attrelid"] = 999 },
		"table as index": func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/indexAttributes"][0]["attrelid"] = 200 },
		"term ordinal":   func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/indexAttributes"][0]["attnum"] = 2 },
		"duplicate term": func(b *tableedit.Baseline) {
			b.AdvancedEvidence.Rows["200/indexAttributes"] = append(b.AdvancedEvidence.Rows["200/indexAttributes"], pgCopyIndexAttribute(210, 1, 23))
		},
		"statistics":   func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/indexAttributes"][0]["attstattarget"] = 322 },
		"storage":      func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/indexAttributes"][0]["attstorage"] = "x" },
		"compression":  func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/indexAttributes"][0]["attcompression"] = "p" },
		"type":         func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/indexAttributes"][0]["atttypid"] = 20 },
		"collation":    func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/indexAttributes"][0]["attcollation"] = 100 },
		"missing flag": func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/indexAttributes"][0]["atthasmissing"] = true },
		"missing datum": func(b *tableedit.Baseline) {
			b.AdvancedEvidence.Rows["200/indexAttributes"][0]["attmissingval"] = []any{1}
		},
		"unknown attribute field": func(b *tableedit.Baseline) {
			b.AdvancedEvidence.Rows["200/indexAttributes"][0]["future_property"] = true
		},
		"genuine option": func(b *tableedit.Baseline) {
			b.AdvancedEvidence.Rows["200/indexAttributes"][0]["attoptions"] = []any{"n_distinct=0.7"}
		},
		"malformed layout option": func(b *tableedit.Baseline) {
			b.AdvancedEvidence.Rows["200/indexAttributes"][0]["attoptions"] = []any{"pg_attver=not-native"}
		},
		"retained index layout": func(b *tableedit.Baseline) {
			b.AdvancedEvidence.Rows["120/indexAttributes"][0]["attoptions"] = []any{"pg_attver=200"}
		},
		"array comment":               func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/comments"][2]["description"] = "changed" },
		"array comment catalog":       func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/comments"][2]["classoid"] = 1259 },
		"array label":                 func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/labels"][1]["label"] = "changed" },
		"array label address":         func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/labels"][1]["objoid"] = 121 },
		"toast index comment ordinal": func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/comments"][3]["objsubid"] = 2 },
		"toast index label":           func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/labels"][2]["label"] = "changed" },
		"toast dependency":            func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/dependencies"][8]["deptype"] = "n" },
		"index dependency address":    func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/dependencies"][9]["refobjsubid"] = 1 },
		"stray index subaddress":      func(b *tableedit.Baseline) { b.AdvancedEvidence.Rows["200/dependencies"][9]["objsubid"] = 99 },
		"unknown dependency field": func(b *tableedit.Baseline) {
			b.AdvancedEvidence.Rows["200/dependencies"][9]["future_property"] = "retained"
		},
	}
	for name, mutate := range mutations {
		t.Run(name, func(t *testing.T) {
			a := pgCopyFixture(100, 120, []string{"id", "note"}, []string{"id", "note"})
			b := pgCopyFixture(200, 120, []string{"note", "id"}, []string{"id", "note"})
			pgCopyAddExtras(&a, &b)
			mutate(&b)
			if pgAdvancedCopyPreservationError(a, b, map[string][]string{"100": {"note", "id"}, "120": {"id", "note"}}, map[string]bool{"100": true}) == nil {
				t.Fatal("accepted unreviewed native extras drift")
			}
		})
	}
}

func TestAdvancedCopyPreservationGeneratedDependencyRefOrder(t *testing.T) {
	a := pgCopyFixture(100, 120, []string{"id", "note"}, []string{"id", "note"})
	b := pgCopyFixture(200, 120, []string{"note", "id"}, []string{"id", "note"})
	base, self := sc.Ref{Kind: "column", Schema: "exact_schema", Table: "parent", Name: "id"}, sc.Ref{Kind: "column", Schema: "exact_schema", Table: "parent", Name: "note"}
	set := func(b *tableedit.Baseline, refs []sc.Ref) {
		for i := range b.AdvancedEvidence.Facts[b.Identity].Table.Columns.Items {
			c := &b.AdvancedEvidence.Facts[b.Identity].Table.Columns.Items[i]
			if c.Ref.Name == "note" {
				c.Generated = sc.Known(sc.Generated{Kind: "stored", Expression: &sc.Expression{Text: "id+1", Dependencies: sc.Complete(refs)}})
			}
		}
	}
	set(&a, []sc.Ref{base, self, self})
	set(&b, []sc.Ref{self, base, self})
	orders := map[string][]string{"100": {"note", "id"}, "120": {"id", "note"}}
	if err := pgAdvancedCopyPreservationError(a, b, orders, map[string]bool{"100": true}); err != nil {
		t.Fatal(err)
	}
	set(&b, []sc.Ref{self, base})
	if pgAdvancedCopyPreservationError(a, b, orders, map[string]bool{"100": true}) == nil {
		t.Fatal("lost generated dependency multiplicity")
	}
	self.Schema = "other"
	set(&b, []sc.Ref{base, self, self})
	if pgAdvancedCopyPreservationError(a, b, orders, map[string]bool{"100": true}) == nil {
		t.Fatal("rewrote a qualified generated dependency reference")
	}
}
