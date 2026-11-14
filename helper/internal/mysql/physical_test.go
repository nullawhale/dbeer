package mysql

import (
	"context"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"fmt"
	"io"
	"reflect"
	"strings"
	"testing"
	"time"
)

func myE6Value(n string) tableedit.PhysicalValue {
	return tableedit.PhysicalValue{Kind: "integer", Value: &n}
}
func myE6Apply(t *testing.T, s *Session, d tableedit.PhysicalDraft) tableedit.PhysicalReply {
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
		t.Fatalf("%s acknowledgement failed: %v state=%s detail=%s", d.Intent.Kind, e, r.Outcome.State, r.Outcome.Steps[0].Message)
	}
	assertPhysicalWireArrays(t, "structure.physical.apply.result", r)
	assertPhysicalWireArrays(t, "structure.physical.status.result", store.Status())
	for _, step := range r.Outcome.Steps {
		if step.Message != "" {
			t.Fatal("acknowledged operation did not pass the preservation comparison: " + d.Intent.Kind)
		}
	}
	return r
}
func TestPhysicalMySQLPartitionsMatrixLive(t *testing.T) {
	for _, method := range []string{"range", "list", "hash", "key"} {
		t.Run(method, func(t *testing.T) {
			s := integrationSession(t)
			name := fmt.Sprintf("e6_%s_%d", method, time.Now().UnixNano())
			q := QuoteIdentifier(name)
			run(t, s, "CREATE TABLE "+q+"(id int NOT NULL,note varchar(40),amount decimal(30,8),payload varbinary(20)) ENGINE=InnoDB")
			defer run(t, s, "DROP TABLE IF EXISTS "+q)
			target := tableedit.Target{Schema: integrationSettings(t).Database, Table: name}
			intent := tableedit.PhysicalIntent{Kind: "partitionTable", Method: method, Columns: []string{"id"}, Algorithm: "COPY", Lock: "EXCLUSIVE"}
			if method == "hash" || method == "key" {
				intent.Count = 2
			} else {
				b := tableedit.PhysicalBound{Kind: method}
				if method == "range" {
					b.To = []tableedit.PhysicalValue{myE6Value("10")}
				} else {
					b.Values = [][]tableedit.PhysicalValue{{myE6Value("1")}, {myE6Value("2")}, {myE6Value("3")}}
				}
				intent.Definitions = []tableedit.PhysicalPartitionDefinition{{Name: "p0", Bound: b}}
			}
			d := tableedit.PhysicalDraft{Version: 1, Target: target, Intent: intent}
			myE6Apply(t, s, d)
			run(t, s, "INSERT INTO "+q+" VALUES(1,'',9007199254740993.12345678,X'00FF'),(2,NULL,NULL,NULL),(3,'NULL',0,X'')")
			inspection, e := s.PhysicalInspect(context.Background(), target)
			assertPhysicalWireArrays(t, "structure.physical.inspect.result", tableedit.PhysicalReply{Inspection: &inspection})
			if e != nil || len(inspection.Objects[0].Columns) != 4 || len(inspection.Objects[0].Partitions) == 0 {
				t.Fatal("inspection unavailable", e)
			}
			if method == "range" || method == "list" {
				bound := tableedit.PhysicalBound{Kind: method}
				if method == "range" {
					bound.To = []tableedit.PhysicalValue{myE6Value("20")}
				} else {
					bound.Values = [][]tableedit.PhysicalValue{{myE6Value("4")}, {myE6Value("5")}}
				}
				d.Intent = tableedit.PhysicalIntent{Kind: "addPartition", Definitions: []tableedit.PhysicalPartitionDefinition{{Name: "p1", Bound: bound}}, Algorithm: "INPLACE", Lock: "NONE"}
				myE6Apply(t, s, d)
				d.Intent = tableedit.PhysicalIntent{Kind: "truncatePartition", Partitions: []string{"p1"}, Algorithm: "INPLACE", Lock: "NONE"}
				myE6Apply(t, s, d)
				d.Intent.Kind = "dropPartition"
				myE6Apply(t, s, d)
			} else {
				d.Intent = tableedit.PhysicalIntent{Kind: "addHashPartitions", Count: 1, Algorithm: "INPLACE", Lock: "SHARED"}
				myE6Apply(t, s, d)
				d.Intent.Kind = "coalescePartitions"
				myE6Apply(t, s, d)
			}
			d.Intent = tableedit.PhysicalIntent{Kind: "removePartitioning", Algorithm: "COPY", Lock: "EXCLUSIVE"}
			myE6Apply(t, s, d)
			r, e := s.work.client.Execute("SELECT note,amount,HEX(payload) FROM " + q + " WHERE id=1")
			if e != nil {
				t.Fatal(e)
			}
			note, _ := ownedStructureString(r, 0, 0)
			amount, _ := ownedStructureString(r, 0, 1)
			payload, _ := ownedStructureString(r, 0, 2)
			r.Close()
			if note != "" || amount != "9007199254740993.12345678" || payload != "00FF" {
				t.Fatal("partition management changed exact values")
			}
		})
	}
}
func TestPhysicalMySQLEngineOnlineIndexReorderAndUnknownLive(t *testing.T) {
	s := integrationSession(t)
	observer := integrationSession(t)
	name := fmt.Sprintf("e6_engine_%d", time.Now().UnixNano())
	q := QuoteIdentifier(name)
	run(t, s, "SET SESSION sql_mode=CONCAT(@@sql_mode,',NO_AUTO_VALUE_ON_ZERO')")
	run(t, s, "CREATE TABLE "+q+"(id bigint NOT NULL AUTO_INCREMENT PRIMARY KEY,note varchar(40) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT 'NULL' COMMENT 'retained',amount decimal(30,8),payload varbinary(20)) ENGINE=InnoDB COMMENT='table retained'")
	defer run(t, observer, "DROP TABLE IF EXISTS "+q)
	run(t, s, "INSERT INTO "+q+" VALUES(0,'',9007199254740993.12345678,X'00FF'),(2,NULL,NULL,NULL),(3,'NULL',0,X'')")
	target := tableedit.Target{Schema: integrationSettings(t).Database, Table: name}
	d := tableedit.PhysicalDraft{Version: 1, Target: target, Intent: tableedit.PhysicalIntent{Kind: "storageEngine", Engine: "MyISAM", Algorithm: "COPY", Lock: "EXCLUSIVE"}}
	before, e := s.readStructurePhysical(target, true)
	if e != nil {
		t.Fatal(e)
	}
	myE6Apply(t, s, d)
	after, e := s.readStructurePhysical(target, true)
	if e != nil || !myPhysicalPreserved(before, after, "storageEngine", nil) {
		t.Fatal("engine conversion lost schema properties", e)
	}
	d.Intent.Engine = "InnoDB"
	myE6Apply(t, s, d)
	d.Intent = tableedit.PhysicalIntent{Kind: "onlineIndex", Index: &tableedit.IndexEdit{Action: "add", Name: "note_idx", Columns: []string{"note"}}, Algorithm: "INPLACE", Lock: "NONE"}
	myE6Apply(t, s, d)
	d.Intent.Index = &tableedit.IndexEdit{Action: "drop", Name: "note_idx"}
	myE6Apply(t, s, d)
	d.Intent = tableedit.PhysicalIntent{Kind: "reorderColumns", ColumnOrder: []string{"payload", "amount", "note", "id"}, Algorithm: "COPY", Lock: "SHARED"}
	myE6Apply(t, s, d)
	r, e := s.work.client.Execute("SELECT note,amount,HEX(payload) FROM " + q + " WHERE id=0")
	if e != nil {
		t.Fatal(e)
	}
	note, _ := ownedStructureString(r, 0, 0)
	amount, _ := ownedStructureString(r, 0, 1)
	payload, _ := ownedStructureString(r, 0, 2)
	r.Close()
	if note != "" || amount != "9007199254740993.12345678" || payload != "00FF" {
		t.Fatal("engine or COPY changed native values/zero")
	}
	d.Intent = tableedit.PhysicalIntent{Kind: "onlineIndex", Index: &tableedit.IndexEdit{Action: "add", Name: "unknown_idx", Columns: []string{"note"}}, Algorithm: "INPLACE", Lock: "NONE"}
	var store tableedit.PhysicalStore
	p, e := store.Preview(context.Background(), s, d)
	if e != nil {
		t.Fatal(e)
	}
	s.structureExecuteOverride = func(exec func() error) error {
		if e := exec(); e != nil {
			return e
		}
		return io.ErrUnexpectedEOF
	}
	out, e := store.Apply(context.Background(), s, tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "unknown"})
	if e != nil || out.Outcome.State != "outcomeUnknown" {
		t.Fatal("lost acknowledgement promoted", e)
	}
}
func TestPhysicalMySQLStrictAlgorithmAndLossReview(t *testing.T) {
	for _, x := range []tableedit.PhysicalIntent{{Kind: "storageEngine", Algorithm: "INPLACE", Lock: "EXCLUSIVE"}, {Kind: "coalescePartitions", Algorithm: "INPLACE", Lock: "NONE"}, {Kind: "partitionTable", Algorithm: "COPY", Lock: "NONE"}, {Kind: "onlineIndex", Algorithm: "INSTANT", Lock: "EXCLUSIVE"}} {
		if e := myPhysicalAlgorithm(x, ""); e == nil {
			t.Fatal("unproven fallback allowed", x)
		}
	}
	text := "'\\NULL"
	sql, e := myPhysicalValue(tableedit.PhysicalValue{Kind: "text", Value: &text})
	if e != nil || strings.Contains(sql, text) {
		t.Fatal("mode-dependent text bound")
	}
}

func TestPhysicalMySQLReorganizeExchangeColumnsAndLossLive(t *testing.T) {
	s := integrationSession(t)
	name := fmt.Sprintf("e6_parts_%d", time.Now().UnixNano())
	q := QuoteIdentifier(name)
	other := name + "_standalone"
	oq := QuoteIdentifier(other)
	run(t, s, "CREATE TABLE "+q+"(id int,note varchar(40)) ENGINE=InnoDB PARTITION BY RANGE(id)(PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN(20))")
	run(t, s, "CREATE TABLE "+oq+"(id int,note varchar(40)) ENGINE=InnoDB")
	defer run(t, s, "DROP TABLE IF EXISTS "+q)
	defer run(t, s, "DROP TABLE IF EXISTS "+oq)
	run(t, s, "INSERT INTO "+q+" VALUES(1,''),(7,'NULL'),(15,NULL)")
	run(t, s, "INSERT INTO "+oq+" VALUES(2,'exchanged')")
	target := tableedit.Target{Schema: integrationSettings(t).Database, Table: name}
	d := tableedit.PhysicalDraft{Version: 1, Target: target, Intent: tableedit.PhysicalIntent{Kind: "reorganizePartition", Partitions: []string{"p0"}, Definitions: []tableedit.PhysicalPartitionDefinition{{Name: "p00", Bound: tableedit.PhysicalBound{Kind: "range", To: []tableedit.PhysicalValue{myE6Value("5")}}}, {Name: "p01", Bound: tableedit.PhysicalBound{Kind: "range", To: []tableedit.PhysicalValue{myE6Value("10")}}}}, Algorithm: "INPLACE", Lock: "SHARED"}}
	myE6Apply(t, s, d)
	child := tableedit.Target{Schema: target.Schema, Table: other}
	d.Intent = tableedit.PhysicalIntent{Kind: "exchangePartition", Child: &child, Partitions: []string{"p00"}, Algorithm: "INPLACE", Lock: "NONE"}
	myE6Apply(t, s, d)
	r, e := s.work.client.Execute("SELECT count(*) FROM " + oq + " WHERE id=1 AND note=''")
	if e != nil {
		t.Fatal("exchanged rows unavailable")
	}
	n, _ := r.GetInt(0, 0)
	r.Close()
	if n != 1 {
		t.Fatal("exchange did not retain exact empty-string rows")
	}
	d.Intent = tableedit.PhysicalIntent{Kind: "dropPartition", Partitions: []string{"p01"}, Algorithm: "INPLACE", Lock: "NONE"}
	myE6Apply(t, s, d)
	r, e = s.work.client.Execute("SELECT count(*) FROM " + q + " WHERE id=7")
	if e != nil {
		t.Fatal("partition loss not observable")
	}
	n, _ = r.GetInt(0, 0)
	r.Close()
	if n != 0 {
		t.Fatal("drop did not delete selected rows")
	}
	for _, method := range []string{"RANGE COLUMNS", "LIST COLUMNS"} {
		t.Run(method, func(t *testing.T) {
			sub := name + strings.ReplaceAll(method, " ", "")
			sq := QuoteIdentifier(sub)
			boundSQL := "VALUES LESS THAN ('m')"
			kind := "range"
			if method == "LIST COLUMNS" {
				boundSQL = "VALUES IN ('', 'NULL')"
				kind = "list"
			}
			run(t, s, "CREATE TABLE "+sq+"(label varchar(40)) ENGINE=InnoDB PARTITION BY "+method+"(label)(PARTITION p0 "+boundSQL+")")
			defer run(t, s, "DROP TABLE IF EXISTS "+sq)
			bound := tableedit.PhysicalBound{Kind: kind}
			z := "z"
			if kind == "range" {
				bound.To = []tableedit.PhysicalValue{{Kind: "text", Value: &z}}
			} else {
				bound.Values = [][]tableedit.PhysicalValue{{{Kind: "text", Value: &z}}}
			}
			draft := tableedit.PhysicalDraft{Version: 1, Target: tableedit.Target{Schema: target.Schema, Table: sub}, Intent: tableedit.PhysicalIntent{Kind: "addPartition", Definitions: []tableedit.PhysicalPartitionDefinition{{Name: "p1", Bound: bound}}, Algorithm: "INPLACE", Lock: "NONE"}}
			myE6Apply(t, s, draft)
		})
	}
}

func TestPhysicalMySQLGeneratedCopyPreservesDependenciesAndExactValuesLive(t *testing.T) {
	s := integrationSession(t)
	name := fmt.Sprintf("e6_generated_%d", time.Now().UnixNano())
	q := QuoteIdentifier(name)
	run(t, s, "SET SESSION sql_mode=CONCAT(@@sql_mode,',NO_AUTO_VALUE_ON_ZERO')")
	run(t, s, "CREATE TABLE "+q+"(id bigint NOT NULL AUTO_INCREMENT PRIMARY KEY,note varchar(40) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT 'NULL' COMMENT 'retained',amount decimal(30,8),payload varbinary(20),stored_value decimal(31,8) GENERATED ALWAYS AS (amount+1) STORED,virtual_value decimal(32,8) GENERATED ALWAYS AS (stored_value*2) VIRTUAL) ENGINE=InnoDB ROW_FORMAT=DYNAMIC COMMENT='generated retained'")
	defer run(t, s, "DROP TABLE IF EXISTS "+q)
	run(t, s, "INSERT INTO "+q+"(id,note,amount,payload) VALUES(0,'',9007199254740993.12345678,X'00FF'),(2,NULL,NULL,NULL),(3,'NULL',-0.00000001,X'')")
	target := tableedit.Target{Schema: integrationSettings(t).Database, Table: name}
	before, e := s.readStructurePhysical(target, true)
	if e != nil {
		t.Fatal(e)
	}
	query := "SELECT id,note,amount,HEX(payload),stored_value,virtual_value FROM " + q + " ORDER BY id"
	rows, e := s.myPhysicalRows(query)
	if e != nil || len(rows) != 3 {
		t.Fatal("nonempty generated value fixture unavailable")
	}
	if myText(rows[0], 0) != "0" || myText(rows[0], 2) != "9007199254740993.12345678" || myText(rows[0], 4) != "9007199254740994.12345678" || myText(rows[0], 5) != "18014398509481988.24691356" {
		t.Fatal("generated exact-value controls invalid")
	}
	d := tableedit.PhysicalDraft{Version: 1, Target: target, Intent: tableedit.PhysicalIntent{Kind: "reorderColumns", ColumnOrder: []string{"payload", "amount", "stored_value", "virtual_value", "note", "id"}, Algorithm: "COPY", Lock: "SHARED"}}
	myE6Apply(t, s, d)
	after, e := s.readStructurePhysical(target, true)
	if e != nil || !mysqlReconstructionPreserved(before, after) || !myPhysicalPreserved(before, after, "reorderColumns", d.Intent.ColumnOrder) {
		t.Fatal("generated native definitions/dependencies changed")
	}
	observed, e := s.myPhysicalRows(query)
	if e != nil || !reflect.DeepEqual(rows, observed) {
		t.Fatal("COPY changed zero ID, SQL NULL, empty/text NULL, exact numeric/binary or generated results")
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
