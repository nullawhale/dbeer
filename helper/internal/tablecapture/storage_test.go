package tablecapture

import (
	"context"
	"dbeer/helper/internal/resultartifact"

	"encoding/json"
	"os"
	"testing"
)

func TestPrivateCaptureReusesVerifiedArtifactReader(t *testing.T) {
	root := t.TempDir()
	budget := &Budget{Limit: 128 << 20}
	columns := []Column{{Index: 0, Name: "value", NativeType: "numeric"}}
	writer, e := NewWriter(root, columns, "postgresql", budget)
	if e != nil {
		t.Fatal(e)
	}
	value := "9007199254740993.123456789"
	if e = writer.Row([]*string{&value}); e != nil {
		t.Fatal(e)
	}
	writer.Close()
	artifact, e := writer.Publish(context.Background(), Outcome{PartialReasons: []string{}})
	if e != nil {
		t.Fatal(e)
	}
	source := artifact
	defer source.Close()
	if !source.Metadata().Complete() {
		t.Fatal("complete capture lost")
	}
	var ref resultartifact.RowRef
	if e = source.Scan(context.Background(), func(r resultartifact.RowRef, row []*string) error {
		ref = r
		if row[0] == nil || *row[0] != value {
			t.Fatal("exact data changed")
		}
		return nil
	}); e != nil {
		t.Fatal(e)
	}
	ref.Offset++
	if _, e = source.ReadRow(context.Background(), ref); e == nil {
		t.Fatal("forged row reference admitted")
	}
	info, e := os.Stat(root + "/" + writer.ID + "/rows.jsonl")
	if e != nil || info.Mode().Perm() != 0600 {
		t.Fatal("capture not private")
	}
	if _, e = os.Stat(root + "/" + writer.ID + "/manifest.json"); e != nil {
		t.Fatal("manifest missing")
	}
	var manifest map[string]json.RawMessage
	b, _ := os.ReadFile(root + "/" + writer.ID + "/manifest.json")
	_ = json.Unmarshal(b, &manifest)
	if _, ok := manifest["profileID"]; ok {
		t.Fatal("profile metadata persisted")
	}
}
