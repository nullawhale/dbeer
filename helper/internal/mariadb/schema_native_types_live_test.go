package mariadb

import (
	"context"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"encoding/base64"
	"fmt"
	wire "github.com/go-mysql-org/go-mysql/mysql"
	"strings"
	"testing"
)

func TestMariaDBSchemaNativeBinaryEnumAndHiddenKey(t *testing.T) {
	owner := schemaNativeAdmin(t)
	name := fmt.Sprintf("data_types_%d", owner.connectionID)
	schema := QuoteIdentifier(name)
	dataRun(t, owner, "CREATE DATABASE "+schema)
	t.Cleanup(func() {
		owner.Execute(context.Background(), protocol.Command{SQL: "DROP DATABASE IF EXISTS " + schema})
	})
	dataRun(t, owner, "CREATE TABLE "+schema+".`binary_labels`(id INT PRIMARY KEY,e ENUM(x'ff',x'00',x'4e554c4c') CHARACTER SET binary DEFAULT x'ff',s SET(x'ff',x'4e554c4c') CHARACTER SET binary DEFAULT x'ff',u UUID DEFAULT '12345678-1234-1234-1234-123456789abc',ip4 INET4 DEFAULT '192.0.2.9',ip6 INET6 DEFAULT '2001:db8::9') ENGINE=InnoDB")
	dataRun(t, owner, "INSERT INTO "+schema+".`binary_labels`(id) VALUES(1),(2)")
	dataRun(t, owner, "CREATE TABLE "+schema+".`hidden_key`(id INT PRIMARY KEY,v VARCHAR(8)) ENGINE=InnoDB WITH SYSTEM VERSIONING")
	dataRun(t, owner, "INSERT INTO "+schema+".`hidden_key` VALUES(1,'before')")
	dataRun(t, owner, "UPDATE "+schema+".`hidden_key` SET v='after' WHERE id=1")
	limits := sc.Limits{Nodes: 256, Members: 8192, Bytes: 8 << 20, Scalar: 65536}
	sink := sc.NewCollector(context.Background(), limits)
	if e := owner.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{name}, Limits: limits}, sink); e != nil {
		t.Fatalf("native type capture unavailable: %v", e)
	}
	for _, table := range sink.Capture.Tables {
		switch table.Ref.Name {
		case "binary_labels":
			for _, column := range table.Columns.Items {
				if column.Ref.Name == "u" || strings.HasPrefix(column.Ref.Name, "ip") {
					if column.Type.Value == nil || column.Type.Value.Modifiers.State != "known" {
						t.Fatal("native UUID/INET fixed type metadata unavailable")
					}
				}

				if column.Ref.Name == "e" || column.Ref.Name == "s" {
					if column.Type.Value == nil || column.Type.Value.Labels.Complete || column.Type.Value.Labels.Code != "nativeBinaryLabels" || len(column.Type.Value.Labels.Items) != 0 {
						t.Fatal("lossy native binary label universe gained complete equality")
					}

					if column.Default.Value == nil || column.Default.Value.Value == nil || column.Default.Value.Encoding != "base64" || *column.Default.Value.Value != base64.StdEncoding.EncodeToString([]byte{255}) {
						t.Fatal("native binary enum/set stored default bytes changed")
					}
				}
			}
		case "hidden_key":
			found := false
			for _, key := range table.Constraints.Items {
				if key.Kind.Value != nil && *key.Kind.Value == "p" {
					found = len(key.Columns.Items) == 2
				}
			}
			if !found || len(table.Columns.Items) != 2 {
				t.Fatal("native implicit-period primary key provenance was incomplete")
			}
		}
	}
}

func TestMariaDBSchemaNativeEncodingAndPolicies(t *testing.T) {
	owner := schemaNativeAdmin(t)
	name := fmt.Sprintf("data_policy_%d", owner.connectionID)
	schema := QuoteIdentifier(name)
	dataRun(t, owner, "CREATE DATABASE "+schema+" CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
	t.Cleanup(func() {
		owner.Execute(context.Background(), protocol.Command{SQL: "DROP DATABASE IF EXISTS " + schema})
	})
	for _, table := range []string{"Ã¤", "ä"} {
		dataRun(t, owner, "CREATE TABLE "+schema+"."+QuoteIdentifier(table)+"(id INT) ENGINE=InnoDB")
	}
	dataRun(t, owner, "CREATE TABLE "+schema+".`h`(id INT PRIMARY KEY,v VARCHAR(8) WITHOUT SYSTEM VERSIONING) ENGINE=InnoDB WITH SYSTEM VERSIONING")
	dataRun(t, owner, "INSERT INTO "+schema+".`h` VALUES(1,'a')")
	limits := sc.Limits{Nodes: 256, Members: 8192, Bytes: 8 << 20, Scalar: 65536}
	capture := func() *sc.Collector {
		sink := sc.NewCollector(context.Background(), limits)
		if e := owner.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{name}, Limits: limits}, sink); e != nil {
			t.Fatalf("policy capture unavailable: %v", e)
		}
		return sink
	}
	without := capture()
	dataRun(t, owner, "DROP TABLE "+schema+".`h`")
	dataRun(t, owner, "CREATE TABLE "+schema+".`h`(id INT PRIMARY KEY,v VARCHAR(8)) ENGINE=InnoDB WITH SYSTEM VERSIONING")
	dataRun(t, owner, "INSERT INTO "+schema+".`h` VALUES(1,'a')")
	with := capture()
	option := func(c *sc.Collector) bool {
		for _, table := range c.Capture.Tables {
			if table.Ref.Name == "h" {
				for _, o := range table.Options.Items {
					if o.Name == "columnSystemVersioning:v" && o.Value == "without" {
						return true
					}
				}
			}
		}
		return false
	}
	if !option(without) || option(with) {
		t.Fatal("native excluded-column versioning policy was silently equal")
	}
	for _, variable := range []string{"character_set_results", "character_set_client", "character_set_connection"} {
		t.Run(variable, func(t *testing.T) {
			dataRun(t, owner, "SET SESSION "+variable+"='latin1'")
			sink := sc.NewCollector(context.Background(), limits)
			if e := owner.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{name}, Limits: limits}, sink); e == nil || len(sink.Capture.Tables) != 0 {
				t.Fatal("changed metadata encoding admitted colliding Unicode identities")
			}
			state := dataRun(t, owner, "SELECT @@SESSION."+variable).Rows
			if len(state) != 1 || state[0][0] == nil || *state[0][0] != "latin1" || owner.closed.Load() {
				t.Fatal("metadata encoding refusal mutated or closed the owner")
			}
			dataRun(t, owner, "SET SESSION "+variable+"='utf8mb4'")
		})
	}
	_ = capture()
}

func TestMariaDBSchemaNativePartitionDefinitions(t *testing.T) {
	owner := schemaNativeAdmin(t)
	name := fmt.Sprintf("data_parts_%d", owner.connectionID)
	schema := QuoteIdentifier(name)
	dataRun(t, owner, "CREATE DATABASE "+schema+" CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
	t.Cleanup(func() {
		owner.Execute(context.Background(), protocol.Command{SQL: "DROP DATABASE IF EXISTS " + schema})
	})
	for _, sql := range []string{
		"CREATE TABLE " + schema + ".`hash2`(id INT,v INT) ENGINE=InnoDB PARTITION BY HASH(id) PARTITIONS 2",
		"CREATE TABLE " + schema + ".`hash3`(id INT,v INT) ENGINE=InnoDB PARTITION BY HASH(id) PARTITIONS 3",
		"CREATE TABLE " + schema + ".`hash_key`(id INT,v INT) ENGINE=InnoDB PARTITION BY HASH(v) PARTITIONS 2",
		"CREATE TABLE " + schema + ".`range_a`(id INT) ENGINE=InnoDB PARTITION BY RANGE(id)(PARTITION p0 VALUES LESS THAN(10),PARTITION p1 VALUES LESS THAN MAXVALUE)",
		"CREATE TABLE " + schema + ".`range_b`(id INT) ENGINE=InnoDB PARTITION BY RANGE(id)(PARTITION p0 VALUES LESS THAN(20),PARTITION p1 VALUES LESS THAN MAXVALUE)",
		"CREATE TABLE " + schema + ".`strings_a`(v VARCHAR(20)) ENGINE=InnoDB PARTITION BY LIST COLUMNS(v)(PARTITION p0 VALUES IN('é','Ã¤'))",
		"CREATE TABLE " + schema + ".`strings_b`(v VARCHAR(20)) ENGINE=InnoDB PARTITION BY LIST COLUMNS(v)(PARTITION p0 VALUES IN('é','ä'))",
		"CREATE TABLE " + schema + ".`binary_a`(v VARBINARY(8)) ENGINE=InnoDB PARTITION BY LIST COLUMNS(v)(PARTITION p0 VALUES IN(x'ff'))",
		"CREATE TABLE " + schema + ".`binary_b`(v VARBINARY(8)) ENGINE=InnoDB PARTITION BY LIST COLUMNS(v)(PARTITION p0 VALUES IN(x'fe'))",
	} {
		dataRun(t, owner, sql)
	}
	dataRun(t, owner, "INSERT INTO "+schema+".`hash2` VALUES(1,2),(2,3)")
	limits := sc.Limits{Nodes: 256, Members: 8192, Bytes: 8 << 20, Scalar: 65536}
	sink := sc.NewCollector(context.Background(), limits)
	if e := owner.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{name}, Limits: limits}, sink); e != nil {
		t.Fatalf("native partition facts unavailable: %v", e)
	}
	tails := map[string]string{}
	for _, table := range sink.Capture.Tables {
		for _, option := range table.Options.Items {
			if option.Name == "nativePartitionDefinition" {
				tails[table.Ref.Name] = option.Value
			}
		}
	}
	for _, pair := range [][2]string{{"hash2", "hash3"}, {"hash2", "hash_key"}, {"range_a", "range_b"}, {"strings_a", "strings_b"}, {"binary_a", "binary_b"}} {
		if tails[pair[0]] == "" || tails[pair[1]] == "" || tails[pair[0]] == tails[pair[1]] {
			t.Fatal("native partition key/count/bound bytes compared falsely equal")
		}
	}
	other := schemaNativeAdmin(t)
	changed := sc.NewCollector(context.Background(), limits)
	hook := &schemaHookSink{Sink: changed, hook: func(table sc.Table) error {
		if table.Ref.Name == "hash2" {
			result := other.Execute(context.Background(), protocol.Command{SQL: "ALTER TABLE " + schema + ".`hash2` ADD PARTITION PARTITIONS 1"})
			if result.Type != "query.result" {
				return fmt.Errorf("owned native partition control failed")
			}
		}
		return nil
	}}
	if e := owner.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{name}, Limits: limits}, hook); e != nil {
		t.Fatalf("changed native partition capture failed: %v", e)
	}
	found := false
	for _, issue := range changed.Capture.Issues {
		found = found || issue.Code == "concurrentDDL"
	}
	if !hook.reached || !found || changed.Capture.Context.Visibility != "partial" {
		t.Fatal("same-index native partition change escaped the definition witness")
	}

}

func TestMariaDBSchemaNativeViewVisibilityAndApplicationPeriods(t *testing.T) {
	admin := schemaNativeAdmin(t)
	name := fmt.Sprintf("data_view_%d", admin.connectionID)
	schema := QuoteIdentifier(name)
	external := QuoteIdentifier(name + "_external")
	dataRun(t, admin, "CREATE DATABASE "+schema)
	dataRun(t, admin, "CREATE DATABASE "+external)
	user := fmt.Sprintf("schema_global_%d", admin.connectionID)
	account := "'" + user + "'@'%'"
	password := fmt.Sprintf("private_view_%d", admin.connectionID)
	t.Cleanup(func() {
		admin.Execute(context.Background(), protocol.Command{SQL: "DROP DATABASE IF EXISTS " + external})
		admin.Execute(context.Background(), protocol.Command{SQL: "DROP DATABASE IF EXISTS " + schema})
		admin.Execute(context.Background(), protocol.Command{SQL: "DROP USER IF EXISTS " + account})
	})
	dataRun(t, admin, "CREATE TABLE "+schema+".`parent`(id INT PRIMARY KEY) ENGINE=InnoDB")
	dataRun(t, admin, "INSERT INTO "+schema+".`parent` VALUES(1),(2)")
	dataRun(t, admin, "CREATE VIEW "+external+".`dependent_view` AS SELECT id FROM "+schema+".`parent`")
	dataRun(t, admin, "CREATE EVENT "+external+".`dependent_event` ON SCHEDULE EVERY 1 DAY STARTS CURRENT_TIMESTAMP+INTERVAL 1 DAY DISABLE DO UPDATE "+schema+".`parent` SET id=id")
	dataRun(t, admin, "CREATE USER "+account+" IDENTIFIED BY '"+password+"'")
	dataRun(t, admin, "GRANT SELECT,TRIGGER,EVENT ON *.* TO "+account)
	dataRun(t, admin, "GRANT INSERT ON "+schema+".* TO "+account)
	settings := dataIntegrationSettings(t)
	settings.User = user
	settings.Password = password
	settings.Database = name
	opened, e := Open(context.Background(), settings)
	if e != nil {
		t.Fatal("owned global-metadata session unavailable")
	}
	restricted := opened.(*Session)
	defer restricted.Close()
	metadata := dataRun(t, admin, "SELECT ENGINE,TABLE_COLLATION,CREATE_OPTIONS,TABLE_COMMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA='"+name+"' AND TABLE_NAME='parent'").Rows
	facts := func(s *Session) *tableedit.Facts {
		var f *tableedit.Facts
		var err error
		response := s.executeWith(context.Background(), protocol.Command{}, func(_ *collector, _ *wire.Result) error {
			f, err = s.readStructureFacts(tableedit.Target{Schema: name, Table: "parent"}, *metadata[0][0], *metadata[0][1], *metadata[0][2], *metadata[0][3])
			return err
		})
		if response.Type != "query.result" || err != nil || f == nil {
			t.Fatal("bounded view visibility facts unavailable")
		}
		return f
	}
	if facts(restricted).Proof {
		t.Fatal("global SELECT/TRIGGER/EVENT gained unproven SHOW VIEW visibility")
	}
	dataRun(t, admin, "GRANT SHOW VIEW ON *.* TO "+account)
	originalID := restricted.connectionID
	dataRun(t, restricted, "BEGIN")
	dataRun(t, restricted, "INSERT INTO "+schema+".`parent` VALUES(3)")
	if *dataRun(t, admin, "SELECT COUNT(*) FROM "+schema+".`parent`").Rows[0][0] != "2" {
		t.Fatal("metadata owner transaction was visible before inspection")
	}
	freshFacts := facts(restricted)
	observedView := false
	for _, dependent := range freshFacts.Dependents[""] {
		observedView = observedView || dependent == name+"_external.dependent_view"
	}
	if !freshFacts.Proof || !observedView || restricted.connectionID != originalID || restricted.TransactionStatus() != "transaction" || *dataRun(t, admin, "SELECT COUNT(*) FROM "+schema+".`parent`").Rows[0][0] != "2" {
		t.Fatal("fresh global metadata failed binding or altered the owning transaction")
	}
	dataRun(t, restricted, "ROLLBACK")

	// Global privilege changes take effect on a freshly authenticated session.
	opened, e = Open(context.Background(), settings)
	if e != nil {
		t.Fatal("owned refreshed metadata session unavailable")
	}
	refreshed := opened.(*Session)
	defer refreshed.Close()
	complete := facts(refreshed)
	if !complete.Proof {
		t.Fatal("complete native view/event visibility was not admitted")
	}
	view, event := false, false
	for _, dependent := range complete.Dependents[""] {
		view = view || dependent == name+"_external.dependent_view"
		event = event || dependent == name+"_external.dependent_event"
	}
	if !view || !event {
		t.Fatalf("external native dependency unavailable: view=%t event=%t", view, event)
	}
	dataRun(t, admin, "CREATE TABLE "+schema+".`application_time`(id INT,valid_start DATE,valid_end DATE,PERIOD FOR valid_time(valid_start,valid_end)) ENGINE=InnoDB")
	dataRun(t, admin, "INSERT INTO "+schema+".`application_time` VALUES(1,'2024-01-01','2025-01-01')")
	limits := sc.Limits{Nodes: 256, Members: 8192, Bytes: 8 << 20, Scalar: 65536}
	sink := sc.NewCollector(context.Background(), limits)
	if e := admin.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{name}, Limits: limits}, sink); e != nil {
		t.Fatal("native application-period capture unavailable")
	}
	found := false
	for _, issue := range sink.Capture.Issues {
		found = found || issue.Code == "nativeApplicationPeriod"
	}
	if !found {
		t.Fatal("application-time period gained false ordinary equality")
	}
	for _, table := range sink.Capture.Tables {
		if table.Ref.Name == "application_time" {
			if table.Options.Complete {
				t.Fatal("application-time native properties gained portable completeness")
			}
			found = false
			for _, option := range table.Options.Items {
				found = found || option.Name == "nativeApplicationPeriod"
			}
			if !found {
				t.Fatal("application-time exact native clause was omitted")
			}
		}
	}
}

func TestMariaDBSchemaNativeSupplementaryDefaults(t *testing.T) {
	owner := schemaNativeAdmin(t)
	name := fmt.Sprintf("data_unicode_%d", owner.connectionID)
	schema := QuoteIdentifier(name)
	dataRun(t, owner, "CREATE DATABASE "+schema+" CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
	t.Cleanup(func() {
		owner.Execute(context.Background(), protocol.Command{SQL: "DROP DATABASE IF EXISTS " + schema})
	})
	dataRun(t, owner, "CREATE TABLE "+schema+".`t`(id INT,v VARCHAR(16) DEFAULT '😀',e ENUM('😀','ordinary') DEFAULT '😀') ENGINE=InnoDB")
	dataRun(t, owner, "INSERT INTO "+schema+".`t`(id) VALUES(1),(2)")
	limits := sc.Limits{Nodes: 256, Members: 8192, Bytes: 8 << 20, Scalar: 65536}
	sink := sc.NewCollector(context.Background(), limits)
	if e := owner.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{name}, Limits: limits}, sink); e != nil {
		t.Fatal("supplementary native capture unavailable")
	}
	if len(sink.Capture.Tables) != 1 {
		t.Fatal("supplementary native fixture missing")
	}
	for _, column := range sink.Capture.Tables[0].Columns.Items {
		if column.Ref.Name == "v" || column.Ref.Name == "e" {
			if column.Default.Value == nil || column.Default.Value.Value == nil || *column.Default.Value.Value != "😀" {
				t.Error("supplementary stored default bytes changed")
			}
			if column.Ref.Name == "e" && (column.Type.Value == nil || column.Type.Value.Labels.Complete || column.Type.Value.Labels.Code != "nativeWideLabels") {
				t.Error("unproven supplementary label domain gained complete equality")
			}

		}
	}
}
