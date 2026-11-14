package dbtools

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/mariadb"
	"dbeer/helper/internal/protocol"
)

func mariaDBToolFixture(t *testing.T) (protocol.Connection, string, *mariadb.Session) {
	t.Helper()
	port, err := strconv.Atoi(os.Getenv("DBEER_TEST_MARIADB_PORT"))
	bin := os.Getenv("DBEER_TEST_MARIADB_TOOLS_DIR")
	if err != nil || port < 1 || bin == "" {
		if os.Getenv("DBEER_REQUIRE_MARIADB") == "1" {
			t.Fatal("required MariaDB native utility fixture unavailable")
		}
		t.Skip("MariaDB native utility fixture is not configured")
	}
	c := protocol.Connection{Engine: "mariadb", Host: os.Getenv("DBEER_TEST_MARIADB_HOST"), Port: port, User: os.Getenv("DBEER_TEST_MARIADB_USER"), Password: os.Getenv("DBEER_TEST_MARIADB_PASSWORD"), Database: os.Getenv("DBEER_TEST_MARIADB_DATABASE"), SSLMode: "verify-full", SSLRootCert: os.Getenv("DBEER_TEST_MARIADB_CA_FILE")}
	opened, err := mariadb.Open(context.Background(), c)
	if err != nil {
		t.Fatal("native utility fixture session unavailable")
	}
	s := opened.(*mariadb.Session)
	t.Cleanup(s.Close)
	return c, bin, s
}
func mariaDBToolRun(t *testing.T, s *mariadb.Session, sql string) protocol.Response {
	t.Helper()
	r := s.Execute(context.Background(), protocol.Command{Type: "execute", SQL: sql})
	if r.Type != "query.result" {
		t.Fatalf("owned native utility fixture SQL failed category=%s SQLSTATE=%s", r.Category, r.SQLState)
	}
	return r
}
func mariaDBToolPreview(t *testing.T, m *Manager, c protocol.Connection, bin, operation, path string) protocol.DatabaseToolsReply {
	t.Helper()
	r := m.Handle(protocol.Command{Type: "dbtools.preview", DatabaseTools: &protocol.DatabaseToolsRequest{Connection: &c, Operation: operation, Format: "sql", Path: path, ToolPath: filepath.Join(bin, expectedTool("mariadb", operation, "sql"))}})
	if r.DatabaseTools == nil {
		t.Fatalf("native utility preview failed category=%s message=%s", r.Category, r.Message)
	}
	return *r.DatabaseTools
}
func mariaDBToolCloseJob(m *Manager, j protocol.DatabaseToolsReply) {
	m.Handle(protocol.Command{Type: "dbtools.close", DatabaseTools: &protocol.DatabaseToolsRequest{JobID: j.JobID}})
}

func TestMariaDBRealToolsManagerDumpAndRestore(t *testing.T) {
	c, bin, s := mariaDBToolFixture(t)
	m, err := New(mariadb.Open, Options{Root: t.TempDir()})
	if err != nil {
		t.Fatal("native utility manager unavailable")
	}
	defer m.Close()
	suffix := strconv.FormatInt(time.Now().UnixNano(), 10)
	rows, audit := "data_tool_rows_"+suffix, "data_tool_audit_"+suffix
	trigger, view, procedure, event := "data_tool_trigger_"+suffix, "data_tool_view_"+suffix, "data_tool_procedure_"+suffix, "data_tool_event_"+suffix
	q := func(name string) string { return "`" + name + "`" }
	mariaDBToolRun(t, s, "CREATE TABLE "+q(rows)+"(id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,n DECIMAL(65,38),j JSON,b BLOB,empty_value VARCHAR(12) DEFAULT '',nullable_value TEXT DEFAULT NULL,g INT AS(CHAR_LENGTH(empty_value)) PERSISTENT) ENGINE=InnoDB AUTO_INCREMENT=9007199254741105")
	mariaDBToolRun(t, s, "CREATE TABLE "+q(audit)+"(id BIGINT UNSIGNED) ENGINE=InnoDB")
	mariaDBToolRun(t, s, "CREATE TRIGGER "+q(trigger)+" AFTER INSERT ON "+q(rows)+" FOR EACH ROW INSERT INTO "+q(audit)+" VALUES(NEW.id)")
	mariaDBToolRun(t, s, "INSERT INTO "+q(rows)+"(n,j,b,empty_value,nullable_value) VALUES(123456789012345678901234567.12345678901234567890123456789012345678,' { \"a\":1, \"a\":2 } ',X'00FF80','',NULL),(NULL,NULL,X'','NULL','NULL'),(NULL,NULL,NULL,'NULL','NULL')")
	mariaDBToolRun(t, s, "CREATE INDEX retained_ignored ON "+q(rows)+"(empty_value)")
	mariaDBToolRun(t, s, "ALTER TABLE "+q(rows)+" ALTER INDEX retained_ignored IGNORED")
	mariaDBToolRun(t, s, "ALTER TABLE "+q(rows)+" COMMENT='retained native utility comment'")
	mariaDBToolRun(t, s, "CREATE VIEW "+q(view)+" AS SELECT id,n,j,b FROM "+q(rows))
	mariaDBToolRun(t, s, "CREATE PROCEDURE "+q(procedure)+"() SELECT COUNT(*) FROM "+q(rows))
	mariaDBToolRun(t, s, "CREATE EVENT "+q(event)+" ON SCHEDULE EVERY 1 DAY STARTS CURRENT_TIMESTAMP + INTERVAL 1 DAY DISABLE DO INSERT INTO "+q(audit)+" VALUES(0)")
	t.Cleanup(func() {
		for _, statement := range []string{"DROP EVENT IF EXISTS " + q(event), "DROP PROCEDURE IF EXISTS " + q(procedure), "DROP VIEW IF EXISTS " + q(view), "DROP TRIGGER IF EXISTS " + q(trigger), "DROP TABLE IF EXISTS " + q(rows), "DROP TABLE IF EXISTS " + q(audit)} {
			mariaDBToolRun(t, s, statement)
		}
	})
	capture := func() map[string][][]*string {
		out := map[string][][]*string{}
		for label, sql := range map[string]string{"rows": "SELECT id,n,j,b,empty_value,nullable_value,g FROM " + q(rows) + " ORDER BY id", "audit": "SELECT id FROM " + q(audit) + " ORDER BY id", "table": "SHOW CREATE TABLE " + q(rows), "view": "SHOW CREATE VIEW " + q(view), "procedure": "SHOW CREATE PROCEDURE " + q(procedure), "trigger": "SHOW CREATE TRIGGER " + q(trigger), "event": "SHOW CREATE EVENT " + q(event), "indexes": "SELECT INDEX_NAME,SEQ_IN_INDEX,COLUMN_NAME,COLLATION,IGNORED FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='" + rows + "' ORDER BY INDEX_NAME,SEQ_IN_INDEX"} {
			r := mariaDBToolRun(t, s, sql)
			if label == "trigger" {
				// Logical native dumps recreate the server's historical Created timestamp.
				// The complete original statement and stored creation context stay exact.
				if len(r.Columns) != 7 || len(r.Rows) != 1 || len(r.Rows[0]) != 7 || r.Columns[6].Name != "Created" {
					t.Fatal("unmodeled native trigger definition metadata")
				}
				out[label] = [][]*string{append([]*string(nil), r.Rows[0][:6]...)}
			} else {
				out[label] = r.Rows
			}
		}
		return out
	}
	beforeMap := capture()
	before, _ := json.Marshal(beforeMap)
	path := filepath.Join(t.TempDir(), "native-backup.sql")
	dump := mariaDBToolPreview(t, m, c, bin, "dump", path)
	done := await(t, m, start(t, m, dump))
	if done.State != "completed" || !done.OutputPublished {
		t.Fatalf("real native dump failed state=%s code=%v", done.State, done.ExitCode)
	}
	mariaDBToolCloseJob(m, done)
	content, err := os.ReadFile(path)
	if err != nil || len(content) == 0 || !strings.HasPrefix(string(content), "/*M!999999\\-") {
		t.Fatal("real native dump or native client sandbox marker absent")
	}
	for _, statement := range []string{"DROP EVENT " + q(event), "DROP PROCEDURE " + q(procedure), "DROP VIEW " + q(view), "DROP TRIGGER " + q(trigger), "DROP TABLE " + q(rows), "DROP TABLE " + q(audit)} {
		mariaDBToolRun(t, s, statement)
	}
	restore := mariaDBToolPreview(t, m, c, bin, "restore", path)
	// Rename/edit of the original path cannot change the reviewed private input.
	if os.WriteFile(path, []byte("invalid replacement after Preview"), 0600) != nil {
		t.Fatal("restore source mutation fixture unavailable")
	}
	done = await(t, m, start(t, m, restore))
	if done.State != "completed" {
		t.Fatalf("real native restore failed state=%s code=%v", done.State, done.ExitCode)
	}
	mariaDBToolCloseJob(m, done)
	afterMap := capture()
	after, _ := json.Marshal(afterMap)
	if string(before) != string(after) {
		for label, oldRows := range beforeMap {
			newRows := afterMap[label]
			if len(oldRows) != len(newRows) {
				t.Log("native restore metadata field path", label+"/rowCount")
				continue
			}
			for i, row := range oldRows {
				if len(row) != len(newRows[i]) {
					t.Log("native restore metadata field path", fmt.Sprintf("%s/%d/columnCount", label, i))
					continue
				}
				for j, value := range row {
					if !reflect.DeepEqual(value, newRows[i][j]) {
						t.Log("native restore metadata field path", fmt.Sprintf("%s/%d/%d", label, i, j))
					}
				}
			}
		}
		t.Fatal("real restore changed exact native rows, counters, definitions, ignored index or dependent objects")
	}
	if s.TransactionStatus() != "idle" {
		t.Fatal("native utility changed the ordinary session transaction")
	}
	mariaDBToolRun(t, s, "INSERT INTO "+q(rows)+"(empty_value) VALUES('next')")
	if *mariaDBToolRun(t, s, "SELECT CAST(MAX(id) AS CHAR) FROM "+q(rows)).Rows[0][0] != "9007199254741108" || *mariaDBToolRun(t, s, "SELECT COUNT(*) FROM "+q(audit)).Rows[0][0] != "4" {
		t.Fatal("restore lost exact auto-increment counter or replayed source triggers")
	}
	retained := capture()["trigger"]
	mariaDBToolRun(t, s, "DROP TRIGGER "+q(trigger))
	mariaDBToolRun(t, s, "CREATE TRIGGER "+q(trigger)+" AFTER INSERT ON "+q(rows)+" FOR EACH ROW INSERT INTO "+q(audit)+" VALUES(0)")
	if reflect.DeepEqual(retained, capture()["trigger"]) {
		t.Fatal("logical trigger proof ignored an actual changed definition while excluding only creation history")
	}

}

func TestMariaDBRealToolsTLSModes(t *testing.T) {
	c, bin, session := mariaDBToolFixture(t)
	name := fmt.Sprintf("data_cli_tls_%d", time.Now().UnixNano())
	quoted := "`" + name + "`"
	mariaDBToolRun(t, session, "CREATE TABLE "+quoted+"(scenario VARCHAR(32), cipher TEXT)")
	defer mariaDBToolRun(t, session, "DROP TABLE IF EXISTS "+quoted)
	for _, scenario := range []struct {
		name, mode, host, ca string
		accepted             bool
	}{
		{"disabled", "disable", "localhost", "", true}, {"encryption", "require", "localhost", "", true}, {"verified", "verify-full", "localhost", c.SSLRootCert, true}, {"chainOnly", "verify-ca", "127.0.0.1", c.SSLRootCert, true}, {"wrongName", "verify-full", "127.0.0.1", c.SSLRootCert, false}, {"wrongCA", "verify-ca", "localhost", os.Getenv("DBEER_TEST_MARIADB_UNTRUSTED_CA_FILE"), false},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			selected := c
			selected.SSLMode, selected.Host, selected.SSLRootCert = scenario.mode, scenario.host, scenario.ca

			if !scenario.accepted {
				m, err := New(mariadb.Open, Options{Root: t.TempDir()})
				if err != nil {
					t.Fatal("native TLS manager unavailable")
				}
				defer m.Close()
				path := filepath.Join(t.TempDir(), "safe.sql")
				if os.WriteFile(path, []byte("SELECT 1;\n"), 0600) != nil {
					t.Fatal("TLS input fixture unavailable")
				}
				response := m.Handle(protocol.Command{Type: "dbtools.preview", DatabaseTools: &protocol.DatabaseToolsRequest{Connection: &selected, Operation: "restore", Format: "sql", Path: path, ToolPath: filepath.Join(bin, "mariadb")}})
				if response.DatabaseTools != nil {
					t.Fatal("native utility preflight accepted wrong CA or hostname")
				}
				return
			}
			dir := t.TempDir()
			args, env, err := utilityArguments(protocol.DatabaseToolsRequest{Operation: "restore", Format: "sql"}, PreparedConnection{Connection: selected, PeerFingerprint: func() string {
				if scenario.accepted && scenario.mode != "disable" {
					return session.DatabaseToolsPeerFingerprint()
				}
				return ""
			}()}, dir)
			if err != nil {
				t.Fatal("native TLS arguments unavailable")
			}
			sql := "INSERT INTO " + quoted + " SELECT '" + scenario.name + "',VARIABLE_VALUE FROM information_schema.SESSION_STATUS WHERE VARIABLE_NAME='SSL_CIPHER';\n"
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			code, runErr := process(ctx, filepath.Join(bin, "mariadb"), args, env, strings.NewReader(sql), io.Discard)
			if scenario.name == "verified" {
				altered := append([]string(nil), args...)
				found := false
				for i, arg := range altered {
					if strings.HasPrefix(arg, "--ssl-fp=") {
						altered[i] = "--ssl-fp=" + strings.Repeat("0", len(strings.TrimPrefix(arg, "--ssl-fp=")))
						found = true
					}
				}
				if !found {
					t.Fatal("verified native utility omitted its reviewed certificate pin")
				}
				badCode, badErr := process(ctx, filepath.Join(bin, "mariadb"), altered, env, strings.NewReader("SELECT 1;\n"), io.Discard)
				if badCode == 0 || badErr == nil {
					t.Fatal("native utility accepted a changed certificate pin")
				}
			}
			rows := mariaDBToolRun(t, session, "SELECT cipher FROM "+quoted+" WHERE scenario='"+scenario.name+"'").Rows
			if !scenario.accepted {
				if code == 0 || runErr == nil || len(rows) != 0 {
					t.Fatal("native client accepted wrong CA or hostname")
				}
				return
			}
			if code != 0 || runErr != nil || len(rows) != 1 || len(rows[0]) != 1 || rows[0][0] == nil {
				t.Fatal("native TLS client did not acknowledge its exact statement")
			}
			if (*rows[0][0] == "") != (scenario.mode == "disable") {
				t.Fatal("native utility cipher disagrees with requested encryption mode")
			}
		})
	}
}

func TestMariaDBRealToolsRestorePartialFailureAndLocalCommands(t *testing.T) {
	c, bin, s := mariaDBToolFixture(t)
	m, err := New(mariadb.Open, Options{Root: t.TempDir()})
	if err != nil {
		t.Fatal("native failure manager unavailable")
	}
	defer m.Close()
	name := fmt.Sprintf("data_tool_partial_%d", time.Now().UnixNano())
	defer mariaDBToolRun(t, s, "DROP TABLE IF EXISTS `"+name+"`")
	path := filepath.Join(t.TempDir(), "partial.sql")
	if os.WriteFile(path, []byte("CREATE TABLE `"+name+"`(id INT);\nINSERT INTO `"+name+"` VALUES(7);\nTHIS IS NOT VALID SQL;\n"), 0600) != nil {
		t.Fatal("partial restore fixture unavailable")
	}
	done := await(t, m, start(t, m, mariaDBToolPreview(t, m, c, bin, "restore", path)))
	if done.State != "outcomeUnknown" || done.OutputPublished || *mariaDBToolRun(t, s, "SELECT COUNT(*) FROM `"+name+"`").Rows[0][0] != "1" {
		t.Fatal("partial failed native restore lost explicit effects/unknown outcome")
	}
	mariaDBToolCloseJob(m, done)
	marker := filepath.Join(t.TempDir(), "must-not-exist")
	path = filepath.Join(t.TempDir(), "local.sql")
	if os.WriteFile(path, []byte("\\! touch "+marker+"\n"), 0600) != nil {
		t.Fatal("local command fixture unavailable")
	}
	done = await(t, m, start(t, m, mariaDBToolPreview(t, m, c, bin, "restore", path)))
	if _, err = os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("native restore executed a local client shell command")
	}
	if done.State == "completed" {
		t.Fatal("a forbidden client shell command was silently accepted")
	}
}

func TestMariaDBRealToolsTimestampHistoryAndSequenceState(t *testing.T) {
	c, bin, s := mariaDBToolFixture(t)
	m, err := New(mariadb.Open, Options{Root: t.TempDir()})
	if err != nil {
		t.Fatal("history utility manager unavailable")
	}
	defer m.Close()
	suffix := strconv.FormatInt(time.Now().UnixNano(), 10)
	hist, plainSeq, cachedSeq := "data_history_"+suffix, "data_seq_plain_"+suffix, "data_seq_cached_"+suffix
	q := func(name string) string { return "`" + name + "`" }
	mariaDBToolRun(t, s, "SET SESSION time_zone='+00:00'")
	mariaDBToolRun(t, s, "CREATE TABLE "+q(hist)+"(id INT PRIMARY KEY,v TEXT,rs TIMESTAMP(6) GENERATED ALWAYS AS ROW START,re TIMESTAMP(6) GENERATED ALWAYS AS ROW END,PERIOD FOR SYSTEM_TIME(rs,re)) ENGINE=InnoDB WITH SYSTEM VERSIONING")
	mariaDBToolRun(t, s, "SET timestamp=1700000000")
	mariaDBToolRun(t, s, "INSERT INTO "+q(hist)+"(id,v) VALUES(1,'old'),(2,'deleted')")
	mariaDBToolRun(t, s, "SET timestamp=1700000010")
	mariaDBToolRun(t, s, "UPDATE "+q(hist)+" SET v='new' WHERE id=1")
	mariaDBToolRun(t, s, "SET timestamp=1700000020")
	mariaDBToolRun(t, s, "DELETE FROM "+q(hist)+" WHERE id=2")
	mariaDBToolRun(t, s, "SET timestamp=DEFAULT")
	mariaDBToolRun(t, s, "CREATE SEQUENCE "+q(plainSeq)+" START WITH 9007199254741105 INCREMENT BY 7 NOCACHE ENGINE=InnoDB")
	mariaDBToolRun(t, s, "CREATE SEQUENCE "+q(cachedSeq)+" START WITH 9007199254741105 INCREMENT BY 7 CACHE 17 ENGINE=InnoDB")
	for _, seq := range []string{plainSeq, cachedSeq} {
		mariaDBToolRun(t, s, "SELECT NEXT VALUE FOR "+q(seq))
	}
	mariaDBToolRun(t, s, "SELECT NEXT VALUE FOR "+q(plainSeq))
	defer func() {
		for _, statement := range []string{"DROP TABLE IF EXISTS " + q(hist), "DROP SEQUENCE IF EXISTS " + q(plainSeq), "DROP SEQUENCE IF EXISTS " + q(cachedSeq)} {
			mariaDBToolRun(t, s, statement)
		}
	}()
	capture := func() map[string][][]*string {
		out := map[string][][]*string{}
		for label, sql := range map[string]string{"history": "SELECT id,v,CAST(rs AS CHAR),CAST(re AS CHAR) FROM " + q(hist) + " FOR SYSTEM_TIME ALL ORDER BY id,rs,re", "current": "SELECT id,v FROM " + q(hist) + " ORDER BY id", "historyDefinition": "SHOW CREATE TABLE " + q(hist), "plainState": "SELECT * FROM " + q(plainSeq), "cachedState": "SELECT * FROM " + q(cachedSeq), "plainDefinition": "SHOW CREATE SEQUENCE " + q(plainSeq), "cachedDefinition": "SHOW CREATE SEQUENCE " + q(cachedSeq)} {
			out[label] = mariaDBToolRun(t, s, sql).Rows
		}
		return out
	}
	observed := capture()
	if len(observed["history"]) != 3 || len(observed["current"]) != 1 {
		t.Fatal("history fixture has no real nonempty previous/deleted versions")
	}
	plainNext := *mariaDBToolRun(t, s, "SELECT CAST(next_not_cached_value AS CHAR) FROM "+q(plainSeq)).Rows[0][0]
	cachedNext := *mariaDBToolRun(t, s, "SELECT CAST(next_not_cached_value AS CHAR) FROM "+q(cachedSeq)).Rows[0][0]
	before, _ := json.Marshal(observed)
	path := filepath.Join(t.TempDir(), "history.sql")
	done := await(t, m, start(t, m, mariaDBToolPreview(t, m, c, bin, "dump", path)))
	if done.State != "completed" || !done.OutputPublished {
		t.Fatal("native historical/sequence dump failed")
	}
	mariaDBToolCloseJob(m, done)
	mariaDBToolRun(t, s, "DROP TABLE "+q(hist))
	mariaDBToolRun(t, s, "DROP SEQUENCE "+q(plainSeq))
	mariaDBToolRun(t, s, "DROP SEQUENCE "+q(cachedSeq))
	done = await(t, m, start(t, m, mariaDBToolPreview(t, m, c, bin, "restore", path)))
	if done.State != "completed" {
		t.Fatalf("native historical/sequence restore failed state=%s code=%v", done.State, done.ExitCode)
	}
	mariaDBToolCloseJob(m, done)
	restored := capture()
	after, _ := json.Marshal(restored)
	if string(before) != string(after) {
		for label, old := range observed {
			if !reflect.DeepEqual(old, restored[label]) {
				t.Log("native historical restore mismatch category", label)
			}
		}
		t.Fatal("native history timestamps/rows, sequence definitions or durable state changed")
	}
	if *mariaDBToolRun(t, s, "SELECT NEXT VALUE FOR "+q(plainSeq)).Rows[0][0] != plainNext || *mariaDBToolRun(t, s, "SELECT NEXT VALUE FOR "+q(cachedSeq)).Rows[0][0] != cachedNext {
		t.Fatal("restored sequences rewound or lost exact durable next state")
	}
}

func TestMariaDBRealToolsTransactionPreciseHistoryRefused(t *testing.T) {
	c, bin, s := mariaDBToolFixture(t)
	m, err := New(mariadb.Open, Options{Root: t.TempDir()})
	if err != nil {
		t.Fatal("native scope manager unavailable")
	}
	defer m.Close()
	name := fmt.Sprintf("data_trx_history_%d", time.Now().UnixNano())
	q := "`" + name + "`"
	mariaDBToolRun(t, s, "CREATE TABLE "+q+"(v INT,rs BIGINT UNSIGNED GENERATED ALWAYS AS ROW START,re BIGINT UNSIGNED GENERATED ALWAYS AS ROW END,PERIOD FOR SYSTEM_TIME(rs,re)) ENGINE=InnoDB WITH SYSTEM VERSIONING")
	defer mariaDBToolRun(t, s, "DROP TABLE IF EXISTS "+q)
	mariaDBToolRun(t, s, "INSERT INTO "+q+"(v) VALUES(1)")
	mariaDBToolRun(t, s, "UPDATE "+q+" SET v=2")
	if *mariaDBToolRun(t, s, "SELECT COUNT(*) FROM "+q+" FOR SYSTEM_TIME ALL").Rows[0][0] != "2" {
		t.Fatal("transaction-precise historical fixture is empty")
	}
	path := filepath.Join(t.TempDir(), "must-not-publish.sql")
	result := m.Handle(protocol.Command{Type: "dbtools.preview", DatabaseTools: &protocol.DatabaseToolsRequest{Connection: &c, Operation: "dump", Format: "sql", Path: path, ToolPath: filepath.Join(bin, "mariadb-dump")}})
	if result.DatabaseTools != nil || !strings.Contains(result.Message, "transaction-precise") {
		t.Fatal("unsupported native dump history was silently advertised as a full backup")
	}
	if _, err = os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("history scope refusal published a partial backup")
	}
}

func TestMariaDBRealToolsVerifiedCertificateRotation(t *testing.T) {
	c, bin, session := mariaDBToolFixture(t)
	control := os.Getenv("DBEER_TEST_MARIADB_TLS_CONTROL")
	if control == "" {
		t.Fatal("owned TLS rotation fixture unavailable")
	}
	m, err := New(mariadb.Open, Options{Root: t.TempDir()})
	if err != nil {
		t.Fatal("rotation manager unavailable")
	}
	defer m.Close()
	input := filepath.Join(t.TempDir(), "rotated.sql")
	if os.WriteFile(input, []byte("SELECT 1;\n"), 0600) != nil {
		t.Fatal("rotation input unavailable")
	}
	reviewed := mariaDBToolPreview(t, m, c, bin, "restore", input)
	rotate := func(mode string) {
		t.Helper()
		command := exec.Command(control, mode)
		command.Stdout, command.Stderr = io.Discard, io.Discard
		if command.Run() != nil {
			t.Fatal("owned TLS rotation failed")
		}
	}
	rotate("rotated")
	defer rotate("original")
	replacement, err := mariadb.Open(context.Background(), c)
	if err != nil {
		t.Fatal("rotated certificate was not independently trusted")
	}
	next := replacement.(*mariadb.Session)
	if next.DatabaseToolsPeerFingerprint() == "" || next.DatabaseToolsPeerFingerprint() == session.DatabaseToolsPeerFingerprint() {
		replacement.Close()
		t.Fatal("rotation did not change the trusted certificate")
	}
	replacement.Close()
	done := await(t, m, start(t, m, reviewed))
	if done.State == "completed" || done.OutputPublished {
		t.Fatal("utility ignored the certificate verified at Preview")
	}
	mariaDBToolCloseJob(m, done)
	// A new review can bind the trusted replacement; the rejected plan cannot retry itself.
	done = await(t, m, start(t, m, mariaDBToolPreview(t, m, c, bin, "restore", input)))
	if done.State != "completed" {
		t.Fatal("fresh review could not bind the trusted rotated certificate")
	}
}

func TestMariaDBRealToolsRequireRefusesTLSDisabledServer(t *testing.T) {
	if os.Getenv("DBEER_TEST_MARIADB_TLS") != "0" {
		t.Skip("TLS-disabled owned server is not selected")
	}
	port, err := strconv.Atoi(os.Getenv("DBEER_TEST_MARIADB_PORT"))
	if err != nil {
		t.Fatal("TLS-disabled native endpoint unavailable")
	}
	c := protocol.Connection{Engine: "mariadb", Host: os.Getenv("DBEER_TEST_MARIADB_HOST"), Port: port, User: os.Getenv("DBEER_TEST_MARIADB_USER"), Password: os.Getenv("DBEER_TEST_MARIADB_PASSWORD"), Database: os.Getenv("DBEER_TEST_MARIADB_DATABASE"), SSLMode: "disable"}
	opened, err := mariadb.Open(context.Background(), c)
	if err != nil {
		t.Fatal("native TLS-disabled observer unavailable")
	}
	defer opened.Close()
	s := opened.(*mariadb.Session)
	if *mariaDBToolRun(t, s, "SELECT VARIABLE_VALUE FROM information_schema.SESSION_STATUS WHERE VARIABLE_NAME='SSL_CIPHER'").Rows[0][0] != "" {
		t.Fatal("TLS-disabled server control unexpectedly encrypted")
	}
	name := fmt.Sprintf("data_no_tls_%d", time.Now().UnixNano())
	quoted := "`" + name + "`"
	mariaDBToolRun(t, s, "CREATE TABLE "+quoted+"(id INT)")
	defer mariaDBToolRun(t, s, "DROP TABLE IF EXISTS "+quoted)
	c.SSLMode = "require"
	bin := os.Getenv("DBEER_TEST_MARIADB_TOOLS_DIR")
	m, err := New(mariadb.Open, Options{Root: t.TempDir()})
	if err != nil {
		t.Fatal("native required-TLS manager unavailable")
	}
	defer m.Close()
	for _, op := range []string{"dump", "restore"} {
		t.Run(op, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "native.sql")
			if op == "restore" {
				if os.WriteFile(path, []byte("INSERT INTO "+quoted+" VALUES(1);\n"), 0600) != nil {
					t.Fatal("native TLS failure input unavailable")
				}
			}
			tool := "mariadb"
			if op == "dump" {
				tool = "mariadb-dump"
			}
			reviewed := m.Handle(protocol.Command{Type: "dbtools.preview", DatabaseTools: &protocol.DatabaseToolsRequest{Connection: &c, Operation: op, Format: "sql", Path: path, ToolPath: filepath.Join(bin, tool)}})
			if reviewed.DatabaseTools != nil {
				t.Fatal("required-TLS Preview authorized a plaintext server")
			}
			// Exercise the later native utility independently: a nonempty observed pin
			// requires native TLS even after the preflight endpoint changes.
			prepared := PreparedConnection{Connection: c, PeerFingerprint: strings.Repeat("a", 64)}
			args, env, err := utilityArguments(protocol.DatabaseToolsRequest{Operation: op, Format: "sql"}, prepared, dir)
			if err != nil {
				t.Fatal("native required TLS arguments unavailable")
			}
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			code, runErr := process(ctx, filepath.Join(bin, tool), args, env, strings.NewReader("INSERT INTO "+quoted+" VALUES(1);\n"), io.Discard)
			if code == 0 || runErr == nil || *mariaDBToolRun(t, s, "SELECT COUNT(*) FROM "+quoted).Rows[0][0] != "0" {
				t.Fatal("native utility downgraded required TLS or executed its write")
			}
			if op == "dump" {
				if _, err = os.Stat(path); !os.IsNotExist(err) {
					t.Fatal("TLS refusal published a dump")
				}
			}
		})
	}
}
