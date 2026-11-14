package mariadb

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"reflect"
	"testing"

	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func schemaNativeAdmin(t *testing.T) *Session {
	t.Helper()
	settings := dataIntegrationSettings(t)
	if os.Getenv("DBEER_TEST_MARIADB_ADMIN_USER") == "" {
		if os.Getenv("DBEER_REQUIRE_MARIADB_SCHEMA") == "1" {
			t.Fatal("required owned schema administrator unavailable")
		}
		t.Skip("owned schema administrator is not configured")
	}
	settings.User, settings.Password = os.Getenv("DBEER_TEST_MARIADB_ADMIN_USER"), os.Getenv("DBEER_TEST_MARIADB_ADMIN_PASSWORD")
	opened, e := Open(context.Background(), settings)
	if e != nil {
		t.Fatal("owned native schema session unavailable")
	}
	s := opened.(*Session)
	t.Cleanup(s.Close)
	return s
}
func TestMariaDBSchemaNativeCapture(t *testing.T) {
	s := schemaNativeAdmin(t)
	name := fmt.Sprintf("data_schema_%d", s.connectionID)
	schema := QuoteIdentifier(name)
	qual := func(table string) string { return schema + "." + QuoteIdentifier(table) }
	dataRun(t, s, "CREATE DATABASE "+schema+" CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
	t.Cleanup(func() { s.Execute(context.Background(), protocol.Command{SQL: "DROP DATABASE IF EXISTS " + schema}) })
	dataRun(t, s, "CREATE SEQUENCE "+qual("seq")+" START WITH 9007199254741105 INCREMENT BY 7 CACHE 17 ENGINE=InnoDB")
	dataRun(t, s, "CREATE TABLE "+qual("ordinary")+" (id BIGINT(20) UNSIGNED NOT NULL AUTO_INCREMENT,n DECIMAL(65,38) DEFAULT 0.125,empty_value VARCHAR(32) DEFAULT '',text_null VARCHAR(32) DEFAULT 'NULL',sql_null VARCHAR(32) DEFAULT NULL,binary_value VARBINARY(8) DEFAULT x'00ff5c27',expr VARCHAR(32) DEFAULT (concat('A','B')),bits BIT(8) DEFAULT b'10000001',g DECIMAL(65,38) AS(n+1) PERSISTENT,choice ENUM('a','q''s','slash\\\\value') DEFAULT 'a',payload JSON DEFAULT '{\"x\":1,\"x\":2}',next_value BIGINT DEFAULT(NEXT VALUE FOR "+qual("seq")+"),PRIMARY KEY(id),KEY ignored_prefix(text_null(7) DESC) IGNORED,CONSTRAINT native_check CHECK(n>=0)) ENGINE=InnoDB")
	dataRun(t, s, "INSERT INTO "+qual("ordinary")+"(id,n) VALUES(11,1),(12,2)")
	dataRun(t, s, "CREATE TABLE "+qual("partitioned")+"(id INT PRIMARY KEY,v VARBINARY(8)) ENGINE=InnoDB PARTITION BY HASH(id) PARTITIONS 2")
	dataRun(t, s, "CREATE TABLE "+qual("aria")+"(id INT,n VARCHAR(8)) ENGINE=Aria")
	dataRun(t, s, "CREATE TABLE "+qual("myisam")+"(id INT,n VARCHAR(8)) ENGINE=MyISAM")
	dataRun(t, s, "CREATE TABLE "+qual("history")+"(id INT,rs TIMESTAMP(6) GENERATED ALWAYS AS ROW START,re TIMESTAMP(6) GENERATED ALWAYS AS ROW END,PERIOD FOR SYSTEM_TIME(rs,re)) ENGINE=InnoDB WITH SYSTEM VERSIONING")
	dataRun(t, s, "INSERT INTO "+qual("history")+"(id) VALUES(1)")
	dataRun(t, s, "CREATE TABLE "+qual("implicit_history")+"(id INT,n VARCHAR(8)) ENGINE=InnoDB WITH SYSTEM VERSIONING")
	dataRun(t, s, "INSERT INTO "+qual("implicit_history")+" VALUES(1,'before')")
	dataRun(t, s, "UPDATE "+qual("implicit_history")+" SET n='after' WHERE id=1")
	dataRun(t, s, "CREATE TABLE "+qual("transaction_history")+"(id INT,rs BIGINT UNSIGNED GENERATED ALWAYS AS ROW START,re BIGINT UNSIGNED GENERATED ALWAYS AS ROW END,PERIOD FOR SYSTEM_TIME(rs,re)) ENGINE=InnoDB WITH SYSTEM VERSIONING")
	before := dataRun(t, s, "SELECT CAST(next_not_cached_value AS CHAR) FROM "+qual("seq")).Rows
	limits := sc.Limits{Nodes: 256, Members: 8192, Bytes: 8 << 20, Scalar: 65536}
	sink := sc.NewCollector(context.Background(), limits)
	if e := s.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{name}, Limits: limits}, sink); e != nil {
		t.Fatalf("native schema capture failed: %v", e)
	}
	if len(sink.Capture.Tables) != 7 || len(sink.Capture.Sequences) != 1 || sink.Capture.Context.Engine != "mariadb" {
		t.Fatal("native table/history/sequence catalog separation changed")
	}
	for _, table := range sink.Capture.Tables {
		if table.Ref.Name == "implicit_history" || table.Ref.Name == "history" || table.Ref.Name == "transaction_history" {
			found := 0
			for _, option := range table.Options.Items {
				if option.Name == "systemPeriod:ROW START" || option.Name == "systemPeriod:ROW END" {
					var p MariaDBPeriodColumn
					if json.Unmarshal([]byte(option.Value), &p) != nil || p.Implicit != (table.Ref.Name == "implicit_history") {
						t.Fatal("native period provenance changed")
					}
					found++
				}
			}
			if found != 2 {
				t.Fatal("native period pair missing")
			}
			if table.Ref.Name == "implicit_history" && len(table.Columns.Items) != 2 {
				t.Fatal("implicit periods fabricated ordinary column ordinals")
			}
		}
	}
	after := dataRun(t, s, "SELECT CAST(next_not_cached_value AS CHAR) FROM "+qual("seq")).Rows
	if len(before) != 1 || len(after) != 1 || before[0][0] == nil || after[0][0] == nil || *before[0][0] != *after[0][0] {
		t.Fatal("inspection evaluated a native sequence default")
	}
	var ordinary sc.Table
	for _, table := range sink.Capture.Tables {
		if table.Ref.Name == "ordinary" {
			ordinary = table
		}
	}
	defaults := map[string]sc.Default{}
	for _, column := range ordinary.Columns.Items {
		if column.Default.Value != nil {
			defaults[column.Ref.Name] = *column.Default.Value
		}
	}
	if defaults["empty_value"].Kind != "literal" || defaults["text_null"].Kind != "literal" || defaults["sql_null"].Kind != "sqlNull" || defaults["expr"].Kind != "expression" || defaults["next_value"].Kind != "expression" {
		t.Fatal("native defaults were conflated or evaluated")
	}
	if defaults["binary_value"].Encoding != "base64" || defaults["binary_value"].Value == nil || *defaults["binary_value"].Value != base64.StdEncoding.EncodeToString([]byte{0, 255, 92, 39}) {
		t.Fatal("native binary default field lost exact bytes")

	}
	for _, column := range ordinary.Columns.Items {
		if column.Ref.Name == "choice" && (column.Type.Value == nil || !column.Type.Value.Labels.Complete || len(column.Type.Value.Labels.Items) != 3 || column.Type.Value.Labels.Items[1] != "q's") {
			t.Fatal("native enum label metadata is incomplete or changed")
		}
	}
	metadata := dataRun(t, s, "SELECT ENGINE,TABLE_COLLATION,CREATE_OPTIONS,TABLE_COMMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA='"+name+"' AND TABLE_NAME='ordinary'").Rows
	if len(metadata) != 1 || len(metadata[0]) != 4 {
		t.Fatal("native structure metadata fixture missing")
	}
	var facts *tableedit.Facts
	var captureErr error
	response := s.executeWith(context.Background(), protocol.Command{}, func(_ *collector, _ *wire.Result) error {
		facts, captureErr = s.readStructureFacts(tableedit.Target{Schema: name, Table: "ordinary"}, *metadata[0][0], *metadata[0][1], *metadata[0][2], *metadata[0][3])
		return captureErr
	})
	if captureErr != nil || response.Type != "query.result" || facts == nil {
		t.Fatal("complete native structure facts unavailable")
	}
	if !facts.Proof || len(facts.Table.Columns.Items) != 12 {
		t.Fatal("native privilege proof or complete column facts missing")
	}
}

func TestMariaDBSchemaNativeIncomingAndDrift(t *testing.T) {
	s, other := schemaNativeAdmin(t), schemaNativeAdmin(t)
	name := fmt.Sprintf("data_facts_%d", s.connectionID)
	owner := name + "_owner"
	schema := QuoteIdentifier(name)
	owned := QuoteIdentifier(owner)
	qual := schema + ".`parent`"
	dataRun(t, s, "CREATE DATABASE "+schema)
	dataRun(t, s, "CREATE DATABASE "+owned)
	t.Cleanup(func() {
		s.Execute(context.Background(), protocol.Command{SQL: "DROP DATABASE IF EXISTS " + owned})
		s.Execute(context.Background(), protocol.Command{SQL: "DROP DATABASE IF EXISTS " + schema})
	})
	dataRun(t, s, "CREATE TABLE "+qual+"(a INT,b INT,CONSTRAINT pair UNIQUE(a,b),CONSTRAINT same_check CHECK(a>=0)) ENGINE=InnoDB")
	dataRun(t, s, "CREATE TABLE "+schema+".`check_other`(a INT,CONSTRAINT same_check CHECK(a<100)) ENGINE=InnoDB")
	dataRun(t, s, "CREATE TABLE "+owned+".`child`(x INT,y INT,CONSTRAINT cross_pair FOREIGN KEY(x,y) REFERENCES "+qual+"(a,b) ON DELETE SET NULL) ENGINE=InnoDB")
	dataRun(t, s, "INSERT INTO "+qual+" VALUES(1,2)")
	dataRun(t, s, "INSERT INTO "+owned+".`child` VALUES(1,2),(NULL,NULL)")
	meta := dataRun(t, s, "SELECT ENGINE,TABLE_COLLATION,CREATE_OPTIONS,TABLE_COMMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA='"+name+"' AND TABLE_NAME='parent'").Rows
	var f *tableedit.Facts
	var captureErr error
	response := s.executeWith(context.Background(), protocol.Command{}, func(_ *collector, _ *wire.Result) error {
		f, captureErr = s.readStructureFacts(tableedit.Target{Schema: name, Table: "parent"}, *meta[0][0], *meta[0][1], *meta[0][2], *meta[0][3])
		return captureErr
	})
	if response.Type != "query.result" || captureErr != nil || f == nil || !f.Proof || len(f.Incoming) != 1 || f.Incoming[0].Schema != owner || f.Incoming[0].Name != "cross_pair" || len(f.Incoming[0].Columns) != 2 || f.Incoming[0].Columns[0] != "a" || f.Incoming[0].Columns[1] != "b" {
		if captureErr != nil || f == nil {
			t.Fatalf("incoming facts unavailable: category=%v response=%s", captureErr, response.Type)
		}
		t.Fatalf("incoming facts mismatch: proof=%t count=%d", f.Proof, len(f.Incoming))
	}
	limits := sc.Limits{Nodes: 256, Members: 8192, Bytes: 8 << 20, Scalar: 65536}
	collector := sc.NewCollector(context.Background(), limits)
	sink := &schemaHookSink{Sink: collector, hook: func(table sc.Table) error {
		if table.Ref.Name == "parent" {
			r := other.Execute(context.Background(), protocol.Command{SQL: "ALTER TABLE " + qual + " COMMENT='late metadata'"})
			if r.Type != "query.result" {
				return errors.New("owned late metadata change failed")
			}
		}
		return nil
	}}
	if e := s.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{name}, Limits: limits}, sink); e != nil {
		t.Fatalf("late metadata reader control failed: %v", e)
	}
	changed := false
	for _, issue := range collector.Capture.Issues {
		changed = changed || issue.Code == "concurrentDDL"
	}
	if !changed || collector.Capture.Context.Visibility != "partial" || !sink.reached {
		t.Fatal("late native metadata change was not detected")
	}
	dataRun(t, s, "BEGIN")
	dataRun(t, s, "INSERT INTO "+qual+" VALUES(3,4)")
	if s.TransactionStatus() != "transaction" {
		t.Fatal("transaction control was not active before metadata")
	}
	if *dataRun(t, other, "SELECT COUNT(*) FROM "+qual).Rows[0][0] != "1" {
		t.Fatal("transaction control was already visible outside its owner")
	}
	failure := errors.New("controlled native schema sink failure")
	failed := &schemaHookSink{Sink: sc.NewCollector(context.Background(), limits), hook: func(sc.Table) error { return failure }}
	if e := s.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{name}, Limits: limits}, failed); !errors.Is(e, failure) {
		t.Fatal("sink failure was not returned")
	}
	if s.closed.Load() || s.TransactionStatus() != "transaction" {
		t.Errorf("bounded sink state: closed=%t transaction=%s", s.closed.Load(), s.TransactionStatus())
	}
	if *dataRun(t, other, "SELECT COUNT(*) FROM "+qual).Rows[0][0] != "1" {
		t.Error("metadata failure committed the owning transaction")
	}
	dataRun(t, s, "ROLLBACK")
	if *dataRun(t, other, "SELECT COUNT(*) FROM "+qual).Rows[0][0] != "1" {
		t.Fatal("metadata control rollback lost the original rows")
	}
}

type schemaHookSink struct {
	sc.Sink
	hook    func(sc.Table) error
	reached bool
}

func (s *schemaHookSink) Table(v sc.Table) error {
	s.reached = true
	if e := s.hook(v); e != nil {
		return e
	}
	return s.Sink.Table(v)
}

func TestMariaDBSchemaNativeFieldListDefaults(t *testing.T) {
	owner, inspector := schemaNativeAdmin(t), schemaNativeAdmin(t)
	name := fmt.Sprintf("data_wire_defaults_%d", owner.connectionID)
	schema := QuoteIdentifier(name)
	table := schema + ".`native_defaults`"
	sequence := schema + ".`seq`"
	dataRun(t, owner, "CREATE DATABASE "+schema)
	t.Cleanup(func() {
		owner.Execute(context.Background(), protocol.Command{SQL: "DROP DATABASE IF EXISTS " + schema})
	})
	dataRun(t, owner, "CREATE SEQUENCE "+sequence+" START WITH 9007199254741105 CACHE 17")
	dataRun(t, owner, "CREATE TABLE "+table+"(id INT,bin VARBINARY(8) DEFAULT x'00ff5c27',empty_bin VARBINARY(8) DEFAULT '',next_id BIGINT DEFAULT(NEXT VALUE FOR "+sequence+")) ENGINE=InnoDB")
	dataRun(t, owner, "BEGIN")
	dataRun(t, owner, "INSERT INTO "+table+"(id) VALUES(1)")
	if owner.TransactionStatus() != "transaction" {
		t.Fatal("owner transaction control is inactive")
	}
	fields := map[string][]byte{}
	response := inspector.executeWith(context.Background(), protocol.Command{}, func(_ *collector, _ *wire.Result) error {
		if e := inspector.work.client.UseDB(name); e != nil {
			return e
		}
		loaded, e := inspector.work.client.FieldList("native_defaults", "")
		if e != nil {
			return e
		}
		for _, field := range loaded {
			fields[string(field.Name)] = append([]byte(nil), field.DefaultValue...)
		}
		return nil
	})
	if response.Type != "query.result" || !reflect.DeepEqual(fields["bin"], []byte{0, 255, 92, 39}) || len(fields["empty_bin"]) != 0 {
		t.Fatal("native FieldList did not preserve exact stored default bytes")
	}
	if dataRun(t, inspector, "SELECT PREVIOUS VALUE FOR "+sequence).Rows[0][0] != nil {
		t.Fatal("native field inspection evaluated a sequence default")
	}
	if owner.TransactionStatus() != "transaction" || *dataRun(t, inspector, "SELECT COUNT(*) FROM "+table).Rows[0][0] != "0" {
		t.Fatal("independent metadata observation changed the owning transaction")
	}
	dataRun(t, owner, "ROLLBACK")
}

func TestMariaDBSchemaNativeDefaultDriftAndCounter(t *testing.T) {
	owner, other := schemaNativeAdmin(t), schemaNativeAdmin(t)
	name := fmt.Sprintf("data_fresh_%d", owner.connectionID)
	schema := QuoteIdentifier(name)
	table := schema + ".`t`"
	dataRun(t, owner, "CREATE DATABASE "+schema+" CHARACTER SET utf8mb4")
	t.Cleanup(func() {
		owner.Execute(context.Background(), protocol.Command{SQL: "DROP DATABASE IF EXISTS " + schema})
	})
	dataRun(t, owner, "CREATE TABLE "+table+"(id BIGINT AUTO_INCREMENT PRIMARY KEY,b VARBINARY(8) DEFAULT x'00ff5c27',v VARCHAR(8),KEY k(v(3) DESC) IGNORED) ENGINE=InnoDB")
	dataRun(t, owner, "INSERT INTO "+table+"(v) VALUES('one'),('two')")
	limits := sc.Limits{Nodes: 256, Members: 8192, Bytes: 8 << 20, Scalar: 65536}
	for _, test := range []struct {
		name, sql string
		changed   bool
	}{
		{"counterOnly", "INSERT INTO " + table + "(v) VALUES('three')", false},
		{"binaryDefault", "ALTER TABLE " + table + " ALTER COLUMN b SET DEFAULT x'00fe5c27'", true},
		{"indexProperty", "ALTER TABLE " + table + " ALTER INDEX k NOT IGNORED", true},
	} {
		t.Run(test.name, func(t *testing.T) {
			collected := sc.NewCollector(context.Background(), limits)
			sink := &schemaHookSink{Sink: collected, hook: func(sc.Table) error {
				if result := other.Execute(context.Background(), protocol.Command{SQL: test.sql}); result.Type != "query.result" {
					return errors.New("owned drift control failed")
				}
				return nil
			}}
			if e := owner.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{name}, Limits: limits}, sink); e != nil {
				t.Fatalf("native freshness capture failed: %v", e)
			}
			changed := false
			for _, issue := range collected.Capture.Issues {
				changed = changed || issue.Code == "concurrentDDL"
			}
			if !sink.reached || changed != test.changed {
				t.Fatal("native property drift and data-only counter movement were conflated")
			}
		})
	}
}

func TestMariaDBSchemaNativeRestrictedAndControlBinding(t *testing.T) {
	admin := schemaNativeAdmin(t)
	name := fmt.Sprintf("data_visibility_%d", admin.connectionID)
	schema := QuoteIdentifier(name)
	user := fmt.Sprintf("schema_reader_%d", admin.connectionID)
	password := fmt.Sprintf("private_owned_%d_reader", admin.connectionID)
	account := "'" + user + "'@'%'"
	dataRun(t, admin, "CREATE DATABASE "+schema)
	t.Cleanup(func() {
		admin.Execute(context.Background(), protocol.Command{SQL: "DROP DATABASE IF EXISTS " + schema})
		admin.Execute(context.Background(), protocol.Command{SQL: "DROP USER IF EXISTS " + account})
	})
	dataRun(t, admin, "CREATE TABLE "+schema+".`t`(id INT,b VARBINARY(8) DEFAULT x'00ff5c27') ENGINE=InnoDB")
	dataRun(t, admin, "INSERT INTO "+schema+".`t`(id) VALUES(1),(2)")
	dataRun(t, admin, "CREATE USER "+account+" IDENTIFIED BY '"+password+"'")
	dataRun(t, admin, "GRANT SELECT ON "+schema+".* TO "+account)
	settings := dataIntegrationSettings(t)
	settings.User = user
	settings.Password = password
	settings.Database = name
	opened, e := Open(context.Background(), settings)
	if e != nil {
		t.Fatal("owned restricted session unavailable")
	}
	restricted := opened.(*Session)
	defer restricted.Close()
	var facts *tableedit.Facts
	var captureErr error
	meta := dataRun(t, admin, "SELECT ENGINE,TABLE_COLLATION,CREATE_OPTIONS,TABLE_COMMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA='"+name+"' AND TABLE_NAME='t'").Rows
	result := restricted.executeWith(context.Background(), protocol.Command{}, func(_ *collector, _ *wire.Result) error {
		facts, captureErr = restricted.readStructureFacts(tableedit.Target{Schema: name, Table: "t"}, *meta[0][0], *meta[0][1], *meta[0][2], *meta[0][3])
		return captureErr
	})
	if result.Type != "query.result" || captureErr != nil || facts == nil || facts.Proof || len(facts.Dependents[""]) == 0 {
		t.Fatal("restricted native metadata gained complete dependency authority")
	}
	limits := sc.Limits{Nodes: 256, Members: 8192, Bytes: 8 << 20, Scalar: 65536}
	sink := sc.NewCollector(context.Background(), limits)
	if e := restricted.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{name}, Limits: limits}, sink); e != nil || sink.Capture.Context.Visibility != "complete" {
		t.Fatal("direct schema SELECT failed visible inventory proof")
	}
	// A differently authenticated metadata connection must not widen the owner.
	bound := schemaNativeAdmin(t)
	bound.openControl = restricted.openControl
	if e := bound.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{name}, Limits: limits}, sc.NewCollector(context.Background(), limits)); e == nil || bound.closed.Load() {
		t.Fatal("metadata actor mismatch was accepted or closed the owning session")
	}
	if *dataRun(t, bound, "SELECT COUNT(*) FROM "+schema+".`t`").Rows[0][0] != "2" {
		t.Fatal("metadata actor refusal damaged the owner")
	}
}
