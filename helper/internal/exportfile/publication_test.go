package exportfile

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"dbeer/helper/internal/protocol"
)

func readyExport(t *testing.T, path string) *Writer {
	t.Helper()
	stamp, err := CaptureDestination(path)
	if err != nil {
		t.Fatal("capture failed")
	}
	writer, err := New(protocol.ExportRequest{Path: path, Format: "json", Destination: &stamp})
	if err != nil {
		t.Fatal("prepare failed")
	}
	if writer.Begin(0, []protocol.Column{}) != nil || writer.End(0, protocol.ResultSet{CommandTag: "SELECT"}) != nil {
		t.Fatal("stream failed")
	}
	t.Cleanup(writer.Abort)
	return writer
}
func unchanged(t *testing.T, path string) {
	t.Helper()
	bytes, err := os.ReadFile(path)
	if err != nil || string(bytes) != "keep" {
		t.Fatal("preexisting destination was lost")
	}
}
func TestCapturedTargetChangedAppearedOrRemovedIsNeverReplaced(t *testing.T) {
	for _, mode := range []string{"edited", "appeared", "removed", "stamp-before-query"} {
		t.Run(mode, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "output.json")
			if mode != "appeared" {
				if os.WriteFile(path, []byte("keep"), 0600) != nil {
					t.Fatal("fixture")
				}
			}
			stamp, err := CaptureDestination(path)
			if err != nil {
				t.Fatal("capture")
			}
			if mode == "stamp-before-query" {
				_ = os.WriteFile(path, []byte("external"), 0600)
				if _, err := New(protocol.ExportRequest{Path: path, Format: "json", Destination: &stamp}); err == nil {
					t.Fatal("changed captured destination accepted")
				}
				return
			}
			writer := readyExport(t, path)
			switch mode {
			case "removed":
				_ = os.Remove(path)
			default:
				_ = os.WriteFile(path, []byte("external"), 0600)
			}
			if writer.Commit() == nil {
				t.Fatal("external replacement accepted")
			}
			if mode != "removed" {
				bytes, _ := os.ReadFile(path)
				if string(bytes) != "external" {
					t.Fatal("external content overwritten")
				}
			}
		})
	}
}
func TestCancellationClosedTemporaryAndCorruptedTemporaryPreserveDestination(t *testing.T) {
	for _, mode := range []string{"cancel", "closed", "retarget-temp", "read-only"} {
		t.Run(mode, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "output.json")
			_ = os.WriteFile(path, []byte("keep"), 0600)
			writer := readyExport(t, path)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			replaced := false
			switch mode {
			case "cancel":
				cancel()
			case "closed":
				_ = writer.file.Close()
			case "retarget-temp":
				replaced = os.Remove(writer.file.Name()) == nil
				_ = os.WriteFile(writer.file.Name(), []byte("unowned"), 0600)
			case "read-only":
				_ = os.Chmod(path, 0400)
				defer os.Chmod(path, 0600)
			}
			if writer.CommitContext(ctx) == nil {
				t.Fatal("fault published")
			}
			unchanged(t, path)
			if mode == "retarget-temp" && replaced {
				data, _ := os.ReadFile(writer.file.Name())
				if string(data) != "unowned" {
					t.Fatal("cleanup removed unowned temporary")
				}
			}
		})
	}
}
func TestFullJSONStreamsBeyondEveryDisplayLimitAndPreservesOrderedSets(t *testing.T) {
	path := filepath.Join(t.TempDir(), "all.json")
	writer, err := New(protocol.ExportRequest{Path: path, Format: "json"})
	if err != nil {
		t.Fatal("new")
	}
	defer writer.Abort()
	value := string(make([]byte, 9000))
	for set := 0; set < 1027; set++ {
		columns := []protocol.Column{{Index: 0, Name: "x", Engine: "postgresql", NativeType: "text"}}
		if writer.Begin(set, columns) != nil {
			t.Fatal("begin")
		}
		rows := 1
		if set == 0 {
			rows = 1005
		}
		for row := 0; row < rows; row++ {
			if writer.Row(set, []*string{&value}) != nil {
				t.Fatal("row")
			}
		}
		if writer.End(set, protocol.ResultSet{CommandTag: "SELECT", RowCount: int64(rows)}) != nil {
			t.Fatal("end")
		}
	}
	if writer.Commit() != nil || writer.RowCount() != 2031 {
		t.Fatal("full export was truncated")
	}
	info, err := os.Stat(path)
	if err != nil || info.Size() < 8*1024*1024 {
		t.Fatal("full bytes were display bounded")
	}
}
