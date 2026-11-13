package resultartifact

import (
	"context"
	"strings"
	"testing"
)

func TestNativeV3SnapshotKeepsOrderedEvidenceAndLegacyDisplaySeparate(t *testing.T) {
	rows := []byte("{\"values\":[\"deliberately unrelated display\"],\"nativeValues\":[{\"kind\":\"object\",\"entries\":[{\"key\":{\"kind\":\"text\",\"value\":\"é\"},\"value\":{\"kind\":\"integer\",\"value\":\"9007199254740993\"}},{\"key\":{\"kind\":\"text\",\"value\":\"é\"},\"value\":{\"kind\":\"binary\",\"value\":\"AP8=\"}}]}]}\n")
	manifest := rowsManifest(t, rows, 1)
	manifest["engine"] = "mongodb"
	manifest["version"] = 3
	manifest["nativeValuesFormat"] = "nativeV1"
	manifest["columns"] = []map[string]any{{"index": 0, "name": "document", "engine": "mongodb", "nativeType": "bson", "typeIdentity": "bson-v1"}}
	root := t.TempDir()
	writeArtifact(t, root, manifest, rows)
	a, err := NewStore(root).Open(context.Background(), fixtureID)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	if a.Metadata().Columns[0].Encoding != "nativeValue" {
		t.Fatal("native encoding was not retained")
	}
	seen := 0
	if err := a.Scan(context.Background(), func(ref RowRef, row []*string) error {
		seen++
		if row[0] == nil || strings.Contains(*row[0], "unrelated") || strings.Count(*row[0], "é") != 2 || !strings.Contains(*row[0], "9007199254740993") {
			t.Fatal("typed evidence was changed or replaced by display")
		}
		again, err := a.ReadRow(context.Background(), ref)
		if err != nil || *again[0] != *row[0] {
			t.Fatal("immutable native read changed")
		}
		return nil
	}); err != nil || seen != 1 {
		t.Fatal("native snapshot scan failed", err)
	}
}

func TestNativeSnapshotRejectsVersionDisguiseMalformedUnicodeAndMissingMatrices(t *testing.T) {
	for _, row := range []string{
		`{"values":["x"],"nativeValues":[]}`,
		`{"values":["x"],"nativeValues":[{"kind":"text","value":"\ud800"}]}`,
		`{"values":["x"],"nativeValues":[{"kind":"null","kind":"text","value":"x"}]}`,
		`{"values":["x"]}`,
		`{"values":["x"],"nativeValues":[{"kind":"null"}],"extra":true}`,
	} {
		data := []byte(row + "\n")
		m := rowsManifest(t, data, 1)
		m["version"] = 3
		m["nativeValuesFormat"] = "nativeV1"
		m["columns"] = []map[string]any{{"index": 0, "name": "x", "nativeType": "text"}}
		root := t.TempDir()
		writeArtifact(t, root, m, data)
		if a, e := NewStore(root).Open(context.Background(), fixtureID); e == nil {
			a.Close()
			t.Fatal("invalid native snapshot accepted")
		}
	}
	data := []byte("[\"legacy\"]\n")
	for _, version := range []int{1, 2} {
		m := rowsManifest(t, data, 1)
		m["version"] = version
		m["nativeValuesFormat"] = "nativeV1"
		root := t.TempDir()
		writeArtifact(t, root, m, data)
		if a, e := NewStore(root).Open(context.Background(), fixtureID); e == nil {
			a.Close()
			t.Fatal("new matrix format accepted in old version")
		}
	}
	// Legacy version3 rows remain explicitly display-only when no native format is declared.
	m := rowsManifest(t, fixtureRows(t), 3)
	m["version"] = 3
	root := t.TempDir()
	writeArtifact(t, root, m, fixtureRows(t))
	a, e := NewStore(root).Open(context.Background(), fixtureID)
	if e != nil {
		t.Fatal(e)
	}
	a.Close()
}

func TestSQLiteNativeSnapshotRequiresTheSameStorageEvidence(t *testing.T) {
	for _, native := range []string{
		`{"kind":"text","value":"42","engine":"sqlite","nativeType":"text"}`,
		`{"kind":"integer","value":"42","engine":"sqlite","nativeType":"integer"}`,
	} {
		rows := []byte(`{"values":["42"],"nativeValues":[` + native + `],"sqliteValues":[{"type":"text","value":"NDI="}]}` + "\n")
		m := rowsManifest(t, rows, 1)
		m["version"] = 3
		m["nativeValuesFormat"] = "nativeV1"
		m["engine"] = "sqlite"
		m["columns"] = []map[string]any{{"index": 0, "name": "v", "engine": "sqlite", "nativeType": "dynamic"}}
		root := t.TempDir()
		writeArtifact(t, root, m, rows)
		a, e := NewStore(root).Open(context.Background(), fixtureID)
		if strings.Contains(native, `"kind":"text"`) {
			if e != nil {
				t.Fatal(e)
			}
			a.Close()
		} else if e == nil {
			a.Close()
			t.Fatal("contradictory SQLite storage was accepted")
		}
	}
}
