package mariadb

import (
	"context"
	"fmt"
	"reflect"
	"testing"
	"time"

	"dbeer/helper/internal/tableedit"
)

func TestMariaDBOwnedTriggerRowsNativeLive(t *testing.T) {
	for _, mode := range []string{"unchanged", "sameNameBodyDrift", "rename"} {
		t.Run(mode, func(t *testing.T) {
			owner, other := schemaNativeAdmin(t), schemaNativeAdmin(t)
			schema := dataIntegrationSettings(t).Database
			name := fmt.Sprintf("data_trigger_%d_%d", owner.connectionID, time.Now().UnixNano())
			newName := name + "_renamed"
			trigger := name + "_trigger"
			qualified := func(n string) string { return QuoteIdentifier(schema) + "." + QuoteIdentifier(n) }
			dataRun(t, other, "CREATE TABLE "+qualified(name)+"(id INT,n INT) ENGINE=InnoDB")
			t.Cleanup(func() {
				dataRun(t, other, "DROP TABLE IF EXISTS "+qualified(name))
				dataRun(t, other, "DROP TABLE IF EXISTS "+qualified(newName))
			})
			makeTrigger := func(value string) {
				dataRun(t, other, "CREATE TRIGGER "+qualified(trigger)+" BEFORE INSERT ON "+qualified(name)+" FOR EACH ROW SET NEW.n="+value)
			}
			makeTrigger("1")
			dataRun(t, other, "INSERT INTO "+qualified(name)+" VALUES(1,9),(2,NULL)")
			target := tableedit.Target{Schema: schema, Table: name}
			var store tableedit.Store
			loaded, e := store.Load(context.Background(), owner, target)
			if e != nil || loaded.Baseline == nil || !loaded.Baseline.DependencyProof {
				t.Fatal("complete owned-trigger baseline unavailable")
			}
			option := func(b tableedit.Baseline) string {
				for _, v := range b.Facts.EngineContext {
					if v.Name == "ownedTriggerRowsDigest" {
						return v.Value
					}
				}
				return ""
			}
			beforeDigest := option(*loaded.Baseline)
			if beforeDigest == "" {
				t.Fatal("owned native trigger digest absent")
			}
			draft := tableedit.Draft{Columns: []tableedit.Column{{Name: "reviewed", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "none"}}}}
			if mode == "rename" {
				draft = tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, RenameTable: &newName}
			}
			preview, e := store.PreviewContext(context.Background(), owner, loaded.Baseline.ID, draft)
			if mode == "rename" {
				// The existing editor guards trigger-bearing renames. A fixture-only
				// native rename proves the digest's sole address exception independently.
				if e == nil {
					t.Fatal("existing trigger rename client boundary disappeared")
				}
				dataRun(t, other, "RENAME TABLE "+qualified(name)+" TO "+qualified(newName))
				target.Table = newName
				fresh, err := other.StructureLoad(context.Background(), target)
				if err != nil || option(fresh) != beforeDigest {
					t.Fatal("native rename changed more than the bound owning-table address")
				}
				return
			}
			if e != nil || preview.Plan == nil {
				t.Fatal("owned-trigger reviewed preview unavailable")
			}
			if mode == "sameNameBodyDrift" {
				dataRun(t, other, "DROP TRIGGER "+qualified(trigger))
				makeTrigger("2")
				fresh, e := other.StructureLoad(context.Background(), target)
				if e != nil || option(fresh) == beforeDigest || !reflect.DeepEqual(fresh.Facts.Dependents, loaded.Baseline.Facts.Dependents) {
					t.Fatal("same-name body control did not isolate retained dependent-name drift")
				}
			}
			applied, e := store.Apply(context.Background(), owner, tableedit.Apply{ExecutionID: tableedit.Token(), PlanID: preview.Plan.ID, Digest: preview.Plan.Digest})
			if mode == "sameNameBodyDrift" {
				if e == nil && (applied.Outcome == nil || applied.Outcome.State == "applied") {
					t.Fatal("same-name trigger body drift retained stale DDL authority")
				}
				fresh, e := other.StructureLoad(context.Background(), target)
				if e != nil || len(fresh.Columns) != 2 {
					t.Fatal("stale trigger drift dispatched column DDL")
				}
			} else {
				if e != nil || applied.Outcome == nil || applied.Outcome.State != "applied" {
					t.Fatal("unchanged owned-trigger operation lost exact preservation")
				}
				for _, step := range applied.Outcome.Steps {
					if step.State != "applied" || step.Message != "" {
						t.Fatal("native trigger preservation postproof incomplete")
					}
				}
				if mode == "rename" {
					target.Table = newName
				}
				fresh, e := other.StructureLoad(context.Background(), target)
				if e != nil || option(fresh) != beforeDigest {
					t.Fatal("only owning table address changed native trigger digest")
				}
			}
			rows := dataRun(t, other, "SELECT id,n FROM "+qualified(target.Table)+" ORDER BY id").Rows
			if len(rows) != 2 || rows[0][1] == nil || *rows[0][1] != "1" || rows[1][1] == nil || *rows[1][1] != "1" {
				t.Fatal("metadata-only trigger observations changed stored rows")
			}
		})
	}
}
