package mariadb

import (
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestMariaDBRowsNativeCoercingModesRefuseBeforeWrites(t *testing.T) {
	for _, mode := range []string{"EMPTY_STRING_IS_NULL", "ORACLE"} {
		t.Run(mode, func(t *testing.T) {
			s := dataIntegrationSession(t)
			name, qualified := rowFixture(t, s, "(id INT PRIMARY KEY,payload VARCHAR(20),b VARBINARY(20)) ENGINE=InnoDB")
			dataRun(t, s, "INSERT INTO "+qualified+" VALUES(1,'retained',X'FF')")
			request := rowRequest(t, s, name, 1)
			request.Changes[0].Values = []protocol.ColumnAssignment{{Column: "payload", Value: rowCell("")}}
			importRequest := protocol.TableImportRequest{Schema: request.Schema, Table: name}
			description := importCommand(s, "import.describe", &importRequest)
			if description.TableImport == nil {
				t.Fatal("coercing mode fixture metadata unavailable")
			}
			importRequest.Fingerprint = description.TableImport.Fingerprint
			importRequest.Columns = []string{"id", "payload", "b"}
			importRequest.Rows = [][]protocol.CellValue{{rowCell("2"), rowCell(""), {Kind: "binary", Value: text("")}}}
			dataRun(t, s, "SET SESSION sql_mode='"+mode+"'")
			before := rowState(t, s)
			if mode == "EMPTY_STRING_IS_NULL" {
				result, err := s.work.client.Execute("INSERT INTO "+qualified+"(id,payload,b) VALUES(?,?,?)", 99, "", []byte{})
				if err != nil || result.Warnings != 0 || result.AffectedRows != 1 {
					t.Fatal("native empty-parameter coercion control did not complete without a warning")
				}
				result.Close()
				actual := dataRun(t, s, "SELECT payload,b FROM "+qualified+" WHERE id=99")
				if actual.Rows[0][0] != nil || actual.Rows[0][1] != nil {
					t.Fatal("native EMPTY_STRING_IS_NULL prepared parameter control did not reach NULL coercion")
				}
			}
			for _, kind := range []string{"changes.preview", "changes.apply"} {
				out := s.ExecuteChanges(t.Context(), protocol.Command{Type: kind, Changes: &request})
				if out.Category != "validation" || !strings.Contains(out.Message, mode) || out.OutcomeUnknown {
					t.Fatal("coercing native mode silently authorized an empty row value")
				}
			}
			for _, kind := range []string{"import.preview", "import.apply"} {
				out := importCommand(s, kind, &importRequest)
				if out.Category != "validation" || !strings.Contains(out.Message, mode) || out.OutcomeUnknown {
					t.Fatal("coercing native mode silently authorized empty imported values")
				}
			}
			if rowState(t, s) != before || *dataRun(t, s, "SELECT payload FROM "+qualified+" WHERE id=1").Rows[0][0] != "retained" || *dataRun(t, s, "SELECT COUNT(*) FROM "+qualified+" WHERE id=2").Rows[0][0] != "0" {
				t.Fatal("native mode refusal changed original values, imported rows or session settings")
			}
			dataRun(t, s, "SET SESSION sql_mode=''")
		})
	}
}
