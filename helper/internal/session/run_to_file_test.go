package session

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/exportfile"
	"dbeer/helper/internal/protocol"
	"os"
	"path/filepath"
	"testing"
)

type exportProbeSession struct {
	calls     int
	mode      string
	cancel    context.CancelFunc
	delivered int
}

func (s *exportProbeSession) Close()                    {}
func (s *exportProbeSession) TransactionStatus() string { return "transaction" }
func (s *exportProbeSession) Execute(context.Context, protocol.Command) protocol.Response {
	panic("full export must use streaming exactly once")
}
func (s *exportProbeSession) ExecuteWithSink(ctx context.Context, c protocol.Command, sink adapter.ResultSink) protocol.Response {
	s.calls++
	sets := 1
	if s.mode == "multiple-csv" {
		sets = 2
	}
	for i := 0; i < sets; i++ {
		_ = sink.Begin(i, []protocol.Column{{Index: 0, Name: "duplicate", Engine: "postgresql", NativeType: "text"}})
		for j := 0; j < 1503; j++ {
			value := "literal"
			if s.mode == "marker-collision" {
				value = `\N`
			}
			_ = sink.Row(i, []*string{&value})
			s.delivered++
		}
		_ = sink.End(i, protocol.ResultSet{CommandTag: "INSERT", RowCount: 1503})
	}
	if s.mode == "cancel-after-sql" {
		s.cancel()
	}
	if s.mode == "sql-failure" {
		r := protocol.ErrorResponse(c, "sql", "Fixture SQL failed.")
		r.Connected, r.TransactionStatus = true, "failedTransaction"
		return r
	}
	if s.mode == "lost-sql-terminal" {
		r := protocol.ErrorResponse(c, "connection", "Fixture terminal lost.")
		r.OutcomeUnknown = true
		return r
	}
	return protocol.Response{Type: "query.result", TransactionStatus: "transaction", CommandTag: "INSERT", RowCount: 1503}
}
func TestFullExportExecutesExactlyOnceDrainsFailureAndSeparatesSQLFromPublication(t *testing.T) {
	for _, mode := range []string{"success", "marker-collision", "multiple-csv", "cancel-after-sql", "sql-failure", "lost-sql-terminal", "stale-captured-target"} {
		t.Run(mode, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "output.json")
			_ = os.WriteFile(path, []byte("keep"), 0600)
			stamp, err := exportfile.CaptureDestination(path)
			if err != nil {
				t.Fatal("capture")
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			physical := &exportProbeSession{mode: mode, cancel: cancel}
			format := "json"
			if mode == "marker-collision" || mode == "multiple-csv" {
				format = "csv"
			}
			request := protocol.ExportRequest{Path: path, Format: format, Destination: &stamp}
			if mode == "stale-captured-target" {
				_ = os.WriteFile(path, []byte("external"), 0600)
			}
			response := runExecution(ctx, physical, protocol.Command{Type: "execute", RequestID: "owned", SessionID: "owned-sql-session", QueryID: "owned-query", SQL: "fixture mutation", Export: &request}, nil)
			if mode == "stale-captured-target" {
				if physical.calls != 0 || !response.SQLNotExecuted {
					t.Fatal("stale destination executed SQL")
				}
				return
			}
			if physical.calls != 1 {
				t.Fatal("SQL executed more than once")
			}
			if physical.delivered < 1503 {
				t.Fatal("file failure stopped SQL drain")
			}
			switch mode {
			case "success":
				if response.Type != "query.result" || response.ExportRowCount != 1503 {
					t.Fatal("full export incomplete")
				}
			case "marker-collision", "multiple-csv", "cancel-after-sql":
				if !response.SQLCompleted || response.OutcomeUnknown || response.ExportPublication != "notPublished" || response.TransactionStatus != "transaction" {
					t.Fatal("known SQL completion confused with save failure")
				}
			case "sql-failure":
				if response.SQLCompleted || response.TransactionStatus != "failedTransaction" {
					t.Fatal("SQL failure became success")
				}
			case "lost-sql-terminal":
				if response.SQLCompleted || !response.OutcomeUnknown {
					t.Fatal("lost terminal became known success")
				}
			}
			if mode != "success" {
				data, _ := os.ReadFile(path)
				if string(data) != "keep" {
					t.Fatal("previous destination lost")
				}
			}
			matches, _ := filepath.Glob(filepath.Join(filepath.Dir(path), ".dbeer-export-*"))
			if len(matches) != 0 {
				t.Fatal("private temporary leaked")
			}
		})
	}
}
