package exportfile

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestNativeJSONPairsExactEvidenceWithDisplayAndSharedReaderFixture(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/export-native-v2.json")
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		ResultSets []struct {
			Metadata protocol.ResultSet `json:"metadata"`
			Rows     []struct {
				Values       []*string              `json:"values"`
				NativeValues []protocol.NativeValue `json:"nativeValues"`
			} `json:"rows"`
		} `json:"resultSets"`
	}
	if json.Unmarshal(data, &doc) != nil {
		t.Fatal("invalid fixture")
	}
	path := filepath.Join(t.TempDir(), "typed.json")
	writer, err := NewWithNative(protocol.ExportRequest{Path: path, Format: "json"}, true)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Abort()
	for i, set := range doc.ResultSets {
		if err := writer.Begin(i, set.Metadata.Columns); err != nil {
			t.Fatal(err)
		}
		for _, row := range set.Rows {
			if err := writer.NativeRow(i, row.NativeValues); err != nil {
				t.Fatal(err)
			}
			if err := writer.Row(i, row.Values); err != nil {
				t.Fatal(err)
			}
		}
		if err := writer.End(i, set.Metadata); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Commit(); err != nil {
		t.Fatal(err)
	}
	actual, _ := os.ReadFile(path)
	var a, b any
	if json.Unmarshal(actual, &a) != nil || json.Unmarshal(data, &b) != nil || !reflect.DeepEqual(a, b) {
		t.Fatal("typed export changed native evidence or version")
	}
}

func TestNativeExportRejectsUnpairedRowsAndPreservesDestination(t *testing.T) {
	for _, mode := range []string{"missing", "unsolicited", "duplicate", "pending", "invalid"} {
		t.Run(mode, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "result.json")
			if os.WriteFile(path, []byte("original"), 0600) != nil {
				t.Fatal("fixture")
			}
			writer, err := NewWithNative(protocol.ExportRequest{Path: path, Format: "json"}, mode != "unsolicited")
			if err != nil {
				t.Fatal(err)
			}
			defer writer.Abort()
			if writer.Begin(0, []protocol.Column{{Index: 0, Name: "v"}}) != nil {
				t.Fatal("begin")
			}
			row := []protocol.NativeValue{protocol.NativeScalar("integer", "9007199254740993")}
			var rejected error
			switch mode {
			case "missing":
				rejected = writer.Row(0, []*string{pointer("display")})
			case "unsolicited":
				rejected = writer.NativeRow(0, row)
			case "duplicate":
				_ = writer.NativeRow(0, row)
				rejected = writer.NativeRow(0, row)
			case "pending":
				_ = writer.NativeRow(0, row)
				rejected = writer.End(0, protocol.ResultSet{})
			case "invalid":
				row[0].Kind = "unsupported"
				rejected = writer.NativeRow(0, row)
			}
			if rejected == nil || writer.Commit() == nil {
				t.Fatal("malformed native pairing accepted")
			}
			writer.Abort()
			got, _ := os.ReadFile(path)
			if string(got) != "original" {
				t.Fatal("failed typed export replaced target")
			}
		})
	}
}

func TestNativeCompleteExportBudgetsRowsRatherThanWholeFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "large.json")
	writer, err := NewWithNative(protocol.ExportRequest{Path: path, Format: "json"}, true)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Abort()
	if writer.Begin(0, []protocol.Column{{Index: 0, Name: "v"}}) != nil {
		t.Fatal("begin")
	}
	text := string(make([]byte, 40000))
	native := protocol.NativeScalar("text", text)
	for range 20 {
		if writer.NativeRow(0, []protocol.NativeValue{native}) != nil || writer.Row(0, []*string{&text}) != nil {
			t.Fatal("valid full export inherited display-matrix budget")
		}
	}
	if writer.End(0, protocol.ResultSet{RowCount: 20}) != nil || writer.Commit() != nil {
		t.Fatal("publish")
	}
	info, _ := os.Stat(path)
	if info.Size() <= protocol.MaxNativeValueBytes {
		t.Fatal("fixture did not exercise the aggregate display limit")
	}
}
