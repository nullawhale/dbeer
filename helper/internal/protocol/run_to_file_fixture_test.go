package protocol

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestCapturedFullExportAdditiveFixture(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/run-to-file-v1.json")
	if err != nil {
		t.Fatal("read fixture")
	}
	var fixture struct {
		Export                         ExportRequest
		Progress                       map[string]any
		SQLCompletedPublicationFailed  map[string]any
		SQLCompletedPublicationUnknown map[string]any
	}
	if json.Unmarshal(data, &fixture) != nil {
		t.Fatal("decode fixture")
	}
	fixture.Export.Path = filepath.Join(t.TempDir(), "output.csv")
	if !fixture.Export.Valid() || fixture.Export.Destination == nil {
		t.Fatal("invalid captured export")
	}
	for _, publication := range []string{"notPublished", "unknown"} {
		response := Response{Type: "error", RequestID: "full-export", SessionID: "original-sql-session", QueryID: "original-query", Category: "export", Connected: true, TransactionStatus: "idle", SQLCompleted: true, ExportPublication: publication}
		encoded, err := json.Marshal(response)
		if err != nil {
			t.Fatal("encode")
		}
		var fields map[string]any
		if json.Unmarshal(encoded, &fields) != nil || fields["sqlCompleted"] != true || fields["exportPublication"] != publication || fields["outcomeUnknown"] != false {
			t.Fatal("SQL/publication distinction lost")
		}
	}
	invalid := *fixture.Export.Destination
	invalid.SHA256 = "not-a-digest"
	if invalid.Valid() {
		t.Fatal("invalid fingerprint accepted")
	}
}
