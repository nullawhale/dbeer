package session

import (
	"context"
	"fmt"
	"os"
	"slices"
	"strconv"
	"testing"
	"time"

	"dbeer/helper/internal/mariadb"
	"dbeer/helper/internal/protocol"
)

func mariaDBManagerSettings(t *testing.T) protocol.Connection {
	t.Helper()
	host := os.Getenv("DBEER_TEST_MARIADB_HOST")
	if host == "" {
		if os.Getenv("DBEER_REQUIRE_MARIADB") == "1" {
			t.Fatal("required native MariaDB endpoint missing")
		}
		t.Skip("native MariaDB endpoint not configured")
	}
	port, err := strconv.Atoi(os.Getenv("DBEER_TEST_MARIADB_PORT"))
	if err != nil {
		t.Fatal("invalid private native port")
	}
	mode := os.Getenv("DBEER_TEST_MARIADB_SSLMODE")
	if mode == "" {
		mode = "disable"
	}
	return protocol.Connection{Engine: "mariadb", Host: host, Port: port, User: os.Getenv("DBEER_TEST_MARIADB_USER"), Password: os.Getenv("DBEER_TEST_MARIADB_PASSWORD"), Database: os.Getenv("DBEER_TEST_MARIADB_DATABASE"), SSLMode: mode, SSLRootCert: os.Getenv("DBEER_TEST_MARIADB_CA_FILE")}
}
func TestMariaDBNormalManagerGridAndImportAuthorityLive(t *testing.T) {
	settings := mariaDBManagerSettings(t)
	setup, err := mariadb.Open(context.Background(), settings)
	if err != nil {
		t.Fatal("cannot open private native setup")
	}
	defer setup.Close()
	name := fmt.Sprintf("g1_manager_rows_%d", time.Now().UnixNano())
	target := mariadb.QuoteIdentifier(settings.Database) + "." + mariadb.QuoteIdentifier(name)
	raw := func(sql string) protocol.Response {
		t.Helper()
		r := setup.Execute(context.Background(), protocol.Command{SQL: sql})
		if r.Type != "query.result" {
			t.Fatalf("native fixture command failed: %s/%s", r.Category, r.SQLState)
		}
		return r
	}
	raw("CREATE TABLE " + target + "(id INT PRIMARY KEY,payload VARCHAR(30),b VARBINARY(30),j JSON,stamp TIMESTAMP(6) NULL) ENGINE=InnoDB")
	defer raw("DROP TABLE IF EXISTS " + target)
	raw("INSERT INTO " + target + " VALUES(1,NULL,X'0080FF','{\"a\":1, \"a\":2}','2024-01-02 03:04:05.123456')")
	manager := New(mariadb.Open)
	defer manager.Close()
	open := func(purpose, id string) protocol.Response {
		t.Helper()
		c := settings
		c.SessionPurpose = purpose
		c.Policy = &protocol.ExecutionPolicy{Environment: "production"}
		submit(t, manager, protocol.Command{Type: "connect", RequestID: id, Connection: &c})
		r := receive(t, manager)
		if r.Type != "connect.result" || r.Engine != "mariadb" {
			t.Fatal("normal native owner failed to open")
		}
		return r
	}
	grid := open("", "grid")
	if !slices.Contains(grid.Capabilities, "gridEditing") || !slices.Contains(grid.Capabilities, protocol.TableImportCapability) {
		t.Fatal("normal native grid/import capabilities were omitted")
	}
	run := func(c protocol.Command) protocol.Response {
		t.Helper()
		submit(t, manager, c)
		return mariaDBManagerTerminal(t, manager)
	}
	columns := run(protocol.Command{Type: "catalog", RequestID: "columns", QueryID: "columns", SessionID: grid.SessionID, Catalog: &protocol.CatalogRequest{Kind: "columns", ObjectKind: "table", Schema: settings.Database, Object: name}})
	browse := run(protocol.Command{Type: "catalog", RequestID: "browse", QueryID: "browse", SessionID: grid.SessionID, Catalog: &protocol.CatalogRequest{Kind: "browse", ObjectKind: "table", Schema: settings.Database, Object: name}})
	if columns.Type != "query.result" || len(columns.Rows) != 5 || columns.Rows[1][6] == nil || *columns.Rows[1][6] != "true" || browse.Type != "query.result" || len(browse.Rows) != 1 || len(browse.StorageTokens) != 1 {
		t.Fatal("normal native metadata/browse did not produce an editable exact row")
	}
	request := protocol.ChangesRequest{Schema: settings.Database, Table: name, Columns: []protocol.SnapshotColumn{}, Changes: []protocol.RowChange{{Kind: "update", StorageToken: browse.StorageTokens[0], Original: []protocol.CellValue{}, Values: []protocol.ColumnAssignment{{Column: "payload", Value: protocol.CellValue{Kind: "text", Value: mariaDBCellText("")}}}}}}
	for i, row := range columns.Rows {
		request.Columns = append(request.Columns, protocol.SnapshotColumn{Name: *row[0], Engine: "mariadb", NativeType: *row[1]})
		cell := protocol.CellValue{Kind: "null"}
		if browse.Rows[0][i] != nil {
			cell.Kind = "text"
			cell.Value = browse.Rows[0][i]
			if browse.Columns[i].Encoding == "base64" {
				cell.Kind = "binary"
			}
		}
		request.Changes[0].Original = append(request.Changes[0].Original, cell)
	}
	preview := run(protocol.Command{Type: "changes.preview", RequestID: "preview", QueryID: "preview", SessionID: grid.SessionID, Changes: &request})
	if preview.Type != "query.result" || len(preview.Rows) != 1 {
		t.Fatal("normal native row preview failed")
	}
	apply := protocol.Command{Type: "changes.apply", RequestID: "apply", QueryID: "apply", SessionID: grid.SessionID, Changes: &request}
	if denied := run(apply); denied.Category != "policy" {
		t.Fatal("normal native production row write bypassed review authority")
	}
	assess := func(op protocol.OperationRequest, owner, id string) string {
		t.Helper()
		r := run(protocol.Command{Type: "operation.assess", RequestID: id, QueryID: id, SessionID: owner, Operations: []protocol.OperationRequest{op}})
		if r.Assessment == nil || r.Assessment.Decision != "confirm" || r.Assessment.Authorization == "" {
			t.Fatal("native write did not require an exact one-use review")
		}
		return r.Assessment.Authorization
	}
	apply.Authorization = assess(protocol.OperationRequest{Type: "changes.apply", Changes: &request}, grid.SessionID, "row-review")
	if r := run(apply); r.Type != "query.result" || r.OutcomeUnknown {
		t.Fatalf("normal native row apply failed: %s/%s", r.Category, r.SQLState)
	}
	if r := run(apply); r.Category != "policy" {
		t.Fatal("normal native row authority was replayable")
	}
	retained := raw("SELECT payload,HEX(b),j FROM " + target + " WHERE id=1")
	if retained.Rows[0][0] == nil || *retained.Rows[0][0] != "" || *retained.Rows[0][1] != "0080FF" || *retained.Rows[0][2] != "{\"a\":1, \"a\":2}" {
		t.Fatal("normal native row changed NULL/empty/binary/JSON semantics")
	}
	importer := open("import", "import")
	importRequest := protocol.TableImportRequest{Schema: settings.Database, Table: name}
	description := run(protocol.Command{Type: "import.describe", RequestID: "describe", QueryID: "describe", SessionID: importer.SessionID, TableImport: &importRequest})
	if description.TableImport == nil {
		t.Fatal("normal native importer description missing")
	}
	importRequest.Fingerprint = description.TableImport.Fingerprint
	importRequest.Columns = []string{"id", "payload", "b", "j"}
	importRequest.Rows = [][]protocol.CellValue{{{Kind: "text", Value: mariaDBCellText("2")}, {Kind: "text", Value: mariaDBCellText("NULL")}, {Kind: "binary", Value: mariaDBCellText("")}, {Kind: "text", Value: mariaDBCellText("{\"a\":1, \"a\":2}")}}}
	if r := run(protocol.Command{Type: "import.preview", RequestID: "import-preview", QueryID: "import-preview", SessionID: importer.SessionID, TableImport: &importRequest}); r.TableImport == nil || r.TableImport.SQL == "" {
		t.Fatal("normal native import preview missing")
	}
	importApply := protocol.Command{Type: "import.apply", RequestID: "import-apply", QueryID: "import-apply", SessionID: importer.SessionID, TableImport: &importRequest}
	importApply.Authorization = assess(protocol.OperationRequest{Type: "import.apply", TableImport: &importRequest}, importer.SessionID, "import-review")
	if r := run(importApply); r.Type != "import.apply.result" || r.OutcomeUnknown {
		t.Fatalf("normal native import failed: %s/%s", r.Category, r.SQLState)
	}
	if r := run(importApply); r.Category != "policy" {
		t.Fatal("normal native import authority was replayable")
	}
	retained = raw("SELECT payload,HEX(b),j FROM " + target + " WHERE id=2")
	if len(retained.Rows) != 1 || *retained.Rows[0][0] != "NULL" || *retained.Rows[0][1] != "" || *retained.Rows[0][2] != "{\"a\":1, \"a\":2}" {
		t.Fatal("normal native imported values changed")
	}
}

func mariaDBCellText(value string) *string { return &value }

func TestMariaDBNormalManagerSystemPeriodBrowseWitnessLive(t *testing.T) {
	settings := mariaDBManagerSettings(t)
	setup, err := mariadb.Open(context.Background(), settings)
	if err != nil {
		t.Fatal("cannot open private native setup")
	}
	defer setup.Close()
	raw := func(sql string) protocol.Response {
		t.Helper()
		r := setup.Execute(context.Background(), protocol.Command{SQL: sql})
		if r.Type != "query.result" {
			t.Fatalf("private period fixture failed: %s/%s", r.Category, r.SQLState)
		}
		return r
	}
	for _, mode := range []string{"implicitTimestamp", "explicitBigint"} {
		t.Run(mode, func(t *testing.T) {
			name := fmt.Sprintf("g1_manager_period_%d", time.Now().UnixNano())
			target := mariadb.QuoteIdentifier(settings.Database) + "." + mariadb.QuoteIdentifier(name)
			ddl := "CREATE TABLE " + target + "(id INT PRIMARY KEY,payload VARCHAR(30)) ENGINE=InnoDB WITH SYSTEM VERSIONING"
			visible := 2
			if mode == "explicitBigint" {
				ddl = "CREATE TABLE " + target + "(id INT PRIMARY KEY,payload VARCHAR(30),started BIGINT UNSIGNED GENERATED ALWAYS AS ROW START,ended BIGINT UNSIGNED GENERATED ALWAYS AS ROW END,PERIOD FOR SYSTEM_TIME(started,ended)) ENGINE=InnoDB WITH SYSTEM VERSIONING"
				visible = 4
			}
			raw(ddl)
			defer raw("DROP TABLE IF EXISTS " + target)
			raw("INSERT INTO " + target + "(id,payload) VALUES(1,'original')")
			manager := New(mariadb.Open)
			defer manager.Close()
			c := settings
			c.Policy = &protocol.ExecutionPolicy{Environment: "development"}
			submit(t, manager, protocol.Command{Type: "connect", RequestID: "period-connect", Connection: &c})
			owner := receive(t, manager)
			if owner.Type != "connect.result" {
				t.Fatal("normal native period owner failed")
			}
			run := func(c protocol.Command) protocol.Response {
				t.Helper()
				c.SessionID = owner.SessionID
				submit(t, manager, c)
				return mariaDBManagerTerminal(t, manager)
			}
			columns := run(protocol.Command{Type: "catalog", RequestID: "period-columns", QueryID: "period-columns", Catalog: &protocol.CatalogRequest{Kind: "columns", ObjectKind: "table", Schema: settings.Database, Object: name}})
			browse := func() protocol.Response {
				return run(protocol.Command{Type: "catalog", RequestID: "period-browse", QueryID: "period-browse", Catalog: &protocol.CatalogRequest{Kind: "browse", ObjectKind: "table", Schema: settings.Database, Object: name}})
			}
			first := browse()
			if columns.Type != "query.result" || len(columns.Rows) != visible || first.Type != "query.result" || len(first.Columns) != visible || len(first.Rows) != 1 || mode == "implicitTimestamp" && len(first.StorageTokens) != 1 {
				t.Log(first.Message)
				t.Fatalf("normal native period contract columns=%s/%d browse=%s/%s/%s visible=%d rows=%d tokens=%d", columns.Type, len(columns.Rows), first.Type, first.Category, first.SQLState, len(first.Columns), len(first.Rows), len(first.StorageTokens))
			}
			token := ""
			if len(first.StorageTokens) > 0 {
				token = first.StorageTokens[0]
			}
			request := protocol.ChangesRequest{Schema: settings.Database, Table: name, Changes: []protocol.RowChange{{Kind: "update", StorageToken: token, Values: []protocol.ColumnAssignment{{Column: "payload", Value: protocol.CellValue{Kind: "text", Value: mariaDBCellText("changed")}}}}}}
			for i, col := range columns.Rows {
				request.Columns = append(request.Columns, protocol.SnapshotColumn{Name: *col[0], Engine: "mariadb", NativeType: *col[1]})
				v := protocol.CellValue{Kind: "null"}
				if first.Rows[0][i] != nil {
					v = protocol.CellValue{Kind: "text", Value: first.Rows[0][i]}
				}
				request.Changes[0].Original = append(request.Changes[0].Original, v)
			}
			apply := func() protocol.Response {
				return run(protocol.Command{Type: "changes.apply", RequestID: "period-apply", QueryID: "period-apply", Changes: &request})
			}
			if r := apply(); r.Type != "query.result" {
				t.Fatalf("normal native period write refused: %s/%s", r.Category, r.SQLState)
			}
			second := browse()
			if second.Type != "query.result" || mode == "implicitTimestamp" && (len(second.StorageTokens) != 1 || second.StorageTokens[0] == token) {
				t.Fatal("native period changes were omitted from the opaque witness")
			}
			raw("UPDATE " + target + " SET payload='original' WHERE id=1")
			if r := apply(); r.Type == "query.result" {
				t.Fatal("same-visible current row accepted a stale native period witness")
			}
			history := raw("SELECT COUNT(*) FROM " + target + " FOR SYSTEM_TIME ALL")
			if len(history.Rows) != 1 || history.Rows[0][0] == nil || *history.Rows[0][0] != "3" {
				t.Fatal("native current/history preservation changed")
			}
			historicalSQL := "SET SESSION system_versioning_asof='2020-01-01 00:00:00'"
			review := run(protocol.Command{Type: "operation.assess", RequestID: "asof-review", QueryID: "asof-review", Operations: []protocol.OperationRequest{{Type: "execute", SQL: historicalSQL}}})
			if review.Assessment == nil || review.Assessment.Decision == "deny" {
				t.Fatal("explicit historical fixture context was denied")
			}
			if r := run(protocol.Command{Type: "execute", RequestID: "asof", QueryID: "asof", SQL: historicalSQL, Authorization: review.Assessment.Authorization}); r.Type != "query.result" {
				t.Fatal("cannot set explicit historical fixture context")
			}
			if r := browse(); r.Type == "query.result" {
				t.Fatal("historical context authorized current native row observations")
			}
		})
	}
}

func mariaDBManagerTerminal(t *testing.T, manager *Manager) protocol.Response {
	t.Helper()
	r := receive(t, manager)
	if r.Type == "query.started" {
		r = receive(t, manager)
	}
	return r
}
