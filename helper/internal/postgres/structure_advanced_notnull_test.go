package postgres

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"reflect"
	"strings"
	"testing"
)

func TestStructureAdvancedNotNullNativeDependenciesLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	for _, kind := range []string{"rls", "inheritance", "partition", "typed"} {
		t.Run(kind, func(t *testing.T) {
			name := "notnull_" + kind
			if kind == "typed" {
				f.exec("CREATE TYPE " + f.table(name+"_type") + " AS(id integer,payload text)")
				f.exec("CREATE TABLE " + f.table(name) + " OF " + f.table(name+"_type"))
			} else {
				tail := ""
				if kind == "partition" {
					tail = " PARTITION BY RANGE(id)"
				}
				f.exec("CREATE TABLE " + f.table(name) + "(id integer,payload text)" + tail)
			}
			if kind == "rls" {
				f.exec("ALTER TABLE " + f.table(name) + " ENABLE ROW LEVEL SECURITY")
			}
			if kind == "inheritance" {
				f.exec("CREATE TABLE " + f.table(name+"_child") + "() INHERITS(" + f.table(name) + ")")
			}
			if kind == "partition" {
				f.exec("CREATE TABLE " + f.table(name+"_child") + " PARTITION OF " + f.table(name) + " FOR VALUES FROM(0) TO(100)")
			}
			f.exec("INSERT INTO " + f.table(name) + " VALUES(1,'retained')")
			target := tableedit.Target{Schema: f.schema, Table: name}
			before, err := readStructure(ctx, f.conn, target)
			if err != nil {
				t.Fatal(err)
			}
			tx, err := f.conn.Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer structureRollback(tx)
			if _, err = tx.Exec(ctx, "ALTER TABLE "+f.table(name)+" ALTER COLUMN payload SET NOT NULL"); err != nil {
				t.Fatal("native NOT NULL failed")
			}
			after, err := readStructure(ctx, tx, target)
			if err != nil {
				t.Fatal(err)
			}
			required := false
			c := tableedit.Condition{Operation: tableedit.Operation{Kind: "changeColumn", Change: &tableedit.ColumnChange{Name: "payload", Nullable: &required}}}
			if err = pgAdvancedPreservationError(before, after, c); err != nil {
				t.Fatal(err)
			}
			if reflect.DeepEqual(before.AdvancedEvidence, after.AdvancedEvidence) {
				t.Fatal("native fixture did not change metadata")
			}
			mutations := 0
			for key, rows := range after.AdvancedEvidence.Rows {
				if !strings.HasSuffix(key, "/constraints") {
					continue
				}
				prefix := strings.TrimSuffix(key, "constraints")
				for _, row := range rows {
					if row["contype"] != "n" {
						continue
					}
					id := pgPhysicalOID(row["oid"])
					for _, kind := range []string{"constraint", "unknown", "inheritance", "missing", "duplicate", "external", "incoming"} {
						changed := after
						changed.AdvancedEvidence = tableedit.CloneAdvancedEvidence(after.AdvancedEvidence)
						if kind == "constraint" || kind == "unknown" || kind == "inheritance" {
							for _, constraint := range changed.AdvancedEvidence.Rows[key] {
								if pgPhysicalOID(constraint["oid"]) == id {
									switch kind {
									case "constraint":
										constraint["convalidated"] = false
									case "unknown":
										constraint["unmodeled"] = true
									case "inheritance":
										constraint["coninhcount"] = float64(99)
									}
								}
							}
						} else {
							edges := []map[string]any{}
							for _, edge := range changed.AdvancedEvidence.Rows[prefix+"dependencies"] {
								owned := edge["classid"] == "2606" && pgPhysicalOID(edge["objid"]) == id
								if owned && kind == "missing" {
									continue
								}
								edges = append(edges, edge)
								if owned && kind == "duplicate" {
									edges = append(edges, pgPhysicalCopy(edge))
								}
								if owned && kind == "external" {
									extra := pgPhysicalCopy(edge)
									extra["refobjid"] = "999999"
									edges = append(edges, extra)
								}
								if owned && kind == "incoming" {
									extra := pgPhysicalCopy(edge)
									extra["classid"], extra["objid"], extra["refclassid"], extra["refobjid"] = "1259", "999999", "2606", id
									edges = append(edges, extra)
								}
							}
							changed.AdvancedEvidence.Rows[prefix+"dependencies"] = edges
						}
						if pgAdvancedPreservationError(before, changed, c) == nil {
							t.Fatalf("unreviewed native NOT NULL %s mutation was admitted", kind)
						}
						mutations++
					}
				}
			}
			if before.Facts.ServerVersion >= 180000 && mutations == 0 {
				t.Fatal("PostgreSQL18 native constraint/dependency negatives were vacuous")
			}
			if _, err = tx.Exec(ctx, "ALTER TABLE "+f.table(name)+" ALTER COLUMN payload DROP NOT NULL"); err != nil {
				t.Fatal("native DROP NOT NULL failed")
			}
			dropped, err := readStructure(ctx, tx, target)
			if err != nil {
				t.Fatal(err)
			}
			optional := true
			drop := tableedit.Condition{Operation: tableedit.Operation{Kind: "changeColumn", Change: &tableedit.ColumnChange{Name: "payload", Nullable: &optional}}}
			if err = pgAdvancedPreservationError(after, dropped, drop); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestStructureAdvancedNotNullWidenDependenciesLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	for _, kind := range []string{"rls", "inheritance", "partition"} {
		t.Run(kind, func(t *testing.T) {
			name := "notnull_widen_" + kind
			tail := ""
			if kind == "partition" {
				tail = " PARTITION BY RANGE(id)"
			}
			f.exec("CREATE TABLE " + f.table(name) + "(id integer,payload integer NOT NULL)" + tail)
			if kind == "rls" {
				f.exec("ALTER TABLE " + f.table(name) + " ENABLE ROW LEVEL SECURITY")
			}
			if kind == "inheritance" {
				f.exec("CREATE TABLE " + f.table(name+"_child") + "() INHERITS(" + f.table(name) + ")")
			}
			if kind == "partition" {
				f.exec("CREATE TABLE " + f.table(name+"_child") + " PARTITION OF " + f.table(name) + " FOR VALUES FROM(0) TO(100)")
			}
			f.exec("INSERT INTO " + f.table(name) + " VALUES(1,7)")
			target := tableedit.Target{Schema: f.schema, Table: name}
			before, err := readStructure(ctx, f.conn, target)
			if err != nil {
				t.Fatal(err)
			}
			tx, err := f.conn.Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer structureRollback(tx)
			if _, err = tx.Exec(ctx, "ALTER TABLE "+f.table(name)+" ALTER COLUMN payload TYPE bigint"); err != nil {
				t.Fatal("native widening failed")
			}
			after, err := readStructure(ctx, tx, target)
			if err != nil {
				t.Fatal(err)
			}
			c := tableedit.Condition{Operation: tableedit.Operation{Kind: "changeColumn", Change: &tableedit.ColumnChange{Name: "payload", Type: &tableedit.DataType{Kind: "bigint"}}}}
			if err = pgAdvancedPreservationError(before, after, c); err != nil {
				t.Fatal(err)
			}
			mutations := 0
			for key, rows := range after.AdvancedEvidence.Rows {
				if !strings.HasSuffix(key, "/constraints") {
					continue
				}
				prefix := strings.TrimSuffix(key, "constraints")
				for _, row := range rows {
					if row["contype"] != "n" || !pgAdvancedConstraintColumns(row, after.AdvancedEvidence.Rows[prefix+"attributes"], []string{"payload"}) {
						continue
					}
					id := pgPhysicalOID(row["oid"])
					for _, kind := range []string{"name", "unknown", "missing", "duplicate", "external", "incoming"} {
						changed := after
						changed.AdvancedEvidence = tableedit.CloneAdvancedEvidence(after.AdvancedEvidence)
						if kind == "name" || kind == "unknown" {
							for _, r := range changed.AdvancedEvidence.Rows[key] {
								if pgPhysicalOID(r["oid"]) == id {
									if kind == "name" {
										r["conname"] = "changed_native_name"
									} else {
										r["unmodeled"] = true
									}
								}
							}
						} else {
							edges := []map[string]any{}
							for _, edge := range changed.AdvancedEvidence.Rows[prefix+"dependencies"] {
								owned := edge["classid"] == "2606" && pgPhysicalOID(edge["objid"]) == id
								if owned && kind == "missing" {
									continue
								}
								edges = append(edges, edge)
								if owned && kind == "duplicate" {
									edges = append(edges, pgPhysicalCopy(edge))
								}
								if owned && kind == "external" {
									extra := pgPhysicalCopy(edge)
									extra["refobjid"] = "999999"
									edges = append(edges, extra)
								}
								if owned && kind == "incoming" {
									extra := pgPhysicalCopy(edge)
									extra["classid"], extra["objid"], extra["refclassid"], extra["refobjid"] = "1259", "999999", "2606", id
									edges = append(edges, extra)
								}
							}
							changed.AdvancedEvidence.Rows[prefix+"dependencies"] = edges
						}
						if pgAdvancedPreservationError(before, changed, c) == nil {
							t.Fatalf("unreviewed widening NOT NULL %s mutation admitted", kind)
						}
						mutations++
					}
				}
			}
			if before.Facts.ServerVersion >= 180000 && mutations == 0 {
				t.Fatal("native widening constraint/dependency negatives were vacuous")
			}
			var value string
			if tx.QueryRow(ctx, "SELECT payload::pg_catalog.text FROM "+f.table(name)).Scan(&value) != nil || value != "7" {
				t.Fatal("native widening did not retain value")
			}
		})
	}
}
