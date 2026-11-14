package mysql

import (
	"context"
	"fmt"
	"io"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/tableedit"
)

// Production Store integration: admission comes from the normal Session.
type myAdvancedStoreFixture struct {
	s, observer *Session
	a           *Session
	target      tableedit.Target
	table       string
}

const myAdvancedStoreMode = "STRICT_ALL_TABLES,NO_ENGINE_SUBSTITUTION,NO_AUTO_VALUE_ON_ZERO"
const myAdvancedStoreCounter = "9007199254741999"

func newMyAdvancedStoreFixture(t *testing.T, kind string) myAdvancedStoreFixture {
	t.Helper()
	if os.Getenv("DBEER_TEST_MYSQL_STRUCTURE_PRIVILEGES") != "1" {
		t.Skip("requires isolated structure privilege fixture")
	}
	s, observer := integrationSession(t), integrationSession(t)
	for _, session := range []*Session{s, observer} {
		run(t, session, "SET SESSION sql_mode='"+myAdvancedStoreMode+"'")
		run(t, session, "SET SESSION time_zone='+00:00'")
	}
	target := tableedit.Target{Schema: integrationSettings(t).Database, Table: fmt.Sprintf("e7_store_%d", time.Now().UnixNano())}
	table := QuoteIdentifier(target.Schema) + "." + QuoteIdentifier(target.Table)
	suffix := " ENGINE=MyISAM ROW_FORMAT=DYNAMIC COMMENT='retained table'"
	if kind == "Partitions" {
		suffix = " ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='retained table' PARTITION BY RANGE(id)(PARTITION p0 VALUES LESS THAN(100) COMMENT 'retained lower',PARTITION p1 VALUES LESS THAN MAXVALUE COMMENT 'retained upper')"
	}
	run(t, observer, "CREATE TABLE "+table+"(id bigint unsigned NOT NULL AUTO_INCREMENT,payload varchar(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin COMMENT 'retained column',n decimal(30,4),b varbinary(4),base int,g int GENERATED ALWAYS AS(base*2) STORED COMMENT 'retained stored',v int GENERATED ALWAYS AS(base+1) VIRTUAL COMMENT 'retained virtual',ts timestamp(6) NULL,KEY retained_id(id),KEY retained_idx(n))"+suffix)
	t.Cleanup(func() { run(t, observer, "DROP TABLE IF EXISTS "+table) })
	// The nonunique AUTO_INCREMENT key deliberately permits duplicate whole rows.
	run(t, observer, "INSERT INTO "+table+"(id,payload,n,b,base,ts) VALUES(0,'',12345678901234567890.1234,0x00ff,3,'2024-11-03 05:30:00.123456'),(101,'NULL',NULL,X'',4,'2024-11-03 06:30:00.123456'),(101,'NULL',NULL,X'',4,'2024-11-03 06:30:00.123456'),(102,NULL,-12345678901234567890.1234,NULL,NULL,NULL)")
	run(t, observer, "ALTER TABLE "+table+" AUTO_INCREMENT="+myAdvancedStoreCounter)
	return myAdvancedStoreFixture{s: s, observer: observer, a: s, target: target, table: table}
}

func (f myAdvancedStoreFixture) preview(t *testing.T, draft tableedit.Draft) (*tableedit.Store, *tableedit.Plan) {
	t.Helper()
	store := &tableedit.Store{}
	loaded, err := store.Load(context.Background(), f.a, f.target)
	if err != nil || loaded.Baseline == nil || loaded.Baseline.Advanced == nil {
		t.Fatal("advanced Store load failed")
	}
	preview, err := store.PreviewContext(context.Background(), f.a, loaded.Baseline.ID, draft)
	if err != nil {
		t.Fatalf("production Store preview failed: %v", err)
	}
	return store, preview.Plan
}

func (f myAdvancedStoreFixture) apply(t *testing.T, draft tableedit.Draft) *tableedit.Outcome {
	t.Helper()
	store, plan := f.preview(t, draft)
	out, err := store.Apply(context.Background(), f.a, tableedit.Apply{PlanID: plan.ID, Digest: plan.Digest, ExecutionID: tableedit.Token()})
	if err != nil || out.Outcome == nil || out.Outcome.State != "applied" || out.Outcome.Observed == nil {
		t.Fatal("production Store apply was not acknowledged and observed")
	}
	for _, step := range out.Outcome.Steps {
		if step.State != "applied" || step.Message != "" {
			t.Fatalf("production Store preservation failed: state=%s message=%s", step.State, step.Message)
		}
	}
	return out.Outcome
}

func (f myAdvancedStoreFixture) values(t *testing.T) [][]*string {
	t.Helper()
	return run(t, f.observer, "SELECT id,payload,CAST(n AS CHAR),HEX(b),base,g,v,UNIX_TIMESTAMP(ts) FROM "+f.table+" ORDER BY id,payload").Rows
}

func (f myAdvancedStoreFixture) counter(t *testing.T) string {
	t.Helper()
	r := run(t, f.observer, "SELECT CAST(AUTO_INCREMENT AS CHAR) FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=BINARY '"+f.target.Schema+"' AND BINARY TABLE_NAME=BINARY '"+f.target.Table+"'")
	if len(r.Rows) != 1 || len(r.Rows[0]) != 1 || r.Rows[0][0] == nil {
		t.Fatal("native AUTO_INCREMENT counter unavailable")
	}
	return *r.Rows[0][0]
}

func myAdvancedStoreBackfill() tableedit.Draft {
	return tableedit.Draft{AuthoringVersion: 5, AllowDestructive: true, Columns: []tableedit.Column{{Name: "required", Type: tableedit.DataType{Kind: "varchar", Length: 40}, Default: tableedit.Default{Kind: "none"}}}, Backfills: []tableedit.Backfill{{Column: "required", Expression: "CONCAT(id,':required')"}}}
}

func myAdvancedStoreRewrite(order ...string) tableedit.Draft {
	return tableedit.Draft{AuthoringVersion: 5, AllowDestructive: true, Columns: []tableedit.Column{}, Reconstruct: true, ColumnOrder: order}
}

func TestStructureAdvancedStoreNativeCopyMySQLLive(t *testing.T) {
	for _, kind := range []string{"MyISAM", "Partitions"} {
		t.Run(kind, func(t *testing.T) {
			f := newMyAdvancedStoreFixture(t, kind)
			before := f.values(t)
			if len(before) != 4 || !reflect.DeepEqual(before[1], before[2]) || before[0][1] == nil || *before[0][1] != "" || before[1][1] == nil || *before[1][1] != "NULL" || before[3][1] != nil || *before[0][2] != "12345678901234567890.1234" || *before[0][3] != "00FF" || *before[1][3] != "" || before[3][3] != nil || f.counter(t) != myAdvancedStoreCounter {
				t.Fatal("native exact-value fixture control failed")
			}
			for _, draft := range []tableedit.Draft{myAdvancedStoreRewrite("payload", "n", "b", "base", "g", "v", "ts", "id"), myAdvancedStoreRewrite()} {
				store, plan := f.preview(t, draft)
				if len(plan.SQL) != 1 || !strings.Contains(plan.SQL[0], "ALGORITHM=COPY") || !strings.Contains(plan.SQL[0], "LOCK=EXCLUSIVE") {
					t.Fatal("native COPY and exclusive lock were not disclosed")
				}
				if len(draft.ColumnOrder) > 0 && (!strings.Contains(plan.SQL[0], " FIRST") || !strings.Contains(plan.SQL[0], " AFTER ")) {
					t.Fatal("complete native column reorder was not disclosed")
				}
				request := tableedit.Apply{PlanID: plan.ID, Digest: plan.Digest, ExecutionID: tableedit.Token()}
				bad := request
				bad.Digest = strings.Repeat("0", 64)
				if _, err := store.Apply(context.Background(), f.a, bad); err == nil {
					t.Fatal("altered digest dispatched a candidate plan")
				}
				out, err := store.Apply(context.Background(), f.a, request)
				if err != nil || out.Outcome.State != "applied" || out.Outcome.Observed == nil || out.Outcome.Steps[0].State != "applied" || out.Outcome.Steps[0].Message != "" {
					t.Fatalf("native Store COPY proof failed: error=%v", err)
				}
				if !reflect.DeepEqual(before, f.values(t)) || f.counter(t) != myAdvancedStoreCounter {
					t.Fatal("native COPY changed exact rows, duplicates, instants or counter")
				}
				if _, err := store.Apply(context.Background(), f.a, request); err == nil {
					t.Fatal("consumed COPY plan was replayed")
				}
			}
		})
	}
}

func TestStructureAdvancedStoreGenerationMySQLLive(t *testing.T) {
	for _, kind := range []string{"MyISAM", "Partitions"} {
		t.Run(kind, func(t *testing.T) {
			f := newMyAdvancedStoreFixture(t, kind)
			for _, selected := range []struct{ name, storage, expression string }{{"g", "stored", "base * 3"}, {"v", "virtual", "base + 2"}} {
				before := f.values(t)
				f.apply(t, tableedit.Draft{AuthoringVersion: 2, AllowDestructive: true, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: selected.name, Generated: &tableedit.Generation{Storage: selected.storage, Expression: selected.expression}}}})
				after := f.values(t)
				index := 5
				if selected.name == "v" {
					index = 6
				}
				for i := range before {
					before[i][index] = after[i][index]
				}
				if !reflect.DeepEqual(before, after) || f.counter(t) != myAdvancedStoreCounter {
					t.Fatal("generation changed an unaffected exact value or counter")
				}
				if *after[0][index] != map[string]string{"g": "9", "v": "5"}[selected.name] || after[3][index] != nil {
					t.Fatal("selected generation did not retain authored semantics")
				}
			}
			before := f.values(t)
			for _, identity := range []string{"none", "autoIncrement"} {
				f.apply(t, tableedit.Draft{AuthoringVersion: 2, AllowDestructive: true, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "id", Identity: &tableedit.Identity{Kind: identity}}}})
				if !reflect.DeepEqual(before, f.values(t)) {
					t.Fatal("identity toggle changed existing zero, duplicate or native values")
				}
			}
		})
	}
}

func TestStructureAdvancedStoreBackfillMySQLLive(t *testing.T) {
	for _, kind := range []string{"MyISAM", "Partitions"} {
		for _, effect := range []string{"apply", "cancel", "unknown", "retained-value-mismatch", "counter-mismatch"} {
			t.Run(kind+"/"+effect, func(t *testing.T) {
				f := newMyAdvancedStoreFixture(t, kind)
				if effect == "retained-value-mismatch" {
					run(t, f.observer, "CREATE TRIGGER "+QuoteIdentifier(f.target.Schema)+"."+QuoteIdentifier(f.target.Table+"_update")+" BEFORE UPDATE ON "+f.table+" FOR EACH ROW SET NEW.payload='changed by retained trigger'")
				}
				before := f.values(t)
				store, plan := f.preview(t, myAdvancedStoreBackfill())
				if len(plan.SQL) != 3 || len(plan.Conditions) != 3 || (plan.Conditions[0].Operation.Column == nil || !plan.Conditions[0].Operation.Column.Nullable) || !strings.HasPrefix(plan.SQL[1], "UPDATE ") || !strings.Contains(plan.SQL[2], "NOT NULL") || plan.Conditions[1].Operation.Kind != "backfill" || plan.Conditions[1].Operation.Name == nil || *plan.Conditions[1].Operation.Name != "required" || !reflect.DeepEqual(before, f.values(t)) {
					t.Fatal("Preview evaluated or hid independent reviewed backfill units")
				}
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				f.s.afterStructureStep = func(i int) {
					if i == 0 && effect == "cancel" {
						cancel()
					}
					if i == 0 && (effect == "unknown" || effect == "counter-mismatch") {
						f.s.structureExecuteOverride = func(execute func() error) error {
							if err := execute(); err != nil {
								return err
							}
							if effect == "unknown" {
								return io.ErrUnexpectedEOF
							}
							r, err := f.s.work.client.Execute("ALTER TABLE " + f.table + " AUTO_INCREMENT=9007199254742001")
							if r != nil {
								r.Close()
							}
							return err
						}
					}
				}
				request := tableedit.Apply{PlanID: plan.ID, Digest: plan.Digest, ExecutionID: tableedit.Token()}
				out, err := store.Apply(ctx, f.a, request)
				f.s.afterStructureStep, f.s.structureExecuteOverride = nil, nil
				if err != nil || out.Outcome == nil || len(out.Outcome.Steps) != 3 || out.Outcome.Steps[0].State != "applied" {
					t.Fatal("backfill lost acknowledged ADD evidence")
				}
				want := map[string]string{"apply": "applied", "cancel": "partiallyApplied", "unknown": "outcomeUnknown", "retained-value-mismatch": "partiallyApplied", "counter-mismatch": "partiallyApplied"}[effect]
				if out.Outcome.State != want {
					t.Fatalf("backfill outcome mismatch: state=%s", out.Outcome.State)
				}
				steps := out.Outcome.Steps
				switch effect {
				case "apply":
					for _, step := range steps {
						if step.State != "applied" || step.Message != "" {
							t.Fatalf("reviewed backfill preservation failed: state=%s message=%s", step.State, step.Message)
						}
					}
				case "cancel":
					if steps[1].State != "notStarted" || steps[2].State != "notStarted" {
						t.Fatal("Stop dispatched a later backfill unit")
					}
				case "unknown":
					if steps[1].State != "unknown" || steps[2].State != "notStarted" || !f.s.closed.Load() || store.Status().Outcome.State != "outcomeUnknown" {
						t.Fatal("lost UPDATE acknowledgement was retried or claimed rolled back")
					}
				default:
					if steps[1].State != "applied" || steps[1].Message == "" || steps[2].State != "notStarted" {
						t.Fatal("acknowledged preservation mismatch lost its durable prefix")
					}
				}
				if effect != "retained-value-mismatch" && !reflect.DeepEqual(before, f.values(t)) {
					t.Fatal("backfill changed unaffected exact values")
				}
				rows := run(t, f.observer, "SELECT COUNT(*),COUNT(required) FROM "+f.table).Rows
				filled := "4"
				if effect == "cancel" {
					filled = "0"
				}
				if *rows[0][0] != "4" || *rows[0][1] != filled {
					t.Fatal("durable backfill units do not match the acknowledgement evidence")
				}
				selected := run(t, f.observer, "SELECT required FROM "+f.table+" ORDER BY id,payload").Rows
				for i, expected := range []string{"0:required", "101:required", "101:required", "102:required"} {
					if effect == "cancel" {
						if selected[i][0] != nil {
							t.Fatal("unstarted UPDATE populated the selected column")
						}
					} else if selected[i][0] == nil || *selected[i][0] != expected {
						t.Fatal("acknowledged UPDATE did not preserve exact authored selected values")
					}
				}
				if effect != "counter-mismatch" && f.counter(t) != myAdvancedStoreCounter {
					t.Fatal("backfill changed an unaffected exact counter")
				}
				if _, err := store.Apply(context.Background(), f.a, request); err == nil {
					t.Fatal("retired backfill plan was replayed")
				}
			})
		}
	}
}

func TestStructureAdvancedStoreStaleMySQLLive(t *testing.T) {
	for _, kind := range []string{"MyISAM", "Partitions"} {
		for _, drift := range []string{"sql-mode", "table-suffix", "column-property", "generation", "partitions"} {
			if kind == "MyISAM" && drift == "partitions" {
				continue
			}
			t.Run(kind+"/"+drift, func(t *testing.T) {
				f := newMyAdvancedStoreFixture(t, kind)
				store, plan := f.preview(t, myAdvancedStoreRewrite())
				sql := map[string]string{
					"sql-mode":        "SET SESSION sql_mode='STRICT_ALL_TABLES,NO_ENGINE_SUBSTITUTION'",
					"table-suffix":    "ALTER TABLE " + f.table + " COMMENT='changed suffix'",
					"column-property": "ALTER TABLE " + f.table + " MODIFY payload varchar(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin COMMENT 'changed column'",
					"generation":      "ALTER TABLE " + f.table + " MODIFY g int GENERATED ALWAYS AS(base*4) STORED COMMENT 'retained stored'",
					"partitions":      "ALTER TABLE " + f.table + " REORGANIZE PARTITION p0 INTO(PARTITION p0 VALUES LESS THAN(100) COMMENT 'changed partition')",
				}[drift]
				run(t, f.s, sql)
				dispatched := false
				f.s.structureExecuteOverride = func(execute func() error) error { dispatched = true; return execute() }
				out, err := store.Apply(context.Background(), f.a, tableedit.Apply{PlanID: plan.ID, Digest: plan.Digest, ExecutionID: tableedit.Token()})
				f.s.structureExecuteOverride = nil
				if err != nil || dispatched || out.Outcome.State != "failed" || out.Outcome.Steps[0].State != "notStarted" {
					t.Fatal("late captured native/context drift dispatched candidate DDL")
				}
			})
		}
	}
}

func TestStructureAdvancedStoreAdmissionMySQLLive(t *testing.T) {
	for _, kind := range []string{"MyISAM", "Partitions"} {
		t.Run(kind, func(t *testing.T) {
			f := newMyAdvancedStoreFixture(t, kind)
			before := f.values(t)
			for _, mode := range []string{"NO_ENGINE_SUBSTITUTION,NO_AUTO_VALUE_ON_ZERO", "STRICT_ALL_TABLES,NO_ENGINE_SUBSTITUTION"} {
				run(t, f.s, "SET SESSION sql_mode='"+mode+"'")
				store := &tableedit.Store{}
				b, err := store.Load(context.Background(), f.a, f.target)
				if err != nil {
					t.Fatal("admission control baseline unavailable")
				}
				if _, err = store.PreviewContext(context.Background(), f.a, b.Baseline.ID, myAdvancedStoreRewrite()); err == nil {
					t.Fatal("unsafe existing SQL mode admitted data-moving DDL")
				}
				actual := run(t, f.s, "SELECT @@SESSION.sql_mode").Rows
				if len(actual) != 1 || strings.Contains(*actual[0][0], "NO_AUTO_VALUE_ON_ZERO") != strings.Contains(mode, "NO_AUTO_VALUE_ON_ZERO") || strings.Contains(*actual[0][0], "STRICT_ALL_TABLES") != strings.Contains(mode, "STRICT_ALL_TABLES") {
					t.Fatal("production admission mutated session SQL mode implicitly")
				}
			}
			run(t, f.s, "SET SESSION sql_mode='"+myAdvancedStoreMode+"'")
			store := &tableedit.Store{}
			b, err := store.Load(context.Background(), f.a, f.target)
			if err != nil {
				t.Fatal("native admission baseline unavailable")
			}
			if kind == "Partitions" {
				to := "renamed_id"
				if _, err = store.PreviewContext(context.Background(), f.a, b.Baseline.ID, tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Changes: []tableedit.ColumnChange{{Name: "id", RenameTo: &to}}}); err == nil {
					t.Fatal("partition-key rename bypassed unchanged native suffix proof")
				}
			}
			if !reflect.DeepEqual(before, f.values(t)) || f.counter(t) != myAdvancedStoreCounter {
				t.Fatal("rejected admission changed native data")
			}
			// A pre-cancelled real Store Apply retires the plan without dispatch.
			store, plan := f.preview(t, myAdvancedStoreRewrite())
			ctx, cancel := context.WithCancel(context.Background())
			cancel()
			request := tableedit.Apply{PlanID: plan.ID, Digest: plan.Digest, ExecutionID: tableedit.Token()}
			out, err := store.Apply(ctx, f.a, request)
			if err != nil || out.Outcome.State != "cancelled" || out.Outcome.Steps[0].State != "notStarted" {
				t.Fatal("pre-dispatch cancellation lost its not-started evidence")
			}
			if _, err := store.Apply(context.Background(), f.a, request); err == nil {
				t.Fatal("pre-cancelled plan was replayed")
			}
		})
	}
}
