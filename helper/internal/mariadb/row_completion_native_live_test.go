package mariadb

import (
	"fmt"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestMariaDBRowImportCompletionPreservesOwnerAndSettingsLive(t *testing.T) {
	for _, mode := range []int{1, 2} {
		t.Run(fmt.Sprint(mode), func(t *testing.T) {
			s, observer := dataIntegrationSession(t), dataIntegrationSession(t)
			name, qualified := rowFixture(t, observer, "(id INT PRIMARY KEY,n TINYINT NOT NULL) ENGINE=InnoDB")
			dataRun(t, observer, "INSERT INTO "+qualified+" VALUES(1,0)")
			dataRun(t, s, fmt.Sprintf("SET SESSION completion_type=%d", mode))
			before := rowState(t, s)
			initial := dataRun(t, s, "SELECT @@SESSION.completion_type")
			if len(initial.Rows) != 1 || initial.Rows[0][0] == nil || *initial.Rows[0][0] == "" {
				t.Fatal("native completion_type observation unavailable")
			}
			completionType := *initial.Rows[0][0]
			assertOwner := func() {
				t.Helper()
				if s.closed.Load() || s.TransactionStatus() != "idle" || rowState(t, s) != before {
					t.Fatal("row/import completion chained a transaction, released its owner or changed settings")
				}
				state := dataRun(t, s, "SELECT @@SESSION.completion_type")
				if len(state.Rows) != 1 || state.Rows[0][0] == nil || *state.Rows[0][0] != completionType {
					t.Fatal("row/import completion changed native completion_type")
				}
			}
			request := rowRequest(t, s, name, 1)
			request.Changes[0].Values = []protocol.ColumnAssignment{{Column: "n", Value: rowCell("1")}}
			if r := rowApply(t, s, request); r.Type != "query.result" || r.OutcomeUnknown || !r.Connected || r.TransactionStatus != "idle" {
				t.Fatal("acknowledged row commit lost its usable idle owner")
			}
			assertOwner()
			request = rowRequest(t, s, name, 1)
			request.Changes[0].Values = []protocol.ColumnAssignment{{Column: "n", Value: rowCell("2")}}
			request.Changes = append(request.Changes, protocol.RowChange{Kind: "insert", Values: []protocol.ColumnAssignment{{Column: "id", Value: rowCell("2")}, {Column: "n", Value: rowCell("999")}}})
			if r := rowApply(t, s, request); r.Type != "error" || r.OutcomeUnknown || !r.Connected || r.TransactionStatus != "idle" {
				t.Fatal("late invalid row did not acknowledge rollback on its owner")
			}
			assertOwner()
			if *dataRun(t, observer, "SELECT n FROM "+qualified+" WHERE id=1").Rows[0][0] != "1" {
				t.Fatal("row rollback retained an earlier write")
			}
			input := protocol.TableImportRequest{Schema: dataIntegrationSettings(t).Database, Table: name}
			description := importCommand(s, "import.describe", &input)
			if description.TableImport == nil || description.TransactionStatus != "idle" {
				t.Fatal("import describe lost its idle owner")
			}
			assertOwner()
			input.Fingerprint = description.TableImport.Fingerprint
			input.Columns = []string{"id", "n"}
			input.Rows = [][]protocol.CellValue{{rowCell("2"), rowCell("2")}}
			if r := importCommand(s, "import.preview", &input); r.Type != "import.preview.result" || r.TransactionStatus != "idle" {
				t.Fatal("import preview lost its idle owner")
			}
			assertOwner()
			if *dataRun(t, observer, "SELECT COUNT(*) FROM "+qualified).Rows[0][0] != "1" {
				t.Fatal("import preview wrote a row")
			}
			if r := importCommand(s, "import.apply", &input); r.Type != "import.apply.result" || r.OutcomeUnknown || !r.Connected || r.TransactionStatus != "idle" {
				t.Fatal("acknowledged import commit lost its usable idle owner")
			}
			assertOwner()
			input.Rows = [][]protocol.CellValue{{rowCell("3"), rowCell("3")}, {rowCell("1"), rowCell("4")}}
			if r := importCommand(s, "import.apply", &input); r.Type != "error" || r.OutcomeUnknown || !r.Connected || r.TransactionStatus != "idle" {
				t.Fatal("late duplicate import did not acknowledge rollback on its owner")
			}
			assertOwner()
			if *dataRun(t, observer, "SELECT COUNT(*) FROM "+qualified).Rows[0][0] != "2" {
				t.Fatal("import rollback retained an earlier row or lost its committed rows")
			}
			dataRun(t, s, "SELECT 1")
		})
	}
}
