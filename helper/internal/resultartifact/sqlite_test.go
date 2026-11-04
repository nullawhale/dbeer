package resultartifact

import (
	"context"
	"strings"
	"testing"
)

func TestSQLiteNativeV2SnapshotRetainsCellTypes(t *testing.T) {
	rows := []byte("{\"values\":[\"42\",\"42\",\"AP8=\"],\"sqliteValues\":[{\"type\":\"integer\",\"value\":\"42\"},{\"type\":\"text\",\"value\":\"NDI=\"},{\"type\":\"blob\",\"value\":\"AP8=\"}]}\n")
	m := rowsManifest(t, rows, 1)
	m["version"] = 2
	m["engine"] = "sqlite"
	m["columns"] = []map[string]any{{"index": 0, "name": "integer", "engine": "sqlite", "nativeType": "dynamic"}, {"index": 1, "name": "text", "engine": "sqlite", "nativeType": "dynamic"}, {"index": 2, "name": "blob", "engine": "sqlite", "nativeType": "dynamic"}}
	root := t.TempDir()
	writeArtifact(t, root, m, rows)
	a, e := NewStore(root).Open(context.Background(), fixtureID)
	if e != nil {
		t.Fatal(e)
	}
	defer a.Close()
	seen := 0
	e = a.Scan(context.Background(), func(ref RowRef, row []*string) error {
		seen++
		if len(row) != 3 || !strings.Contains(*row[0], `"type":"integer"`) || !strings.Contains(*row[1], `"type":"text"`) || !strings.Contains(*row[2], `"type":"blob"`) {
			t.Fatal("snapshot storage classes lost")
		}
		return nil
	})
	if e != nil || seen != 1 {
		t.Fatal("snapshot could not be scanned", e)
	}
}
