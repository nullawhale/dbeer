package mysql

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"errors"
	"fmt"
	wire "github.com/go-mysql-org/go-mysql/mysql"
	"io"
	"os"
	"strings"
	"testing"
	"time"
)

func mysqlE4Draft(order ...string) tableedit.Draft {
	return tableedit.Draft{AuthoringVersion: 5, AllowDestructive: true, Columns: []tableedit.Column{}, ColumnOrder: order, Reconstruct: true}
}
func TestStructureReconstructionAndNativePhysicalOrderLive(t *testing.T) {
	s := integrationSession(t)
	observer := integrationSession(t)
	name := fmt.Sprintf("e4_order_%d", time.Now().UnixNano())
	child := name + "_child"
	audit := name + "_audit"
	table := QuoteIdentifier(name)
	ctx := context.Background()
	for _, sql := range []string{"CREATE TABLE " + table + " (id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY, value VARCHAR(40) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT 'NULL' COMMENT 'retained', amount DECIMAL(30,8) UNSIGNED DEFAULT 1.25, payload VARBINARY(20), generated_value BIGINT GENERATED ALWAYS AS (amount+1) VIRTUAL, UNIQUE KEY e4_unique(value), KEY e4_amount(amount)) ENGINE=InnoDB", "CREATE TABLE " + QuoteIdentifier(child) + " (id BIGINT UNSIGNED, FOREIGN KEY(id) REFERENCES " + table + "(id) ON DELETE CASCADE)", "CREATE TABLE " + QuoteIdentifier(audit) + " (v VARCHAR(40))", "CREATE TRIGGER " + QuoteIdentifier(name+"_trigger") + " AFTER INSERT ON " + table + " FOR EACH ROW INSERT INTO " + QuoteIdentifier(audit) + " VALUES(NEW.value)", "INSERT INTO " + table + " (value,amount,payload) VALUES('',9007199254740993.12345678,X'00FF'),(NULL,NULL,NULL),('NULL',0,X'')", "INSERT INTO " + QuoteIdentifier(child) + " VALUES(1)"} {
		run(t, observer, sql)
	}
	defer func() {
		run(t, observer, "DROP TABLE IF EXISTS "+QuoteIdentifier(child))
		run(t, observer, "DROP TABLE IF EXISTS "+table)
		run(t, observer, "DROP TABLE IF EXISTS "+QuoteIdentifier(audit))
	}()
	run(t, observer, "SET SESSION sql_mode=CONCAT(@@sql_mode,',NO_AUTO_VALUE_ON_ZERO')")
	run(t, observer, "INSERT INTO "+table+" (id,value,amount,payload) VALUES(0,'zero',0,X'00')")
	target := tableedit.Target{Schema: integrationSettings(t).Database, Table: name}
	store := &tableedit.Store{}
	loaded, e := store.Load(ctx, s, target)
	if e != nil {
		t.Fatal(e)
	}
	d := mysqlE4Draft("payload", "amount", "value", "id", "generated_value")
	p, e := store.PreviewContext(ctx, s, loaded.Baseline.ID, d)
	if e != nil {
		t.Fatal(e)
	}
	if len(p.Plan.SQL) != 1 || !strings.Contains(p.Plan.SQL[0], " FIRST") || !strings.Contains(p.Plan.SQL[0], " AFTER ") {
		t.Fatal("no native order method")
	}
	out, e := store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "physical"})
	if e != nil || out.Outcome.State != "applied" {
		t.Fatalf("reorder failed %v %+v", e, out.Outcome)
	}
	for _, x := range out.Outcome.Steps {
		if x.Message != "" {
			t.Fatal(x.Message)
		}
	}
	r, e := observer.work.client.Execute("SELECT value,amount,HEX(payload),generated_value FROM " + table + " WHERE id=1")
	if e != nil {
		t.Fatal("retained rows unavailable")
	}
	value, _ := ownedStructureString(r, 0, 0)
	amount, _ := ownedStructureString(r, 0, 1)
	payload, _ := ownedStructureString(r, 0, 2)
	generated, _ := r.GetInt(0, 3)
	r.Close()
	if value != "" || amount != "9007199254740993.12345678" || payload != "00FF" || generated != 9007199254740994 {
		t.Fatal("native values changed")
	}
	r, e = observer.work.client.Execute("SELECT count(*) FROM " + QuoteIdentifier(child))
	if e != nil {
		t.Fatal(e)
	}
	n, _ := r.GetInt(0, 0)
	r.Close()
	if n != 1 {
		t.Fatal("incoming reference lost")
	}
	zero, e := observer.work.client.Execute("SELECT count(*) FROM " + table + " WHERE id=0")
	if e != nil {
		t.Fatal(e)
	}
	zeros, _ := zero.GetInt(0, 0)
	zero.Close()
	if zeros != 1 {
		t.Fatal("reorder rewrote an existing AUTO_INCREMENT zero")
	}
	loaded, e = store.Load(ctx, s, target)
	if e != nil {
		t.Fatal(e)
	}
	p, e = store.PreviewContext(ctx, s, loaded.Baseline.ID, mysqlE4Draft())
	if e != nil || !strings.Contains(p.Plan.SQL[0], " FORCE") {
		t.Fatal("native FORCE missing", e)
	}
	out, e = store.Apply(ctx, s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "force"})
	if e != nil || out.Outcome.State != "applied" {
		t.Fatal("native FORCE failed", e)
	}
	run(t, observer, "INSERT INTO "+table+" (value) VALUES('after')")
	counter, e := observer.work.client.Execute("SELECT id FROM " + table + " WHERE value='after'")
	if e != nil {
		t.Fatal(e)
	}
	next, _ := counter.GetInt(0, 0)
	counter.Close()
	if next != 4 {
		t.Fatal("reconstruction changed the AUTO_INCREMENT counter")
	}
	zero, e = observer.work.client.Execute("SELECT count(*) FROM " + table + " WHERE id=0")
	if e != nil {
		t.Fatal(e)
	}
	zeros, _ = zero.GetInt(0, 0)
	zero.Close()
	if zeros != 1 {
		t.Fatal("FORCE rewrote an existing AUTO_INCREMENT zero")
	}

	r, e = observer.work.client.Execute("SELECT count(*) FROM " + QuoteIdentifier(audit))
	if e != nil {
		t.Fatal(e)
	}
	n, _ = r.GetInt(0, 0)
	r.Close()
	if n != 5 {
		t.Fatal("retained trigger fired during reconstruction or disappeared")
	}
}
func TestStructureBackfillPreviewPartialFailureCancellationAndUnknownLive(t *testing.T) {
	for _, effect := range []string{"apply", "failed-expression", "cancel", "unknown", "concurrent"} {
		t.Run(effect, func(t *testing.T) {
			s := integrationSession(t)
			observer := integrationSession(t)
			name := fmt.Sprintf("e4_backfill_%d", time.Now().UnixNano())
			table := QuoteIdentifier(name)
			run(t, observer, "CREATE TABLE "+table+" (id INT)")
			run(t, observer, "INSERT INTO "+table+" VALUES(1),(2)")
			defer run(t, observer, "DROP TABLE IF EXISTS "+table)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			store := &tableedit.Store{}
			b, e := store.Load(ctx, s, tableedit.Target{Schema: integrationSettings(t).Database, Table: name})
			if e != nil {
				t.Fatal(e)
			}
			expression := "CONCAT(id,':required')"
			if effect == "failed-expression" {
				expression = "missing_function(id)"
			}
			d := tableedit.Draft{AuthoringVersion: 5, AllowDestructive: true, Columns: []tableedit.Column{{Name: "required", Type: tableedit.DataType{Kind: "varchar", Length: 40}, Default: tableedit.Default{Kind: "none"}}}, Backfills: []tableedit.Backfill{{Column: "required", Expression: expression}}}
			p, e := store.PreviewContext(ctx, s, b.Baseline.ID, d)
			if e != nil || len(p.Plan.SQL) != 3 || !strings.Contains(p.Plan.SQL[1], expression) {
				t.Fatal("preview evaluated or hid expression", e)
			}
			if effect == "cancel" {
				s.afterStructureStep = func(i int) {
					if i == 0 {
						cancel()
					}
				}
			}
			if effect == "unknown" {
				s.afterStructureStep = func(i int) {
					if i == 0 {
						s.structureExecuteOverride = func(execute func() error) error {
							if e := execute(); e != nil {
								return e
							}
							return io.ErrUnexpectedEOF
						}
					}
				}
			}
			if effect == "concurrent" {
				run(t, observer, "ALTER TABLE "+table+" ADD COLUMN concurrent INT")
			}
			apply := tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: effect}
			out, e := store.Apply(ctx, s, apply)
			if e != nil {
				t.Fatal(e)
			}
			want := map[string]string{"apply": "applied", "failed-expression": "partiallyApplied", "cancel": "partiallyApplied", "unknown": "outcomeUnknown", "concurrent": "failed"}[effect]
			if out.Outcome.State != want {
				t.Fatalf("want %s got %+v", want, out.Outcome)
			}
			if _, e = store.Apply(ctx, s, apply); e == nil {
				t.Fatal("execution replayed")
			}
		})
	}
}

func TestStructureReconstructionNativeDefinitionClausesAreNeverRewritten(t *testing.T) {
	facts := &tableedit.Facts{EngineContext: []sc.Option{{Name: "sqlMode", Value: "ANSI_QUOTES,NO_BACKSLASH_ESCAPES"}}}
	raw := `CREATE TABLE "record" ("i(d," BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, "v" VARCHAR(50) DEFAULT 'ENGINE_ATTRIBUTE, COLUMN_FORMAT' COMMENT 'kept', "g" TEXT GENERATED ALWAYS AS (concat("v",',(')) STORED, "location" POINT SRID 4326, PRIMARY KEY ("i(d,"), KEY "k" ("v")) ENGINE=InnoDB AUTO_INCREMENT=900`
	columns, other, suffix, ok := mysqlReconstructionDefinition(raw, facts)
	if !ok || len(columns) != 4 || len(other) != 2 || !strings.Contains(columns["location"], "SRID 4326") || !strings.Contains(columns["v"], "COMMENT 'kept'") || !strings.Contains(suffix, "AUTO_INCREMENT=900") {
		t.Fatal("native attribute or quoted clause lost")
	}
	reordered := `CREATE TABLE "record" (` + columns["location"] + `, ` + columns["g"] + `, ` + columns["v"] + `, ` + columns["i(d,"] + `, ` + strings.Join(other, ", ") + `) ` + suffix
	a := tableedit.Baseline{NativeDefinition: raw, Facts: facts}
	b := a
	b.NativeDefinition = reordered
	if !mysqlReconstructionPreserved(a, b) {
		t.Fatal("physical order changed native properties")
	}
	b.NativeDefinition = strings.Replace(reordered, "SRID 4326", "SRID 0", 1)
	if mysqlReconstructionPreserved(a, b) {
		t.Fatal("unmodeled native attribute loss was hidden")
	}
}

func TestStructureReconstructionIdentityOrderPhysicallyRebuildsLive(t *testing.T) {
	if os.Getenv("DBEER_TEST_MYSQL_MONITOR_PRIVILEGES") != "1" {
		t.Skip("physical table-identity proof requires the disposable PROCESS observer")
	}
	s := integrationSession(t)
	writer := integrationSession(t)
	settings := integrationSettings(t)
	observerSettings := settings
	observerSettings.User = os.Getenv("DBEER_TEST_MYSQL_MONITOR_USER")
	observerSettings.Password = os.Getenv("DBEER_TEST_MYSQL_MONITOR_PASSWORD")
	if observerSettings.User == "" || observerSettings.Password == "" {
		t.Fatal("owned physical metadata observer credentials are missing")
	}
	opened, err := Open(context.Background(), observerSettings)
	if err != nil {
		t.Fatal("cannot open physical metadata observer")
	}
	observer := opened.(*Session)
	defer observer.Close()
	name := fmt.Sprintf("e4_identity_order_%d", time.Now().UnixNano())
	table := QuoteIdentifier(name)
	run(t, writer, "CREATE TABLE "+table+" (id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,value DECIMAL(30,8) NOT NULL,derived DECIMAL(30,8) GENERATED ALWAYS AS (value+1) VIRTUAL) ENGINE=InnoDB")
	defer run(t, writer, "DROP TABLE IF EXISTS "+table)
	run(t, writer, "SET SESSION sql_mode=CONCAT(@@sql_mode,',NO_AUTO_VALUE_ON_ZERO')")
	run(t, writer, "INSERT INTO "+table+" (id,value) VALUES(0,9007199254740993.12345678),(1,0)")
	readID := func() uint64 {
		t.Helper()
		r, e := observer.work.client.Execute("SELECT TABLE_ID FROM information_schema.INNODB_TABLES WHERE NAME=?", settings.Database+"/"+name)
		if e != nil {
			t.Fatal("physical InnoDB metadata is unavailable")
		}
		defer r.Close()
		if r.RowNumber() != 1 {
			t.Fatal("owned InnoDB table identity is ambiguous")
		}
		id, e := r.GetUint(0, 0)
		if e != nil || id == 0 {
			t.Fatal("invalid physical InnoDB table identity")
		}
		return id
	}
	store := &tableedit.Store{}
	target := tableedit.Target{Schema: settings.Database, Table: name}
	for i, order := range [][]string{{"id", "value", "derived"}, {"derived", "id", "value"}} {
		before := readID()
		b, e := store.Load(context.Background(), s, target)
		if e != nil {
			t.Fatal(e)
		}
		p, e := store.PreviewContext(context.Background(), s, b.Baseline.ID, mysqlE4Draft(order...))
		if i == 1 && b.Baseline.Facts.ServerVersion < 80400 {
			if e == nil || !strings.Contains(e.Error(), "requires ALGORITHM=COPY") {
				t.Fatal("unsupported virtual reorder lacked its concrete prerequisite")
			}
			definitions, _, _, ok := mysqlReconstructionDefinition(b.Baseline.NativeDefinition, b.Baseline.Facts)
			if !ok {
				t.Fatal("native boundary definition unavailable")
			}
			result, nativeErr := writer.work.client.Execute("ALTER TABLE " + table + " MODIFY COLUMN " + definitions["derived"] + " FIRST, ALGORITHM=INPLACE, LOCK=EXCLUSIVE")
			if result != nil {
				result.Close()
			}
			var native *wire.MyError
			if !errors.As(nativeErr, &native) || native.Code != 1846 {
				t.Fatal("actual server did not enforce the virtual-order INPLACE boundary")
			}
			if readID() != before {
				t.Fatal("rejected virtual reorder changed physical identity")
			}
			continue
		}
		if e != nil {
			t.Fatal(e)
		}

		out, e := store.Apply(context.Background(), s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: fmt.Sprintf("physical-proof-%d", i)})
		if e != nil || out.Outcome.State != "applied" {
			t.Fatalf("explicit reconstruction with column order failed (case=%d state=%s)", i, out.Outcome.State)
		}
		for _, step := range out.Outcome.Steps {
			if step.Message != "" {
				t.Fatal("retained native schema did not match")
			}
		}
		if readID() == before {
			t.Fatal("explicit reconstruction with unchanged or virtual-only order did not rebuild the physical table")
		}
	}
	r, e := writer.work.client.Execute("SELECT value,derived FROM " + table + " WHERE id=0")
	if e != nil {
		t.Fatal("retained zero row is unavailable")
	}
	value, _ := ownedStructureString(r, 0, 0)
	derived, _ := ownedStructureString(r, 0, 1)
	r.Close()
	if value != "9007199254740993.12345678" || derived != "9007199254740994.12345678" {
		t.Fatal("explicit reconstruction changed exact values or generation")
	}
	run(t, writer, "INSERT INTO "+table+" (value) VALUES(1)")
	r, e = writer.work.client.Execute("SELECT id FROM " + table + " WHERE value=1")
	if e != nil {
		t.Fatal("counter proof is unavailable")
	}
	next, _ := r.GetUint(0, 0)
	r.Close()
	if next != 2 {
		t.Fatal("explicit reconstruction reset the AUTO_INCREMENT counter")
	}
}
