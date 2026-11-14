package postgres

import (
	"context"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"github.com/jackc/pgx/v5"
	"io"
	"strings"
	"testing"
	"time"
)

func pgE6Value(n string) tableedit.PhysicalValue {
	return tableedit.PhysicalValue{Kind: "integer", Value: &n}
}
func pgE6Apply(t *testing.T, s *Session, d tableedit.PhysicalDraft) tableedit.PhysicalReply {
	t.Helper()
	var store tableedit.PhysicalStore
	assertPhysicalWireArrays(t, "structure.physical.status.result", store.Status())
	p, e := store.Preview(context.Background(), s, d)
	if e != nil {
		t.Fatal(e)
	}
	assertPhysicalWireArrays(t, "structure.physical.preview.result", p)
	r, e := store.Apply(context.Background(), s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "physical"})
	if e != nil || r.Outcome.State != "applied" {
		t.Fatalf("%s acknowledgement failed: %v", d.Intent.Kind, e)
	}
	assertPhysicalWireArrays(t, "structure.physical.apply.result", r)
	assertPhysicalWireArrays(t, "structure.physical.status.result", store.Status())
	for _, step := range r.Outcome.Steps {
		if step.Message != "" {
			t.Fatal("acknowledged operation did not pass preservation comparison: " + d.Intent.Kind)
		}
	}
	return r
}
func TestPhysicalPostgresPartitionMatrixLive(t *testing.T) {
	for _, method := range []string{"range", "list", "hash"} {
		t.Run(method, func(t *testing.T) {
			f := newChangeFixture(t)
			s := &Session{conn: f.conn}
			parent := tableedit.Target{Schema: f.schema, Table: "parent"}
			child := tableedit.Target{Schema: f.schema, Table: "child"}
			f.exec("CREATE TABLE " + f.table("parent") + "(id integer, note text, amount numeric(30,8),payload bytea) PARTITION BY " + strings.ToUpper(method) + "(id)")
			bound := tableedit.PhysicalBound{Kind: method}
			switch method {
			case "range":
				bound.From = []tableedit.PhysicalValue{pgE6Value("0")}
				bound.To = []tableedit.PhysicalValue{pgE6Value("10")}
			case "list":
				bound.Values = [][]tableedit.PhysicalValue{{pgE6Value("1")}, {pgE6Value("2")}, {pgE6Value("3")}}
			case "hash":
				n := 0
				bound.Modulus = 1
				bound.Remainder = &n
			}
			d := tableedit.PhysicalDraft{Version: 1, Target: parent, Intent: tableedit.PhysicalIntent{Kind: "createPartition", Child: &child, Bound: &bound}}
			r := pgE6Apply(t, s, d)
			if len(r.Outcome.Observed[0].Partitions) != 1 {
				t.Fatal("partition not observed")
			}
			f.exec("INSERT INTO " + f.table("parent") + " VALUES(1,'',9007199254740993.12345678,'\\x00ff'),(2,NULL,NULL,NULL),(3,'NULL',0,'\\x')")
			inspect, e := s.PhysicalInspect(context.Background(), parent)
			assertPhysicalWireArrays(t, "structure.physical.inspect.result", tableedit.PhysicalReply{Inspection: &inspect})
			if e != nil || inspect.Objects[0].PartitionMethod != method || len(inspect.Objects[0].Columns) != 4 {
				t.Fatal("inspection metadata rejected", e)
			}
			d.Intent = tableedit.PhysicalIntent{Kind: "detachPartition", Child: &child}
			pgE6Apply(t, s, d)
			var exact, note, payload string
			if e = f.observer.QueryRow(context.Background(), "SELECT amount::text,note,encode(payload,'hex') FROM "+f.table("child")+" WHERE id=1").Scan(&exact, &note, &payload); e != nil || exact != "9007199254740993.12345678" || note != "" || payload != "00ff" {
				t.Fatal("detach changed values")
			}
			d.Intent = tableedit.PhysicalIntent{Kind: "attachPartition", Child: &child, Bound: &bound}
			pgE6Apply(t, s, d)
			d.Intent = tableedit.PhysicalIntent{Kind: "truncatePartition", Child: &child}
			pgE6Apply(t, s, d)
			var n int
			_ = f.observer.QueryRow(context.Background(), "SELECT count(*) FROM "+f.table("parent")).Scan(&n)
			if n != 0 {
				t.Fatal("truncate not applied")
			}
			d.Intent = tableedit.PhysicalIntent{Kind: "dropPartition", Child: &child}
			pgE6Apply(t, s, d)
		})
	}
}
func TestPhysicalPostgresConcurrentIndexInvalidDriftAndUnknownLive(t *testing.T) {
	f := newChangeFixture(t)
	s := &Session{conn: f.conn}
	f.exec("CREATE TABLE " + f.table("indexed") + "(id int,note text)")
	f.exec("INSERT INTO " + f.table("indexed") + " VALUES(1,''),(1,NULL),(2,'NULL')")
	target := tableedit.Target{Schema: f.schema, Table: "indexed"}
	d := tableedit.PhysicalDraft{Version: 1, Target: target, Intent: tableedit.PhysicalIntent{Kind: "concurrentIndex", Index: &tableedit.IndexEdit{Action: "add", Name: "duplicate_unique", Unique: true, Columns: []string{"id"}}}}
	var store tableedit.PhysicalStore
	p, e := store.Preview(context.Background(), s, d)
	if e != nil || !strings.Contains(p.Plan.SQL[0], "CONCURRENTLY") {
		t.Fatal(e)
	}
	r, e := store.Apply(context.Background(), s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "invalid"})
	if e != nil || r.Outcome.State != "failed" {
		t.Fatal("unexpected acknowledgement", e)
	}
	found := false
	for _, i := range r.Outcome.Observed[0].Indexes {
		found = found || i.Name == "duplicate_unique" && !i.Valid
	}
	if !found {
		t.Fatal("failed concurrent CREATE must retain INVALID index observation")
	}
	d.Intent.Index = &tableedit.IndexEdit{Action: "drop", Name: "duplicate_unique"}
	pgE6Apply(t, s, d)
	d.Intent.Index = &tableedit.IndexEdit{Action: "add", Name: "keep", Columns: []string{"note"}}
	pgE6Apply(t, s, d)
	p, e = store.Preview(context.Background(), s, d)
	if e == nil {
		t.Fatal("existing index overwrite admitted")
	}
	d.Intent.Index = &tableedit.IndexEdit{Action: "add", Name: "stale", Columns: []string{"id"}}
	p, e = store.Preview(context.Background(), s, d)
	if e != nil {
		t.Fatal(e)
	}
	f.exec("ALTER TABLE " + f.table("indexed") + " ADD COLUMN external_change int")
	r, e = store.Apply(context.Background(), s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "drift"})
	if e != nil || r.Outcome.Steps[0].State != "notStarted" {
		t.Fatal("stale physical metadata dispatched")
	}
	f.exec("CREATE TABLE " + f.table("parent") + "(id int) PARTITION BY RANGE(id)")
	child := tableedit.Target{Schema: f.schema, Table: "partition"}
	bound := tableedit.PhysicalBound{Kind: "range", From: []tableedit.PhysicalValue{pgE6Value("0")}, To: []tableedit.PhysicalValue{pgE6Value("10")}}
	d = tableedit.PhysicalDraft{Version: 1, Target: tableedit.Target{Schema: f.schema, Table: "parent"}, Intent: tableedit.PhysicalIntent{Kind: "createPartition", Child: &child, Bound: &bound}}
	s.structureCommitOverride = func(commit func() error) error {
		if e := commit(); e != nil {
			return e
		}
		return io.ErrUnexpectedEOF
	}
	var unknown tableedit.PhysicalStore
	p, e = unknown.Preview(context.Background(), s, d)
	if e != nil {
		t.Fatal(e)
	}
	r, e = unknown.Apply(context.Background(), s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "unknown"})
	if e != nil || r.Outcome.State != "outcomeUnknown" || len(r.Outcome.Observed[0].Partitions) != 1 {
		t.Fatal("lost commit acknowledgement promoted or forgotten")
	}
}
func TestPhysicalPostgresConcurrentDetachAndCancelLive(t *testing.T) {
	f := newChangeFixture(t)
	s := &Session{conn: f.conn}
	f.exec("CREATE TABLE " + f.table("p") + "(id int) PARTITION BY RANGE(id)")
	f.exec("CREATE TABLE " + f.table("c") + " PARTITION OF " + f.table("p") + " FOR VALUES FROM(0) TO(10)")
	child := tableedit.Target{Schema: f.schema, Table: "c"}
	d := tableedit.PhysicalDraft{Version: 1, Target: tableedit.Target{Schema: f.schema, Table: "p"}, Intent: tableedit.PhysicalIntent{Kind: "detachPartition", Child: &child, Concurrent: true}}
	pgE6Apply(t, s, d)
	f.exec("CREATE TABLE " + f.table("cancel_index") + "(id int)")
	f.exec("INSERT INTO " + f.table("cancel_index") + " SELECT generate_series(1,500)")
	f.exec("CREATE FUNCTION " + f.table("slow") + "(i int) RETURNS int LANGUAGE plpgsql IMMUTABLE AS $$BEGIN PERFORM pg_sleep(0.005); RETURN i; END$$")
	expression := f.table("slow") + "(id)"
	d = tableedit.PhysicalDraft{Version: 1, Target: tableedit.Target{Schema: f.schema, Table: "cancel_index"}, Intent: tableedit.PhysicalIntent{Kind: "concurrentIndex", Index: &tableedit.IndexEdit{Action: "add", Name: "cancelled_idx", Definition: &tableedit.IndexDefinition{Method: "btree", Terms: []tableedit.IndexTerm{{Expression: &expression}}}}}}
	p, e := s.PhysicalPrepare(context.Background(), d)
	if e != nil {
		t.Fatal(e)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	out := s.PhysicalExecute(ctx, p, func(_ int, phase string) {
		if phase == "running" {
			go func() { time.Sleep(150 * time.Millisecond); cancel() }()
		}
	})
	if len(out) != 1 || out[0].State == "applied" || out[0].State == "notStarted" {
		t.Fatal("cancel did not interrupt dispatched concurrent index")
	}
	var valid bool
	if e = f.observer.QueryRow(context.Background(), `SELECT i.indisvalid FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class c ON c.oid=i.indexrelid JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname='cancelled_idx'`, f.schema).Scan(&valid); e != nil || valid {
		t.Fatal("cancelled index was not retained INVALID", e)
	}
}

func TestPhysicalPostgresDefaultAndPendingFinalizeLive(t *testing.T) {
	f := newChangeFixture(t)
	s := &Session{conn: f.conn}
	f.exec("CREATE TABLE " + f.table("p") + "(id int) PARTITION BY RANGE(id)")
	f.exec("CREATE TABLE " + f.table("c") + " PARTITION OF " + f.table("p") + " FOR VALUES FROM(0) TO(10)")
	child := tableedit.Target{Schema: f.schema, Table: "c"}
	d := tableedit.PhysicalDraft{Version: 1, Target: tableedit.Target{Schema: f.schema, Table: "p"}, Intent: tableedit.PhysicalIntent{Kind: "detachPartition", Child: &child, Concurrent: true}}
	// An older snapshot of this parent holds concurrent detach between its two acknowledged internal transactions.
	tx, e := f.observer.Begin(context.Background())
	if e != nil {
		t.Fatal(e)
	}
	if _, e = tx.Exec(context.Background(), "SELECT * FROM "+f.table("p")); e != nil {
		t.Fatal(e)
	}
	plan, e := s.PhysicalPrepare(context.Background(), d)
	if e != nil {
		t.Fatal(e)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan []tableedit.Execution, 1)
	go func() { done <- s.PhysicalExecute(ctx, plan, func(int, string) {}) }() // Separate metadata observer belongs only to this disposable fixture.
	observer, e := pgx.ConnectConfig(context.Background(), f.conn.Config().Copy())
	if e != nil {
		t.Fatal(e)
	}
	defer observer.Close(context.Background())
	deadline := time.Now().Add(3 * time.Second)
	pending := false
	for time.Now().Before(deadline) {
		_ = observer.QueryRow(context.Background(), `SELECT COALESCE(bool_or(i.inhdetachpending),false) FROM pg_catalog.pg_inherits i JOIN pg_catalog.pg_class c ON c.oid=i.inhrelid JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname='c'`, f.schema).Scan(&pending)
		if pending {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !pending {
		cancel()
		_ = tx.Rollback(context.Background())
		<-done
		t.Fatal("concurrent detach never entered its pending state")
	}
	cancel()
	result := <-done
	_ = tx.Rollback(context.Background())
	if len(result) != 1 || result[0].State == "applied" {
		t.Fatal("interrupted detach reported complete")
	}
	if s.TransactionStatus() != "idle" {
		s = &Session{conn: observer}
	}
	d.Intent = tableedit.PhysicalIntent{Kind: "finalizePartition", Child: &child}
	pgE6Apply(t, s, d)
	defaultChild := tableedit.Target{Schema: f.schema, Table: "default_child"}
	bound := tableedit.PhysicalBound{Kind: "default"}
	d.Intent = tableedit.PhysicalIntent{Kind: "createPartition", Child: &defaultChild, Bound: &bound}
	pgE6Apply(t, s, d)
	d.Intent = tableedit.PhysicalIntent{Kind: "detachPartition", Child: &defaultChild, Concurrent: true}
	if _, e = s.PhysicalPrepare(context.Background(), d); e == nil {
		t.Fatal("concurrent detach with default partition admitted")
	}
}

func TestPhysicalPostgresRetainedSchemaPropertiesLive(t *testing.T) {
	f := newChangeFixture(t)
	s := &Session{conn: f.conn}
	f.exec("CREATE TABLE " + f.table("p") + "(id int NOT NULL, note text DEFAULT 'NULL', amount numeric(30,8), payload bytea, CONSTRAINT positive CHECK(id>=0), CONSTRAINT p_pk PRIMARY KEY(id)) PARTITION BY RANGE(id)")
	f.exec("CREATE INDEX p_note ON " + f.table("p") + "(note)")
	f.exec("CREATE FUNCTION " + f.table("keep_trigger") + "() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RETURN NEW; END$$")
	f.exec("CREATE TRIGGER keep BEFORE INSERT ON " + f.table("p") + " FOR EACH ROW EXECUTE FUNCTION " + f.table("keep_trigger") + "()")
	f.exec("COMMENT ON TABLE " + f.table("p") + " IS 'retained parent'")
	f.exec("COMMENT ON COLUMN " + f.table("p") + ".note IS 'retained column'")
	f.exec("CREATE TABLE " + f.table("sibling") + " PARTITION OF " + f.table("p") + " FOR VALUES FROM(10) TO(20)")
	parent := tableedit.Target{Schema: f.schema, Table: "p"}
	child := tableedit.Target{Schema: f.schema, Table: "child"}
	bound := tableedit.PhysicalBound{Kind: "range", From: []tableedit.PhysicalValue{pgE6Value("0")}, To: []tableedit.PhysicalValue{pgE6Value("10")}}
	d := tableedit.PhysicalDraft{Version: 1, Target: parent, Intent: tableedit.PhysicalIntent{Kind: "createPartition", Child: &child, Bound: &bound}}
	pgE6Apply(t, s, d)
	f.exec("COMMENT ON TABLE " + f.table("child") + " IS 'retained child'")
	f.exec("INSERT INTO " + f.table("p") + " VALUES(1,'',9007199254740993.12345678,'\\x00ff'),(2,NULL,NULL,NULL),(3,'NULL',0,'\\x'),(15,'sibling',1,NULL)")
	before, e := pgPhysicalRead(context.Background(), s.conn, tableedit.Target{Schema: f.schema, Table: "sibling"})
	if e != nil {
		t.Fatal(e)
	}
	d.Intent = tableedit.PhysicalIntent{Kind: "detachPartition", Child: &child}
	pgE6Apply(t, s, d)
	d.Intent = tableedit.PhysicalIntent{Kind: "attachPartition", Child: &child, Bound: &bound}
	pgE6Apply(t, s, d)
	after, e := pgPhysicalRead(context.Background(), s.conn, tableedit.Target{Schema: f.schema, Table: "sibling"})
	if e != nil || tableedit.Fingerprint(before) != tableedit.Fingerprint(after) {
		t.Fatal("unselected sibling properties changed")
	}
	var comment string
	if e = f.observer.QueryRow(context.Background(), `SELECT pg_catalog.obj_description($1::pg_catalog.regclass,'pg_class')`, f.table("child")).Scan(&comment); e != nil || comment != "retained child" {
		t.Fatal("child comment not preserved")
	}
	if _, e = f.observer.Exec(context.Background(), "INSERT INTO "+f.table("p")+"(id) VALUES(1)"); e == nil {
		t.Fatal("primary key not preserved")
	}
	if _, e = f.observer.Exec(context.Background(), "INSERT INTO "+f.table("p")+"(id) VALUES(-1)"); e == nil {
		t.Fatal("check constraint not preserved")
	}
}

// Marshal the real adapter/store reply through the production wire serializer;
// strict native readers require empty arrays, never null collection defaults.
func assertPhysicalWireArrays(t *testing.T, typ string, reply tableedit.PhysicalReply) {
	t.Helper()
	raw, e := json.Marshal(protocol.Response{Type: typ, RequestID: "r", SessionID: "s", QueryID: "q", Connected: true, TransactionStatus: "idle", Structure: &tableedit.Reply{Physical: &reply}})
	if e != nil {
		t.Fatal("physical reply cannot be marshalled")
	}
	var object map[string]any
	if json.Unmarshal(raw, &object) != nil {
		t.Fatal("physical reply is not JSON")
	}
	var noNull func(any) bool
	noNull = func(v any) bool {
		switch x := v.(type) {
		case nil:
			return false
		case map[string]any:
			for _, v := range x {
				if !noNull(v) {
					return false
				}
			}
		case []any:
			for _, v := range x {
				if !noNull(v) {
					return false
				}
			}
		}
		return true
	}
	if !noNull(object) {
		t.Fatal("actual physical wire reply contains an explicit null")
	}
	structure, _ := object["structure"].(map[string]any)
	physical, _ := structure["physical"].(map[string]any)
	arrays := func(o map[string]any, keys ...string) {
		for _, key := range keys {
			if _, ok := o[key].([]any); !ok {
				t.Fatal("actual physical wire reply lost required array " + key)
			}
		}
	}
	checkObjects := func(v any) {
		objects, ok := v.([]any)
		if !ok {
			t.Fatal("actual physical wire reply lost object array")
		}
		for _, v := range objects {
			o, ok := v.(map[string]any)
			if !ok {
				t.Fatal("invalid physical object")
			}
			arrays(o, "columns", "partitions", "indexes", "limitations")
		}
	}
	if plan, ok := physical["plan"].(map[string]any); ok {
		arrays(plan, "sql", "objects", "prerequisites", "risks", "consequences")
		checkObjects(plan["objects"])
	}
	if outcome, ok := physical["outcome"].(map[string]any); ok {
		arrays(outcome, "steps")
		if v, present := outcome["observed"]; present {
			checkObjects(v)
		}
	}
	if inspection, ok := physical["inspection"].(map[string]any); ok {
		arrays(inspection, "objects", "operations")
		checkObjects(inspection["objects"])
	}
}
