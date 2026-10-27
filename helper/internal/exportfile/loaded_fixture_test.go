package exportfile

import (
	"encoding/csv"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

// Prepared cross-consumer value cases; execute only at final integration.
func TestSharedLoadedExportValuesMatchFullExportWithoutPretendingDisplayTruncation(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/loaded-export-v1.json")
	if err != nil {
		t.Fatal("cannot read shared loaded export fixture")
	}
	var fixture struct {
		NullMarker string `json:"nullMarker"`
		ResultSets []struct {
			Metadata struct {
				Columns           []protocol.Column `json:"columns"`
				CommandTag        string            `json:"commandTag"`
				RowCount          int64             `json:"rowCount"`
				DisplayedRowCount int64             `json:"displayedRowCount"`
				Truncated         bool              `json:"truncated"`
			} `json:"metadata"`
			Rows [][]*string `json:"rows"`
		} `json:"resultSets"`
		CSV []string `json:"csv"`
	}
	if json.Unmarshal(data, &fixture) != nil {
		t.Fatal("invalid shared fixture")
	}
	for i, set := range fixture.ResultSets {
		for _, format := range []string{"json", "csv"} {
			path := filepath.Join(t.TempDir(), "export."+format)
			writer, err := New(protocol.ExportRequest{Path: path, Format: format, NullMarker: &fixture.NullMarker})
			if err != nil {
				t.Fatal("cannot prepare export")
			}
			if writer.Begin(0, set.Metadata.Columns) != nil {
				t.Fatal("cannot begin export")
			}
			for _, row := range set.Rows {
				if writer.Row(0, row) != nil {
					t.Fatal("cannot write fixture row")
				}
			}
			if writer.End(0, protocol.ResultSet{CommandTag: set.Metadata.CommandTag, RowCount: set.Metadata.RowCount}) != nil || writer.Commit() != nil {
				writer.Abort()
				t.Fatal("cannot publish export")
			}
			actual, err := os.ReadFile(path)
			if err != nil {
				t.Fatal("cannot read export")
			}
			if format == "json" {
				var value struct {
					ResultSets []struct {
						Metadata struct {
							Columns           []protocol.Column
							RowCount          int64
							DisplayedRowCount int64
							Truncated         bool
						}
						Rows [][]*string
					}
				}
				if json.Unmarshal(actual, &value) != nil || len(value.ResultSets) != 1 {
					t.Fatal("invalid full export")
				}
				got := value.ResultSets[0]
				// Full export contains all supplied rows and intentionally reports
				// truncated=false; loaded-export disclosure is a different scope.
				if !reflect.DeepEqual(got.Rows, set.Rows) || !reflect.DeepEqual(got.Metadata.Columns, set.Metadata.Columns) || got.Metadata.RowCount != set.Metadata.RowCount || got.Metadata.DisplayedRowCount != set.Metadata.DisplayedRowCount || got.Metadata.Truncated {
					t.Fatal("shared exact values or metadata changed")
				}
			} else {
				got, gotErr := csv.NewReader(strings.NewReader(string(actual))).ReadAll()
				want, wantErr := csv.NewReader(strings.NewReader(fixture.CSV[i])).ReadAll()
				// Go full CSV uses LF record separators; Swift/Rust loaded CSV
				// uses CRLF. Both preserve quoted embedded CRLF and exact values.
				if gotErr != nil || wantErr != nil || !reflect.DeepEqual(got, want) {
					t.Fatal("shared CSV values changed")
				}
			}
		}
	}
}
