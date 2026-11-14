package mariadb

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestMariaDBNormalStructureModifyPreservesNativeColumnPropertiesLive(t *testing.T) {
	c := dataIntegrationSettings(t)
	if os.Getenv("DBEER_TEST_MARIADB_ADMIN_USER") == "" {
		t.Skip("native complete metadata actor not configured")
	}
	c.User = os.Getenv("DBEER_TEST_MARIADB_ADMIN_USER")
	c.Password = os.Getenv("DBEER_TEST_MARIADB_ADMIN_PASSWORD")
	opened, e := Open(context.Background(), c)
	if e != nil {
		t.Fatal("cannot open native metadata actor")
	}
	s := opened.(*Session)
	defer s.Close()
	name := fmt.Sprintf("g1_modify_%d", time.Now().UnixNano())
	q := QuoteIdentifier(c.Database) + "." + QuoteIdentifier(name)
	dataRun(t, s, "CREATE TABLE "+q+"(id INT NOT NULL COMMENT 'native', v VARCHAR(20) NULL DEFAULT NULL COMMENT 'retained', kept_value VARCHAR(20) DEFAULT 'NULL', required_value VARCHAR(20) NULL DEFAULT NULL, opaque VARBINARY(5) DEFAULT 0xff, base_value INT DEFAULT 7, generated_value INT GENERATED ALWAYS AS(base_value*2) STORED, KEY kept(kept_value(5)) COMMENT 'kept') ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='exact table'")
	defer dataRun(t, s, "DROP TABLE IF EXISTS "+q)
	dataRun(t, s, "INSERT INTO "+q+"(id,v,required_value) VALUES(1,'','first'),(2,'NULL','second'),(3,NULL,'third')")
	before := dataRun(t, s, "SELECT id,v,required_value,HEX(opaque),generated_value FROM "+q+" ORDER BY id").Rows
	var store tableedit.Store
	target := tableedit.Target{Schema: c.Database, Table: name}
	run := func(change tableedit.ColumnChange) {
		t.Helper()
		b, e := store.Load(context.Background(), s, target)
		if e != nil {
			t.Fatal("native MODIFY load failed")
		}
		p, e := store.PreviewContext(context.Background(), s, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 2, Changes: []tableedit.ColumnChange{change}})
		if e != nil || p.Plan == nil {
			t.Logf("metadata proof=%t globalDependencies=%d selectedDependencies=%d", b.Baseline.Facts.Proof, len(b.Baseline.Facts.Dependents[""]), len(b.Baseline.Facts.Dependents[change.Name]))
			for _, reason := range b.Baseline.Facts.Dependents[""] {
				t.Logf("metadata reason unavailable=%t visibility=%t viewInventory=%t", reason == "Fresh authenticated global dependency metadata is incomplete or unavailable.", strings.HasPrefix(reason, "Global static dependency visibility"), strings.HasPrefix(reason, "Native view definitions"))
			}
			t.Fatalf("native MODIFY preview failed: %s", e.Error())
		}
		if len(p.Plan.SQL) != 1 || !strings.Contains(p.Plan.SQL[0], " MODIFY COLUMN ") {
			t.Fatal("native full column definition is not displayed")
		}
		r, e := store.Apply(context.Background(), s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: tableedit.Token()})
		if e != nil || r.Outcome == nil || r.Outcome.State != "applied" {
			t.Fatalf("native MODIFY apply failed: %T", e)
		}
		for _, step := range r.Outcome.Steps {
			if step.Message != "" {
				t.Fatal("native MODIFY complete postproof refused: " + step.Message)
			}
		}
	}
	run(tableedit.ColumnChange{Name: "id", Type: &tableedit.DataType{Kind: "bigint"}})
	run(tableedit.ColumnChange{Name: "v", Type: &tableedit.DataType{Kind: "varchar", Length: 50}})
	required := false
	optional := true
	run(tableedit.ColumnChange{Name: "required_value", Nullable: &required})
	run(tableedit.ColumnChange{Name: "required_value", Nullable: &optional})
	after := dataRun(t, s, "SELECT id,v,required_value,HEX(opaque),generated_value FROM "+q+" ORDER BY id").Rows
	if !reflect.DeepEqual(before, after) {
		t.Fatal("native MODIFY changed exact retained row values")
	}
	// Requiring a column that actually contains NULL must refuse without native
	// coercion or successful acknowledgement; both native settings and rows remain.
	b, e := store.Load(context.Background(), s, target)
	if e != nil {
		t.Fatal("negative native MODIFY load failed")
	}
	p, e := store.PreviewContext(context.Background(), s, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 2, Changes: []tableedit.ColumnChange{{Name: "v", Nullable: &required}}})
	if e != nil {
		t.Fatal("native NULL validation preview failed")
	}
	result, e := store.Apply(context.Background(), s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: tableedit.Token()})
	if e != nil || result.Outcome == nil || result.Outcome.State == "applied" {
		t.Fatal("native NULL validation coerced a retained NULL")
	}
	if !reflect.DeepEqual(before, dataRun(t, s, "SELECT id,v,required_value,HEX(opaque),generated_value FROM "+q+" ORDER BY id").Rows) {
		t.Fatal("failed native required-column change modified data")
	}
}
