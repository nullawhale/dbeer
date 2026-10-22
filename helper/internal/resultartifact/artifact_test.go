//go:build darwin || linux

package resultartifact

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
)

const fixtureID = "11111111-1111-1111-1111-111111111111"

func fixtureDirectory() string {
	return filepath.Join("..", "..", "..", "protocol", "fixtures", "snapshot-v1", fixtureID)
}

func fixtureManifest(t *testing.T) map[string]any {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(fixtureDirectory(), "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var manifest map[string]any
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatal(err)
	}
	return manifest
}

func fixtureRows(t *testing.T) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(fixtureDirectory(), "rows.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func writeArtifact(t *testing.T, root string, manifest map[string]any, rows []byte) string {
	t.Helper()
	directory := filepath.Join(root, fixtureID)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "manifest.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "rows.jsonl"), rows, 0o600); err != nil {
		t.Fatal(err)
	}
	return directory
}

func rowsManifest(t *testing.T, rows []byte, count int64) map[string]any {
	t.Helper()
	manifest := fixtureManifest(t)
	digest := sha256.Sum256(rows)
	manifest["rowsBytes"] = len(rows)
	manifest["rowsSHA256"] = hex.EncodeToString(digest[:])
	manifest["rowCount"] = count
	manifest["sourceRowCount"] = count
	return manifest
}

func openFixture(t *testing.T) (Artifact, string) {
	t.Helper()
	root := t.TempDir()
	directory := writeArtifact(t, root, fixtureManifest(t), fixtureRows(t))
	artifact, err := NewStore(root).Open(context.Background(), fixtureID)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { artifact.Close() })
	return artifact, directory
}

func stringPointer(value string) *string { return &value }

func TestSharedSwiftFixtureExactValuesAndReusableReads(t *testing.T) {
	artifact, _ := openFixture(t)
	metadata := artifact.Metadata()
	if metadata.ID != fixtureID || metadata.Version != 1 || metadata.Engine != "postgresql" || metadata.RowCount != 3 ||
		metadata.SourceRowCount == nil || *metadata.SourceRowCount != 30 || !metadata.Truncated || !metadata.Partial ||
		metadata.Outcome != "cancelled" || metadata.Complete() || metadata.CapturedAt != 1790000000.125 || metadata.RowsBytes != 98 {
		t.Fatalf("incorrect fixture metadata: %#v", metadata)
	}
	wantColumns := []Column{
		{Index: 0, Name: "same", Engine: "postgresql", NativeType: "text", TypeOID: 25},
		{Index: 1, Name: "same", Engine: "postgresql", NativeType: "numeric", TypeOID: 1700},
		{Index: 2, Name: "binary", Engine: "postgresql", NativeType: "bytea", TypeOID: 17, Encoding: "base64"},
	}
	if !reflect.DeepEqual(metadata.Columns, wantColumns) {
		t.Fatalf("incorrect fixture columns: %#v", metadata.Columns)
	}
	want := [][]*string{
		{nil, stringPointer("9007199254740993.123456789"), stringPointer("AP8=")},
		{stringPointer(""), stringPointer("-0.000000000000000001"), stringPointer("")},
		{stringPointer("NULL"), stringPointer("1e1000"), nil},
	}
	var references []RowRef
	for iteration := 0; iteration < 2; iteration++ {
		var got [][]*string
		err := artifact.Scan(context.Background(), func(ref RowRef, row []*string) error {
			if ref.Index != int64(len(got)) || ref.Length < 1 || ref.Digest == [32]byte{} {
				t.Fatalf("incorrect row reference: %#v", ref)
			}
			got = append(got, row)
			if iteration == 0 {
				references = append(references, ref)
			} else if ref != references[len(got)-1] {
				t.Fatalf("repeated scan changed reference")
			}
			return nil
		})
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Fatalf("scan: %v, got %#v", err, got)
		}
	}
	for _, index := range []int{2, 0, 1, 2} {
		got, err := artifact.ReadRow(context.Background(), references[index])
		if err != nil || !reflect.DeepEqual(got, want[index]) {
			t.Fatalf("read row %d: %v, got %#v", index, err, got)
		}
	}
	metadata.Columns[0].Encoding = "base64"
	*metadata.SourceRowCount = 0
	*metadata.ProfileID = "modified"
	*metadata.ProfileName = "modified"
	unchanged := artifact.Metadata()
	if unchanged.Columns[0].Encoding != "" || *unchanged.SourceRowCount != 30 || *unchanged.ProfileName != "Historical profile" || *unchanged.ProfileID == "modified" {
		t.Fatal("metadata mutation changed reader state")
	}
}

func TestCompleteness(t *testing.T) {
	sourceCount := int64(3)
	base := Metadata{Outcome: "succeeded", RowCount: 3, SourceRowCount: &sourceCount}
	if !base.Complete() || !base.IsComplete() {
		t.Fatal("successful complete capture should be complete")
	}
	for _, outcome := range []string{"failed", "cancelled", "timedOut", "unknown"} {
		m := base
		m.Outcome = outcome
		if m.Complete() {
			t.Fatal("unsuccessful capture was complete")
		}
	}
	for _, flag := range []string{"partial", "truncated", "sourceCount"} {
		m := base
		switch flag {
		case "partial":
			m.Partial = true
		case "truncated":
			m.Truncated = true
		case "sourceCount":
			count := int64(30)
			m.SourceRowCount = &count
		}
		if m.Complete() {
			t.Fatalf("%s capture was complete", flag)
		}
	}
	base.SourceRowCount = nil
	if !base.Complete() {
		t.Fatal("unknown total with successful untruncated capture should be complete")
	}
}

func TestMalformedManifestRejected(t *testing.T) {
	tests := []struct {
		name   string
		modify func(map[string]any)
	}{
		{"version", func(m map[string]any) { m["version"] = 2 }},
		{"id", func(m map[string]any) { m["id"] = "22222222-2222-2222-2222-222222222222" }},
		{"blank title", func(m map[string]any) { m["title"] = " \n " }},
		{"long title", func(m map[string]any) { m["title"] = strings.Repeat("x", 4097) }},
		{"long SQL", func(m map[string]any) { m["sql"] = strings.Repeat("x", MaximumManifestBytes/2+1) }},
		{"long profile", func(m map[string]any) { m["profileName"] = strings.Repeat("x", 4097) }},
		{"invalid profile id", func(m map[string]any) { m["profileID"] = "not-a-uuid" }},
		{"long command", func(m map[string]any) { m["commandTag"] = strings.Repeat("x", 4097) }},
		{"engine", func(m map[string]any) { m["engine"] = "other" }},
		{"environment", func(m map[string]any) { m["environment"] = "other" }},
		{"outcome", func(m map[string]any) { m["outcome"] = "other" }},
		{"negative count", func(m map[string]any) { m["rowCount"] = -1 }},
		{"source count", func(m map[string]any) { m["sourceRowCount"] = 2 }},
		{"negative bytes", func(m map[string]any) { m["rowsBytes"] = -1 }},
		{"wrong bytes", func(m map[string]any) { m["rowsBytes"] = 99 }},
		{"digest case", func(m map[string]any) { m["rowsSHA256"] = strings.ToUpper(m["rowsSHA256"].(string)) }},
		{"short digest", func(m map[string]any) { m["rowsSHA256"] = "abc" }},
		{"column index", func(m map[string]any) { m["columns"].([]any)[1].(map[string]any)["index"] = 0 }},
		{"column name", func(m map[string]any) { delete(m["columns"].([]any)[0].(map[string]any), "name") }},
		{"column engine", func(m map[string]any) { m["columns"].([]any)[0].(map[string]any)["engine"] = "other" }},
		{"column encoding", func(m map[string]any) { m["columns"].([]any)[0].(map[string]any)["encoding"] = "" }},
		{"column OID overflow", func(m map[string]any) { m["columns"].([]any)[0].(map[string]any)["typeOid"] = uint64(1) << 32 }},
		{"long column name", func(m map[string]any) { m["columns"].([]any)[0].(map[string]any)["name"] = strings.Repeat("x", 65_537) }},
		{"long native type", func(m map[string]any) {
			m["columns"].([]any)[0].(map[string]any)["nativeType"] = strings.Repeat("x", 65_537)
		}},
		{"column count", func(m map[string]any) { m["columns"] = make([]any, 65_537) }},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			manifest := fixtureManifest(t)
			test.modify(manifest)
			root := t.TempDir()
			writeArtifact(t, root, manifest, fixtureRows(t))
			artifact, err := NewStore(root).Open(context.Background(), fixtureID)
			if artifact != nil {
				artifact.Close()
			}
			if !errors.Is(err, ErrCorrupt) {
				t.Fatalf("got %v, want corrupt", err)
			}
		})
	}
	for _, key := range []string{"version", "id", "title", "capturedAt", "engine", "sql", "environment", "outcome", "columns", "rowCount", "truncated", "partial", "commandTag", "rowsBytes", "rowsSHA256"} {
		for _, null := range []bool{false, true} {
			t.Run("required "+key+" null "+map[bool]string{false: "false", true: "true"}[null], func(t *testing.T) {
				manifest := fixtureManifest(t)
				if null {
					manifest[key] = nil
				} else {
					delete(manifest, key)
				}
				data, err := json.Marshal(manifest)
				if err != nil {
					t.Fatal(err)
				}
				if _, err := decodeManifest(data, fixtureID); !errors.Is(err, ErrCorrupt) {
					t.Fatalf("got %v, want corrupt", err)
				}
			})
		}
	}
}

func TestUUIDSpellingAndLegacyColumnDefaults(t *testing.T) {
	for _, id := range []string{"", "../" + fixtureID, fixtureID + "/rows.jsonl", "/" + fixtureID, "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", "11111111111111111111111111111111", fixtureID + "\x00"} {
		if artifact, err := NewStore(t.TempDir()).Open(context.Background(), id); !errors.Is(err, ErrInvalidID) || artifact != nil {
			t.Fatalf("id %q: %v", id, err)
		}
	}
	if !ValidID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa") || !ValidID(fixtureID) {
		t.Fatal("canonical id rejected")
	}
	column, err := decodeColumn([]byte(`{"index":0,"name":"same"}`), 0)
	if err != nil || column != (Column{Index: 0, Name: "same", Engine: "postgresql"}) {
		t.Fatalf("legacy column: %#v, %v", column, err)
	}
	manifest := fixtureManifest(t)
	manifest["id"] = strings.ToUpper(fixtureID)
	manifest["profileID"] = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
	data, _ := json.Marshal(manifest)
	if _, err := decodeManifest(data, fixtureID); err != nil {
		t.Fatalf("Swift UUID upper-case encoding rejected: %v", err)
	}
}

func TestCorruptRowsRejectedEvenWithMatchingChecksum(t *testing.T) {
	tests := []struct {
		name  string
		rows  []byte
		count int64
	}{
		{"width", []byte(`["only one"]` + "\n"), 1},
		{"not array", []byte(`null` + "\n"), 1},
		{"number", []byte(`[1,"x",null]` + "\n"), 1},
		{"base64", []byte(`[null,"x","not base64!"]` + "\n"), 1},
		{"base64 newline", []byte(`[null,"x","AP\n8="]` + "\n"), 1},
		{"base64 padding", []byte(`[null,"x","AP8"]` + "\n"), 1},
		{"base64 trailing", []byte(`[null,"x","AP8=AAAA"]` + "\n"), 1},
		{"unterminated line", []byte(`[null,"x",null]`), 1},
		{"blank line", []byte("\n"), 1},
		{"too many rows", []byte("[null,\"x\",null]\n[null,\"x\",null]\n"), 1},
		{"too few rows", []byte("[null,\"x\",null]\n"), 2},
		{"invalid UTF8", []byte{'[', '"', 0xff, '"', ',', '"', 'x', '"', ',', 'n', 'u', 'l', 'l', ']', '\n'}, 1},
		{"unpaired high surrogate", []byte(`["\ud800","x",null]` + "\n"), 1},
		{"unpaired low surrogate", []byte(`["\udc00","x",null]` + "\n"), 1},
		{"bad surrogate pair", []byte(`["\ud800\u0041","x",null]` + "\n"), 1},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			writeArtifact(t, root, rowsManifest(t, test.rows, test.count), test.rows)
			if artifact, err := NewStore(root).Open(context.Background(), fixtureID); !errors.Is(err, ErrCorrupt) || artifact != nil {
				t.Fatalf("got %v, want corrupt", err)
			}
		})
	}
	root := t.TempDir()
	rows := bytes.Replace(fixtureRows(t), []byte("NULL"), []byte("NOPE"), 1)
	writeArtifact(t, root, fixtureManifest(t), rows)
	if _, err := NewStore(root).Open(context.Background(), fixtureID); !errors.Is(err, ErrCorrupt) {
		t.Fatalf("stale checksum: %v", err)
	}
}

func TestJSONValidationPreservesEscapesAndUnicode(t *testing.T) {
	valid := []string{
		`["\ud83c\udf7a","1","AP8="]`,
		`["\\ud800","1",null]`,
		`["🍺","1",null]`,
		`["\u0000","1",null]`,
		`["line\nsecond","1",null]`,
	}
	columns := []Column{{}, {}, {Encoding: "base64"}}
	for _, text := range valid {
		if _, err := decodeRow([]byte(text), columns); err != nil {
			t.Fatalf("valid JSON %s rejected: %v", text, err)
		}
	}
	for _, text := range []string{`{"a":1,"a":2}`, `{"a":1} {}`, `{"a":"\ud800"}`, `{"a":"\udc00"}`} {
		if _, err := decodeObject([]byte(text)); !errors.Is(err, ErrCorrupt) {
			t.Fatalf("invalid object accepted: %s", text)
		}
	}
}

func TestEmptyRowsAndZeroWidthRows(t *testing.T) {
	for _, rows := range [][]byte{nil, []byte("[]\n[]\n")} {
		manifest := rowsManifest(t, rows, int64(bytes.Count(rows, []byte{'\n'})))
		manifest["columns"] = []any{}
		root := t.TempDir()
		writeArtifact(t, root, manifest, rows)
		artifact, err := NewStore(root).Open(context.Background(), fixtureID)
		if err != nil {
			t.Fatal(err)
		}
		var seen int64
		err = artifact.Scan(context.Background(), func(ref RowRef, row []*string) error {
			seen++
			if len(row) != 0 {
				t.Fatal("nonempty zero-width row")
			}
			_, err := artifact.ReadRow(context.Background(), ref)
			return err
		})
		artifact.Close()
		if err != nil || seen != manifest["rowCount"] {
			t.Fatalf("empty scan: %d, %v", seen, err)
		}
	}
}

func TestCancellationCloseAndCallbackErrors(t *testing.T) {
	artifact, _ := openFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := NewStore(t.TempDir()).Open(ctx, fixtureID); !errors.Is(err, context.Canceled) {
		t.Fatalf("open cancellation: %v", err)
	}
	if err := artifact.Scan(ctx, nil); !errors.Is(err, context.Canceled) {
		t.Fatalf("scan cancellation: %v", err)
	}
	var ref RowRef
	var visits int
	ctx, cancel = context.WithCancel(context.Background())
	err := artifact.Scan(ctx, func(value RowRef, _ []*string) error {
		visits++
		ref = value
		cancel()
		return nil
	})
	if !errors.Is(err, context.Canceled) || visits != 1 {
		t.Fatalf("scan cancellation after callback: %d, %v", visits, err)
	}
	if _, err := artifact.ReadRow(ctx, ref); !errors.Is(err, context.Canceled) {
		t.Fatalf("read cancellation: %v", err)
	}
	sentinel := errors.New("callback stopped")
	if err := artifact.Scan(context.Background(), func(RowRef, []*string) error { return sentinel }); !errors.Is(err, sentinel) {
		t.Fatalf("callback error: %v", err)
	}
	if err := artifact.Close(); err != nil {
		t.Fatal(err)
	}
	if err := artifact.Close(); err != nil {
		t.Fatal(err)
	}
	if err := artifact.Scan(context.Background(), nil); !errors.Is(err, ErrClosed) {
		t.Fatalf("closed scan: %v", err)
	}
	if _, err := artifact.ReadRow(context.Background(), ref); !errors.Is(err, ErrClosed) {
		t.Fatalf("closed read: %v", err)
	}
}

func TestReferencesAreAuthenticatedAndConcurrent(t *testing.T) {
	artifact, directory := openFixture(t)
	var references []RowRef
	if err := artifact.Scan(context.Background(), func(ref RowRef, _ []*string) error {
		references = append(references, ref)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	other, err := NewStore(filepath.Dir(directory)).Open(context.Background(), fixtureID)
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	if _, err := other.ReadRow(context.Background(), references[0]); !errors.Is(err, ErrCorrupt) {
		t.Fatalf("cross-reader reference accepted: %v", err)
	}
	for _, field := range []string{"index", "offset", "length", "digest", "overflow"} {
		ref := references[0]
		switch field {
		case "index":
			ref.Index++
		case "offset":
			ref.Offset++
		case "length":
			ref.Length--
		case "digest":
			ref.Digest[0]++
		case "overflow":
			ref.Offset = 1<<63 - 1
		}
		if _, err := artifact.ReadRow(context.Background(), ref); !errors.Is(err, ErrCorrupt) {
			t.Fatalf("forged %s accepted: %v", field, err)
		}
	}
	var group sync.WaitGroup
	for range 8 {
		group.Go(func() {
			for _, ref := range references {
				if _, err := artifact.ReadRow(context.Background(), ref); err != nil {
					t.Errorf("concurrent read: %v", err)
				}
			}
			if err := artifact.Scan(context.Background(), nil); err != nil {
				t.Errorf("concurrent scan: %v", err)
			}
		})
	}
	group.Wait()
}

func TestConfiguredQuotaAndBoundedMetadata(t *testing.T) {
	for _, settings := range []string{
		`{"version":1,"quotaBytes":1}`,
		`{"version":1,"quotaBytes":0}`,
		`{"version":2,"quotaBytes":100000}`,
		`{"version":1,"quotaBytes":100000,"quotaBytes":200000}`,
		`{"version":1}`,
		strings.Repeat(" ", maximumSettingsBytes+1),
	} {
		root := t.TempDir()
		writeArtifact(t, root, fixtureManifest(t), fixtureRows(t))
		if err := os.WriteFile(filepath.Join(root, "settings.json"), []byte(settings), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := NewStore(root).Open(context.Background(), fixtureID); !errors.Is(err, ErrCorrupt) {
			t.Fatalf("settings %q: %v", settings[:min(len(settings), 80)], err)
		}
	}
	root := t.TempDir()
	directory := writeArtifact(t, root, fixtureManifest(t), fixtureRows(t))
	manifestInfo, err := os.Stat(filepath.Join(directory, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, quota := range []int64{manifestInfo.Size() + 97, manifestInfo.Size() + 98, DefaultQuotaBytes * 2} {
		data, _ := json.Marshal(map[string]any{"version": 1, "quotaBytes": quota})
		if err := os.WriteFile(filepath.Join(root, "settings.json"), data, 0o600); err != nil {
			t.Fatal(err)
		}
		artifact, err := NewStore(root).Open(context.Background(), fixtureID)
		if quota == manifestInfo.Size()+97 {
			if !errors.Is(err, ErrCorrupt) {
				t.Fatalf("quota below artifact: %v", err)
			}
		} else if err != nil {
			t.Fatalf("configured quota %d: %v", quota, err)
		}
		if artifact != nil {
			artifact.Close()
		}
	}
	if err := os.WriteFile(filepath.Join(directory, "manifest.json"), bytes.Repeat([]byte{' '}, MaximumManifestBytes+1), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := NewStore(root).Open(context.Background(), fixtureID); !errors.Is(err, ErrCorrupt) {
		t.Fatalf("oversize metadata: %v", err)
	}
}

func TestMaximumRowSupportedAndLargerRowRejected(t *testing.T) {
	for _, encodedSize := range []int{MaximumRowBytes, MaximumRowBytes + 1} {
		root := t.TempDir()
		rows := append([]byte(`["`), bytes.Repeat([]byte{'x'}, encodedSize-4)...)
		rows = append(rows, '"', ']', '\n')
		manifest := rowsManifest(t, rows, 1)
		manifest["columns"] = []any{map[string]any{"index": 0, "name": "long", "engine": "mysql", "nativeType": "longtext", "typeOid": 0}}
		writeArtifact(t, root, manifest, rows)
		artifact, err := NewStore(root).Open(context.Background(), fixtureID)
		if encodedSize > MaximumRowBytes {
			if !errors.Is(err, ErrCorrupt) {
				t.Fatalf("oversize row: %v", err)
			}
			continue
		}
		if err != nil {
			t.Fatalf("maximum row: %v", err)
		}
		err = artifact.Scan(context.Background(), func(ref RowRef, row []*string) error {
			if ref.Length != MaximumRowBytes+1 || len(*row[0]) != MaximumRowBytes-4 {
				t.Fatal("maximum row was truncated")
			}
			read, err := artifact.ReadRow(context.Background(), ref)
			if err != nil || *read[0] != *row[0] {
				t.Fatalf("maximum read row: %v", err)
			}
			return nil
		})
		artifact.Close()
		if err != nil {
			t.Fatal(err)
		}
	}
}
