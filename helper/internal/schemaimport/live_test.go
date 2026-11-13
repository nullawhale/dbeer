package schemaimport

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/mysql"
	"dbeer/helper/internal/postgres"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/schemabundle"
	sc "dbeer/helper/internal/schemacompare"
	"github.com/jackc/pgx/v5"
)

// These tests capture only owned disposable fixtures using the supported
// PostgreSQL/MySQL runners. Imported SQL is never sent to either server.
func TestRealPostgresSchemaBundleRoundTripAndGitEdits(t *testing.T) {
	dsn := os.Getenv("DBEER_TEST_DSN")
	if dsn == "" {
		t.Skip("disposable PostgreSQL fixture required")
	}
	ctx := context.Background()
	owner, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal("fixture connection failed")
	}
	defer owner.Close(ctx)
	name := "bundle_" + time.Now().Format("150405000000")
	schema := pgx.Identifier{name}.Sanitize()
	if _, err = owner.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal("fixture schema creation failed")
	}
	defer owner.Exec(ctx, "DROP SCHEMA IF EXISTS "+schema+" CASCADE")
	if _, err = owner.Exec(ctx, "CREATE TYPE "+schema+`.mood AS ENUM ('é','é',''); CREATE SEQUENCE `+schema+`.counter AS bigint START WITH 9007199254740993; CREATE TABLE `+schema+`.items(id bigint PRIMARY KEY, amount numeric(30,9) DEFAULT 9007199254740993.123456789, label text DEFAULT 'NULL', mood `+schema+`.mood); CREATE INDEX amount_idx ON `+schema+`.items(amount DESC NULLS FIRST); ALTER SEQUENCE `+schema+`.counter OWNED BY `+schema+`.items.id;`); err != nil {
		t.Fatal("fixture DDL failed")
	}
	cfg := owner.Config()
	settings := protocol.Connection{Engine: "postgresql", Host: cfg.Host, Port: int(cfg.Port), User: cfg.User, Password: cfg.Password, Database: cfg.Database, SSLMode: "disable"}
	opened, err := postgres.Open(ctx, settings)
	if err != nil {
		t.Fatal("capture open failed")
	}
	reader := opened.(adapter.SchemaReader)
	collector := sc.NewCollector(ctx, sc.DefaultLimits())
	if err = reader.ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{name}, Limits: sc.DefaultLimits()}, collector); err != nil {
		opened.Close()
		t.Fatal("fixture capture failed")
	}
	opened.Close()
	dir, m := writeBundle(t, collector.Capture, []string{name})
	// The source can disappear before inspection: no source or validation server
	// is necessary for the exported SQL/capture consistency checks.
	if _, err = owner.Exec(ctx, "DROP SCHEMA "+schema+" CASCADE"); err != nil {
		t.Fatal("fixture removal failed")
	}
	got, err := Read(ctx, schemabundle.Source{Path: dir}, t.TempDir(), render)
	if err != nil {
		t.Fatalf("real PostgreSQL bundle rejected (%T)", err)
	}
	if len(got.Capture.Tables) != 1 || len(got.Capture.Types) < 1 || len(got.Capture.Sequences) != 1 || got.Capture.Context.Version != "" || got.Capture.Tables[0].Ref.Schema != name {
		t.Fatal("historical PostgreSQL facts lost")
	}
	path := filepath.Join(dir, tableFile(t, m, "items"))
	data, _ := os.ReadFile(path)
	if strings.Count(string(data), `"amount" numeric(30, 9)`) != 1 {
		t.Fatal("fixture numeric type missing")
	}
	data = []byte(strings.Replace(string(data), `"amount" numeric(30, 9)`, `"amount" numeric(31, 9)`, 1))
	if err = os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = Read(ctx, schemabundle.Source{Path: dir, AllowSQLChanges: true}, t.TempDir(), render); err != nil {
		t.Fatalf("supported PostgreSQL Git edit rejected (%T)", err)
	}
}
func TestRealMySQLSchemaBundleRoundTripAndGitEdits(t *testing.T) {
	port, err := strconv.Atoi(os.Getenv("DBEER_TEST_MYSQL_PORT"))
	if err != nil || port < 1 {
		t.Skip("disposable MySQL fixture required")
	}
	host := os.Getenv("DBEER_TEST_MYSQL_HOST")
	if host == "" {
		host = "localhost"
	}
	mode := os.Getenv("DBEER_TEST_MYSQL_SSLMODE")
	if mode == "" {
		mode = "disable"
	}
	settings := protocol.Connection{Engine: "mysql", Host: host, Port: port, User: os.Getenv("DBEER_TEST_MYSQL_USER"), Password: os.Getenv("DBEER_TEST_MYSQL_PASSWORD"), Database: os.Getenv("DBEER_TEST_MYSQL_DATABASE"), SSLMode: mode, SSLRootCert: os.Getenv("DBEER_TEST_MYSQL_CA_FILE")}
	ctx := context.Background()
	owner, err := mysql.Open(ctx, settings)
	if err != nil {
		t.Fatal("fixture connection failed")
	}
	defer owner.Close()
	name := "bundle_" + time.Now().Format("150405000000")
	quoted := "`" + name + "`"
	run := func(sql string) {
		r := owner.Execute(ctx, protocol.Command{Type: "execute", RequestID: "fixture", SessionID: "fixture", QueryID: "fixture", SQL: sql})
		if r.Type != "query.result" {
			t.Fatal("fixture DDL failed")
		}
	}
	run("CREATE TABLE " + quoted + " (id BIGINT PRIMARY KEY, amount DECIMAL(30,9) DEFAULT 9007199254740993.123456789, label VARCHAR(40) DEFAULT 'NULL', `literal\\n` INT, `tick``column` INT, KEY label_idx(label)) ENGINE=InnoDB DEFAULT CHARACTER SET=utf8mb4 COLLATE=utf8mb4_bin")
	defer run("DROP TABLE IF EXISTS " + quoted)
	opened, err := mysql.Open(ctx, settings)
	if err != nil {
		t.Fatal("capture open failed")
	}
	collector := sc.NewCollector(ctx, sc.DefaultLimits())
	if err = opened.(adapter.SchemaReader).ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{settings.Database}, Limits: sc.DefaultLimits()}, collector); err != nil {
		opened.Close()
		t.Fatal("fixture capture failed")
	}
	opened.Close()
	dir, m := writeBundle(t, collector.Capture, []string{settings.Database})
	run("DROP TABLE " + quoted)
	got, err := Read(ctx, schemabundle.Source{Path: dir}, t.TempDir(), render)
	if err != nil {
		t.Fatalf("real MySQL bundle rejected (%T)", err)
	}
	found := false
	for _, table := range got.Capture.Tables {
		if table.Ref.Name == name {
			found = true
			names := map[string]bool{}
			for _, column := range table.Columns.Items {
				names[column.Ref.Name] = true
			}
			if !names[`literal\n`] || !names["tick`column"] {
				t.Fatal("quoted identifier bytes changed during import")
			}
		}
	}
	if !found || got.Capture.Context.Version != "" {
		t.Fatal("historical MySQL facts lost")
	}
	path := filepath.Join(dir, tableFile(t, m, name))
	data, _ := os.ReadFile(path)
	if strings.Count(string(data), "`amount` DECIMAL(30, 9)") != 1 {
		t.Fatal("fixture numeric type missing")
	}
	data = []byte(strings.Replace(string(data), "`amount` DECIMAL(30, 9)", "`amount` DECIMAL(31, 9)", 1))
	if err = os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = Read(ctx, schemabundle.Source{Path: dir, AllowSQLChanges: true}, t.TempDir(), render); err != nil {
		t.Fatalf("supported MySQL Git edit rejected (%T)", err)
	}
	bad := strings.Replace(string(data), "\n)", ",\n)", 1)
	if bad == string(data) {
		t.Fatal("fixture table body terminator missing")
	}
	if err = os.WriteFile(path, []byte(bad), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = Read(ctx, schemabundle.Source{Path: dir, AllowSQLChanges: true}, t.TempDir(), render); err == nil {
		t.Fatal("invalid MySQL trailing comma accepted by import")
	}
}
