package exportfile

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

func pointer(value string) *string { return &value }

func TestJSONPreservesAllResultSetsNullExactTextAndBinaryMetadata(t *testing.T) {
	path := filepath.Join(t.TempDir(), "result.json")
	writer, err := New(protocol.ExportRequest{Path: path, Format: "json"})
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Abort()
	columns := []protocol.Column{{Index: 0, Name: "x", Engine: "postgresql", NativeType: "numeric"}, {Index: 1, Name: "x", Engine: "postgresql", NativeType: "bytea", Encoding: "base64"}}
	if writer.Begin(0, columns) != nil || writer.Row(0, []*string{pointer("9007199254740993.123456789"), pointer("AP8=")}) != nil || writer.Row(0, []*string{nil, pointer("")}) != nil || writer.End(0, protocol.ResultSet{CommandTag: "SELECT 2", RowCount: 2}) != nil {
		t.Fatal("cannot write first export result")
	}
	if writer.Begin(1, []protocol.Column{}) != nil || writer.End(1, protocol.ResultSet{CommandTag: "CALL", RowCount: 0}) != nil || writer.Commit() != nil {
		t.Fatal("cannot publish multiple result export")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	fixture, err := os.ReadFile("../../../protocol/fixtures/export.json")
	if err != nil {
		t.Fatal(err)
	}
	var actual, expected any
	if json.Unmarshal(data, &actual) != nil || json.Unmarshal(fixture, &expected) != nil || !reflect.DeepEqual(actual, expected) {
		t.Fatal("full export disagrees with the shared Swift/Go JSON fixture")
	}
	var document struct {
		Version    int
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
	if json.Unmarshal(data, &document) != nil || document.Version != 1 || len(document.ResultSets) != 2 || len(document.ResultSets[0].Rows) != 2 || *document.ResultSets[0].Rows[0][0] != "9007199254740993.123456789" || document.ResultSets[0].Rows[1][0] != nil || document.ResultSets[0].Metadata.Columns[1].Encoding != "base64" || document.ResultSets[0].Metadata.Columns[0].Name != document.ResultSets[0].Metadata.Columns[1].Name || document.ResultSets[0].Metadata.Truncated {
		t.Fatal("JSON export changed ordered typed result data")
	}
}

func TestCancellationRemovesPartialBeforeDatabaseRecoveryFinishes(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "old.json")
	if os.WriteFile(path, []byte("original"), 0600) != nil {
		t.Fatal("cannot create destination fixture")
	}
	writer, err := New(protocol.ExportRequest{Path: path, Format: "json"})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	stop := writer.CancelOn(ctx)
	defer stop()
	defer writer.Abort()
	if writer.Begin(0, []protocol.Column{{Index: 0, Name: "x"}}) != nil || writer.Row(0, []*string{pointer("partial")}) != nil {
		t.Fatal("cannot start partial export")
	}
	cancel()
	deadline := time.Now().Add(time.Second)
	for {
		temporary, _ := filepath.Glob(filepath.Join(directory, ".dbeer-export-*"))
		if len(temporary) == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("cancellation retained a partial file while worker recovered")
		}
		time.Sleep(time.Millisecond)
	}
	if writer.CommitContext(ctx) != ErrCancelled {
		t.Fatal("cancelled export was published")
	}
	data, _ := os.ReadFile(path)
	if string(data) != "original" {
		t.Fatal("cancellation changed the existing destination")
	}
}

func TestFailuresAndAbortPreserveDestinationAndRemoveTemporaryFile(t *testing.T) {
	for _, scenario := range []string{"collision", "multiple sets", "abort"} {
		t.Run(scenario, func(t *testing.T) {
			directory := t.TempDir()
			path := filepath.Join(directory, "existing.csv")
			if os.WriteFile(path, []byte("original"), 0600) != nil {
				t.Fatal("cannot create destination fixture")
			}
			marker := "NULL"
			writer, err := New(protocol.ExportRequest{Path: path, Format: "csv", NullMarker: &marker})
			if err != nil {
				t.Fatal(err)
			}
			if writer.Begin(0, []protocol.Column{{Index: 0, Name: "x"}}) != nil {
				t.Fatal("cannot begin export")
			}
			switch scenario {
			case "collision":
				if writer.Row(0, []*string{&marker}) != ErrNullCollision || writer.Commit() != ErrNullCollision {
					t.Fatal("NULL collision was accepted")
				}
			case "multiple sets":
				_ = writer.End(0, protocol.ResultSet{})
				if writer.Begin(1, []protocol.Column{}) != ErrMultipleResults || writer.Commit() != ErrMultipleResults {
					t.Fatal("CSV accepted multiple column sets")
				}
			case "abort":
				_ = writer.Row(0, []*string{pointer("partial")})
				writer.Abort()
			}
			writer.Abort()
			data, _ := os.ReadFile(path)
			temporary, _ := filepath.Glob(filepath.Join(directory, ".dbeer-export-*"))
			if string(data) != "original" || len(temporary) != 0 {
				t.Fatal("failed export replaced the destination or retained a partial file")
			}
		})
	}
}
