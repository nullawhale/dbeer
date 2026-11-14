package schemaimport

import (
	"context"
	"dbeer/helper/internal/mariadb"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/schemabundle"
	sc "dbeer/helper/internal/schemacompare"
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"strconv"
	"testing"
)

func TestMariaDBOfflineNativeCapturedBundle(t *testing.T) {
	port, e := strconv.Atoi(os.Getenv("DBEER_TEST_MARIADB_PORT"))
	user := os.Getenv("DBEER_TEST_MARIADB_ADMIN_USER")
	if e != nil || port < 1 || user == "" {
		if os.Getenv("DBEER_REQUIRE_MARIADB") == "1" {
			t.Fatal("required native offline-capture fixture unavailable")
		}
		t.Skip("native offline-capture fixture not configured")
	}
	settings := protocol.Connection{Engine: "mariadb", Host: os.Getenv("DBEER_TEST_MARIADB_HOST"), Port: port, Database: os.Getenv("DBEER_TEST_MARIADB_DATABASE"), User: user, Password: os.Getenv("DBEER_TEST_MARIADB_ADMIN_PASSWORD"), SSLMode: "verify-full", SSLRootCert: os.Getenv("DBEER_TEST_MARIADB_CA_FILE")}
	session, e := mariadb.Open(context.Background(), settings)
	if e != nil {
		t.Fatal("native capture session unavailable")
	}
	defer session.Close()
	run := func(sql string) {
		response := session.Execute(context.Background(), protocol.Command{SQL: sql})
		if response.Type != "query.result" {
			t.Fatalf("native capture fixture SQL failed: category=%s SQLSTATE=%s", response.Category, response.SQLState)
		}
	}
	name := fmt.Sprintf("native_schema_%d", port)
	schema := mariadb.QuoteIdentifier(name)
	run("CREATE DATABASE " + schema + " CHARACTER SET utf8mb4 COLLATE utf8mb4_bin")
	t.Cleanup(func() {
		session.Execute(context.Background(), protocol.Command{SQL: "DROP DATABASE IF EXISTS " + schema})
	})
	run("CREATE TABLE " + schema + ".`ordinary`(id INT NOT NULL,n DECIMAL(65,38) DEFAULT 0.125,b VARBINARY(8) DEFAULT X'00ff',v VARCHAR(32) DEFAULT '😀' INVISIBLE,PRIMARY KEY(id),KEY ignored_native(v(7) DESC) IGNORED COMMENT 'native retained') ENGINE=InnoDB")
	run("INSERT INTO " + schema + ".`ordinary`(id,n) VALUES(1,123456789012345678901234567.12345678901234567890123456789012345678),(2,NULL)")
	run("CREATE TABLE " + schema + ".`implicit_history`(id INT PRIMARY KEY,v VARCHAR(8) WITHOUT SYSTEM VERSIONING) ENGINE=InnoDB WITH SYSTEM VERSIONING")
	run("INSERT INTO " + schema + ".`implicit_history` VALUES(1,'before')")
	run("UPDATE " + schema + ".`implicit_history` SET v='after'")
	run("CREATE TABLE " + schema + ".`explicit_history`(id INT PRIMARY KEY,v VARCHAR(8) WITHOUT SYSTEM VERSIONING,rs TIMESTAMP(6) GENERATED ALWAYS AS ROW START,re TIMESTAMP(6) GENERATED ALWAYS AS ROW END,PERIOD FOR SYSTEM_TIME(rs,re)) ENGINE=InnoDB WITH SYSTEM VERSIONING")
	run("INSERT INTO " + schema + ".`explicit_history`(id,v) VALUES(1,'before')")
	run("UPDATE " + schema + ".`explicit_history` SET v='after'")
	sink := sc.NewCollector(context.Background(), sc.DefaultLimits())
	reader, ok := session.(interface {
		ReadSchema(context.Context, sc.CaptureSpec, sc.Sink) error
	})
	if !ok {
		t.Fatal("native schema reader interface unavailable")
	}
	if e := reader.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{name}, Limits: sc.DefaultLimits()}, sink); e != nil {
		t.Fatalf("native capture failed: %v", e)
	}
	// Bundle paths are purely offline; no database opener is accepted by Read.
	capture := sink.Capture
	for i := range capture.Inventories {
		capture.Inventories[i].Schema = "native_schema"
		for j := range capture.Inventories[i].Tables.Items {
			capture.Inventories[i].Tables.Items[j].Schema = "native_schema"
		}
	}
	for i := range capture.Tables {
		capture.Tables[i] = mariaDBOfflineMapSchema(t, capture.Tables[i], "native_schema")
	}
	canonical, ce := schemabundle.Canonical(context.Background(), capture)
	if ce != nil {
		t.Fatal("native capture canonical failed")
	}
	if ce = validateOwnership(canonical); ce != nil {
		t.Fatal("native capture ownership failed")
	}
	dir, manifest := mariaDBNativeWriteBundle(t, capture)
	rebuilt, be := schemabundle.Build(context.Background(), t.TempDir(), canonical, []string{"native_schema"}, mariadb.RenderSchemaDefinition)
	if be != nil {
		t.Fatal("native capture rebuild failed")
	}
	defer rebuilt.Close()
	if !reflect.DeepEqual(manifest, rebuilt.Manifest) {
		t.Fatal("native capture manifest rebuild differs")
	}
	imported, e := Read(context.Background(), schemabundle.Source{Path: dir}, t.TempDir(), mariadb.RenderSchemaDefinition)
	if e != nil {
		t.Fatalf("actual native captured bundle failed independent read: %v", e)
	}
	if imported.Summary.ModifiedSQL != 0 || len(imported.Capture.Tables) != 3 || imported.Capture.Context.Engine != "mariadb" {
		t.Fatal("actual native import lost immutable objects/engine identity")
	}
	if imported.Summary.ManualObjects != 0 {
		t.Fatalf("independently represented native facts became manual: count=%d", imported.Summary.ManualObjects)
	}

}

func mariaDBOfflineMapSchema(t *testing.T, table sc.Table, schema string) sc.Table {
	t.Helper()
	raw, e := json.Marshal(table)
	if e != nil {
		t.Fatal("native schema mapping fixture failed")
	}
	var copy sc.Table
	if json.Unmarshal(raw, &copy) != nil {
		t.Fatal("native schema mapping fixture decode failed")
	}
	old := table.Ref.Schema
	refType := reflect.TypeOf(sc.Ref{})
	var visit func(reflect.Value)
	visit = func(v reflect.Value) {
		if !v.IsValid() {
			return
		}
		if v.Type() == refType {
			ref := v.Interface().(sc.Ref)
			if ref.Schema == old {
				ref.Schema = schema
			}
			v.Set(reflect.ValueOf(ref))
			return
		}
		switch v.Kind() {
		case reflect.Pointer:
			if !v.IsNil() {
				visit(v.Elem())
			}
		case reflect.Struct:
			for i := 0; i < v.NumField(); i++ {
				visit(v.Field(i))
			}
		case reflect.Slice:
			for i := 0; i < v.Len(); i++ {
				visit(v.Index(i))
			}
		}
	}
	visit(reflect.ValueOf(&copy).Elem())
	return copy
}
