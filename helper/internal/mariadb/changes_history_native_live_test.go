package mariadb

import (
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestMariaDBRowsNativeLiveSystemVersionedPeriodsAndHistory(t *testing.T) {
	for _, precise := range []bool{false, true} {
		t.Run(map[bool]string{false: "timestamp", true: "transaction"}[precise], func(t *testing.T) {
			s, other := dataIntegrationSession(t), dataIntegrationSession(t)
			definition := "(id INT PRIMARY KEY,n TINYINT NOT NULL) ENGINE=InnoDB WITH SYSTEM VERSIONING"
			if precise {
				definition = "(id INT PRIMARY KEY,n TINYINT NOT NULL,period_start BIGINT UNSIGNED GENERATED ALWAYS AS ROW START,period_end BIGINT UNSIGNED GENERATED ALWAYS AS ROW END,PERIOD FOR SYSTEM_TIME(period_start,period_end)) ENGINE=InnoDB WITH SYSTEM VERSIONING"
			}
			name, qualified := rowFixture(t, s, definition)
			dataRun(t, s, "INSERT INTO "+qualified+"(id,n) VALUES(1,0),(2,0)")
			request := rowRequest(t, s, name, 1)
			columnCount := 2
			if precise {
				columnCount = 4
			}
			if len(request.Columns) != columnCount || len(request.Changes[0].Original) != columnCount {
				t.Fatal("native versioned snapshot omitted server-maintained periods")
			}
			if !precise && !validMariaDBStorageToken(request.Changes[0].StorageToken) {
				t.Fatal("native timestamp periods lacked storage evidence")
			}
			request.Changes[0].Values = []protocol.ColumnAssignment{{Column: "n", Value: rowCell("1")}}
			if out := rowApply(t, s, request); out.Type != "query.result" {
				t.Fatalf("native versioned row Apply failed: %s/%s", out.Category, out.SQLState)
			}
			history := dataRun(t, s, "SELECT n FROM "+qualified+" FOR SYSTEM_TIME ALL WHERE id=1 ORDER BY n")
			if len(history.Rows) != 2 || *history.Rows[0][0] != "0" || *history.Rows[1][0] != "1" {
				t.Fatal("native versioned write lost its retained historical row")
			}
			stale := rowRequest(t, s, name, 1)
			stale.Changes[0].Values = []protocol.ColumnAssignment{{Column: "n", Value: rowCell("3")}}
			dataRun(t, other, "UPDATE "+qualified+" SET n=2 WHERE id=1")
			dataRun(t, other, "UPDATE "+qualified+" SET n=1 WHERE id=1")
			count := *dataRun(t, s, "SELECT COUNT(*) FROM "+qualified+" FOR SYSTEM_TIME ALL").Rows[0][0]
			if out := rowApply(t, s, stale); out.Category != "conflict" {
				t.Fatal("a changed native period with identical current visible values did not invalidate the row")
			}
			batch := rowRequest(t, s, name, 1, 2)
			batch.Changes[0].Values = []protocol.ColumnAssignment{{Column: "n", Value: rowCell("5")}}
			batch.Changes[1].Values = []protocol.ColumnAssignment{{Column: "n", Value: rowCell("999")}}
			if out := rowApply(t, s, batch); out.Type != "error" || out.OutcomeUnknown || *dataRun(t, s, "SELECT COUNT(*) FROM "+qualified+" FOR SYSTEM_TIME ALL").Rows[0][0] != count || *dataRun(t, s, "SELECT n FROM "+qualified+" WHERE id=1").Rows[0][0] != "1" {
				t.Fatal("native versioned late-row failure retained current or historical changes")
			}
			period := "ROW_START"
			if precise {
				period = request.Columns[2].Name
			}
			request = rowRequest(t, s, name, 1)
			request.Changes[0].Values = []protocol.ColumnAssignment{{Column: period, Value: rowCell("1")}}
			if out := rowApply(t, s, request); out.Category != "validation" {
				t.Fatal("server-maintained native period became editable")
			}
			importRequest := protocol.TableImportRequest{Schema: request.Schema, Table: name}
			description := importCommand(s, "import.describe", &importRequest)
			if description.TableImport == nil || len(description.TableImport.Columns) != columnCount || precise && (!description.TableImport.Columns[2].Generated || !description.TableImport.Columns[3].Generated) {
				t.Fatal("native versioned import exposed writable or omitted period metadata")
			}
			importRequest.Fingerprint = description.TableImport.Fingerprint
			importRequest.Columns = []string{"id", "n"}
			importRequest.Rows = [][]protocol.CellValue{{rowCell("3"), rowCell("7")}}
			if out := importCommand(s, "import.apply", &importRequest); out.Type != "import.apply.result" || *dataRun(t, s, "SELECT n FROM "+qualified+" WHERE id=3").Rows[0][0] != "7" {
				t.Fatal("native versioned import failed to retain automatically maintained periods")
			}
			request = rowRequest(t, s, name, 1)
			request.Changes[0].Values = []protocol.ColumnAssignment{{Column: "n", Value: rowCell("4")}}
			defaultContext := *dataRun(t, s, "SELECT @@SESSION.system_versioning_asof").Rows[0][0]
			dataRun(t, s, "SET SESSION system_versioning_asof='2020-01-01 00:00:00'")
			observedContext := *dataRun(t, s, "SELECT @@SESSION.system_versioning_asof").Rows[0][0]
			if out := rowApply(t, s, request); out.Category != "validation" || out.OutcomeUnknown {
				t.Fatal("historical observation context authorized a current native row write")
			}
			if out := importCommand(s, "import.apply", &importRequest); out.Category != "validation" || out.OutcomeUnknown {
				t.Fatal("historical observation context authorized a native import")
			}
			if *dataRun(t, s, "SELECT @@SESSION.system_versioning_asof").Rows[0][0] != observedContext {
				t.Fatal("native history admission silently changed the user's observation context")
			}
			dataRun(t, s, "SET SESSION system_versioning_asof=DEFAULT")
			if *dataRun(t, s, "SELECT @@SESSION.system_versioning_asof").Rows[0][0] != defaultContext {
				t.Fatal("native history fixture failed to restore its original observation context")
			}
		})
	}
}
