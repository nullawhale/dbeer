package schemabundle

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	sc "dbeer/helper/internal/schemacompare"
)

func fixture() sc.Capture {
	return sc.Capture{Context: sc.CaptureContext{Engine: "postgresql", Version: "17 on fixture", Database: "default", StartedAt: "one", FinishedAt: "two", Consistency: "repeatableRead", Visibility: "complete", EngineContext: sc.Known([]sc.Option{{Name: "locale", Value: "C"}})}, Inventories: []sc.Inventory{{Schema: "public", Existence: "present", Tables: sc.Complete([]sc.Ref{{Kind: "table", Schema: "public", Name: "A"}, {Kind: "table", Schema: "public", Name: "a"}}), Types: sc.Complete[sc.Ref](nil)}}, Tables: []sc.Table{{Ref: sc.Ref{Kind: "table", Schema: "public", Name: "A"}, Kind: sc.Known("r"), Storage: sc.Known("p"), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Options: sc.Complete[sc.Option](nil), Columns: sc.Complete[sc.Column](nil), Constraints: sc.Complete[sc.Constraint](nil), Indexes: sc.Complete[sc.Index](nil), Dependencies: sc.Complete[sc.Dependency](nil)}, {Ref: sc.Ref{Kind: "table", Schema: "public", Name: "a"}, Kind: sc.Known("r"), Storage: sc.Known("p"), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Options: sc.Complete[sc.Option](nil), Columns: sc.Complete[sc.Column](nil), Constraints: sc.Complete[sc.Constraint](nil), Indexes: sc.Complete[sc.Index](nil), Dependencies: sc.Complete[sc.Dependency](nil)}}, Types: []sc.TypeDefinition{}, Sequences: []sc.Sequence{}, Issues: []sc.Issue{}}
}
func renderer(_ context.Context, _ sc.Capture, r sc.Ref) (sc.Definition, error) {
	if r.Kind == "schema" {
		return sc.Definition{SQL: "CREATE SCHEMA bad;", Limited: true}, nil
	}
	return sc.Definition{SQL: "CREATE TABLE \"" + r.Schema + "\".\"" + strings.ReplaceAll(r.Name, "\"", "\"\"") + "\" ();\n"}, nil
}
func contents(t *testing.T, r *Result) map[string][]byte {
	t.Helper()
	out := map[string][]byte{}
	for id, f := range r.descriptions {
		var b []byte
		var offset int64
		for {
			c, e := r.Chunk(context.Background(), id, offset, 7)
			if e != nil {
				t.Fatal(e)
			}
			part, e := base64.StdEncoding.DecodeString(c.DataBase64)
			if e != nil {
				t.Fatal(e)
			}
			b = append(b, part...)
			offset = c.NextOffset
			if !c.HasMore {
				break
			}
		}
		if digest(b) != f.SHA256 || int64(len(b)) != f.Bytes {
			t.Fatal("file hash mismatch")
		}
		out[f.Path] = b
	}
	return out
}
func TestEveryByteDeterministicAndPortable(t *testing.T) {
	a := fixture()
	b := fixture()
	b.Context.StartedAt = "tomorrow"
	b.Context.FinishedAt = "later"
	b.Context.Database = "different default"
	b.Context.Version = "other runtime"
	b.Inventories[0].Tables.Items[0], b.Inventories[0].Tables.Items[1] = b.Inventories[0].Tables.Items[1], b.Inventories[0].Tables.Items[0]
	b.Tables[0], b.Tables[1] = b.Tables[1], b.Tables[0]
	first, e := Build(context.Background(), t.TempDir(), a, []string{"public"}, renderer)
	if e != nil {
		t.Fatal(e)
	}
	defer first.Close()
	second, e := Build(context.Background(), t.TempDir(), b, []string{"public"}, renderer)
	if e != nil {
		t.Fatal(e)
	}
	defer second.Close()
	if first.Summary.Included != 2 {
		t.Fatal("complete tables were omitted")
	}
	if !reflect.DeepEqual(contents(t, first), contents(t, second)) || !reflect.DeepEqual(first.Summary, second.Summary) {
		t.Fatal("portable bundle changed with capture clocks/provenance/order")
	}
	if a.Context.StartedAt != "one" {
		t.Fatal("capture mutated")
	}
	var snapshot sc.Capture
	if json.Unmarshal(contents(t, first)["capture.json"], &snapshot) != nil || snapshot.Context.Database != "" || snapshot.Tables[0].Ref.Schema != "public" {
		t.Fatal("logical namespace lost or provenance retained")
	}
}
func TestExactUnicodeCaseAndLongPathIdentity(t *testing.T) {
	c := fixture()
	c.Tables = nil
	c.Inventories[0].Tables.Items = nil
	for _, name := range []string{"A", "a", "é", "e\u0301", strings.Repeat("界", 80), "../escape\nCREATE TABLE injected(x int);"} {
		ref := sc.Ref{Kind: "table", Schema: "public", Name: name}
		c.Tables = append(c.Tables, sc.Table{Ref: ref, Kind: sc.Known("r"), Storage: sc.Known("p"), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Options: sc.Complete[sc.Option](nil), Columns: sc.Complete[sc.Column](nil), Constraints: sc.Complete[sc.Constraint](nil), Indexes: sc.Complete[sc.Index](nil), Dependencies: sc.Complete[sc.Dependency](nil)})
		c.Inventories[0].Tables.Items = append(c.Inventories[0].Tables.Items, ref)
	}
	r, e := Build(context.Background(), t.TempDir(), c, []string{"public"}, renderer)
	if e != nil {
		t.Fatal(e)
	}
	defer r.Close()
	seen := map[string]bool{}
	for _, o := range r.Manifest.Objects {
		path := o.File.Path
		if filepath.Base(path) != path || len(path) > 100 || seen[strings.ToLower(path)] {
			t.Fatal("unsafe, too long, or case-colliding path")
		}
		seen[strings.ToLower(path)] = true
	}
}
func TestUnsupportedPrefixAndDependencyNeverExecutable(t *testing.T) {
	c := fixture()
	bad := sc.Ref{Kind: "type", Schema: "public", Name: "bad\nCREATE TABLE injected(x int);\rSELECT 1;\u2028DROP TABLE x;"}
	c.Types = []sc.TypeDefinition{{Ref: bad}}
	c.Tables[0].Dependencies = sc.Complete([]sc.Dependency{{From: c.Tables[0].Ref, To: bad, Kind: "catalogReference", State: "observed"}})
	r, e := Build(context.Background(), t.TempDir(), c, []string{"public"}, func(ctx context.Context, c sc.Capture, r sc.Ref) (sc.Definition, error) {
		if r == bad {
			return sc.Definition{SQL: "CREATE TYPE prefix;\nDROP TABLE stolen;", Limited: true}, nil
		}
		return renderer(ctx, c, r)
	})
	if e != nil {
		t.Fatal(e)
	}
	defer r.Close()
	files := contents(t, r)
	for _, o := range r.Manifest.Objects {
		if o.Ref == bad || o.Ref == c.Tables[0].Ref {
			if o.State == "included" || !strings.HasPrefix(string(files[o.File.Path]), "-- ") || strings.Contains(string(files[o.File.Path]), "CREATE") {
				t.Fatal("unsupported definition leaked executable prefix")
			}
		}
	}
}
func TestUnknownFactsAndPartialInventoryReported(t *testing.T) {
	c := fixture()
	c.Inventories[0].Tables.Complete = false
	c.Tables[0].Kind = sc.Unknown[string]("permissionDenied")
	c.Issues = []sc.Issue{{Code: "permissionDenied", Property: "catalog", Message: "Metadata is hidden.", BlocksEquality: true, Planning: "manual"}}
	r, e := Build(context.Background(), t.TempDir(), c, []string{"public"}, renderer)
	if e != nil {
		t.Fatal(e)
	}
	defer r.Close()
	if r.Manifest.Complete || r.Summary.Incomplete < 2 || len(r.Manifest.Issues) != 1 {
		t.Fatal("partial capture apparently complete")
	}
}
func TestCancellationQuotaAndExistingFiles(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, e := Build(ctx, t.TempDir(), fixture(), []string{"public"}, renderer); !errors.Is(e, context.Canceled) {
		t.Fatal("cancel ignored")
	}
	c := fixture()
	c.Context.Version = strings.Repeat("v", sc.DefaultLimits().Scalar+1)
	if _, e := Build(context.Background(), t.TempDir(), c, []string{"public"}, renderer); !errors.Is(e, sc.ErrLimit) {
		t.Fatal("scalar quota ignored")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "capture.json")
	if e := os.WriteFile(path, []byte("foreign"), 0600); e != nil {
		t.Fatal(e)
	}
	if _, e := Build(context.Background(), dir, fixture(), []string{"public"}, renderer); e == nil {
		t.Fatal("existing file overwritten")
	}
	if data, e := os.ReadFile(path); e != nil || string(data) != "foreign" {
		t.Fatal("foreign file changed")
	}
}
func TestFileWhitelistOffsetAndCancellation(t *testing.T) {
	r, e := Build(context.Background(), t.TempDir(), fixture(), []string{"public"}, renderer)
	if e != nil {
		t.Fatal(e)
	}
	defer r.Close()
	for _, id := range []string{"../capture.json", "capture.json", strings.Repeat("a", 64)} {
		if _, e = r.Chunk(context.Background(), id, 0, 100); e == nil {
			t.Fatal("unknown file accepted")
		}
	}
	for _, offset := range []int64{-1, r.Summary.Manifest.Bytes + 1} {
		if _, e = r.Chunk(context.Background(), "manifest", offset, 100); e == nil {
			t.Fatal("invalid offset accepted")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, e = r.Chunk(ctx, "manifest", 0, 100); !errors.Is(e, context.Canceled) {
		t.Fatal("late chunk delivered after cancellation")
	}
}

func TestExternalAndRowTypeMetadataRemainPortableWithoutRejectingSelection(t *testing.T) {
	c := fixture()
	external := sc.Ref{Kind: "type", Schema: "shared", Name: "status"}
	row := sc.Ref{Kind: "type", Schema: "public", Name: "a", RowType: true}
	c.Types = []sc.TypeDefinition{{Ref: external}, {Ref: row}}
	c.Sequences = []sc.Sequence{{Ref: sc.Ref{Kind: "sequence", Schema: "shared", Name: "counter"}}}
	c.Tables[0].Dependencies = sc.Complete([]sc.Dependency{{From: c.Tables[0].Ref, To: external, Kind: "catalogReference", State: "observed"}, {From: c.Tables[0].Ref, To: row, Kind: "catalogReference", State: "observed"}})
	r, e := Build(context.Background(), t.TempDir(), c, []string{"public"}, renderer)
	if e != nil {
		t.Fatal(e)
	}
	defer r.Close()
	for _, object := range r.Manifest.Objects {
		if object.Ref == c.Tables[0].Ref {
			if object.State != "incomplete" {
				t.Fatal("external dependency apparently executable")
			}
			found := false
			for _, dependency := range object.Dependencies {
				if dependency.Ref == external && dependency.State == "external" {
					found = true
				}
			}
			if !found {
				t.Fatal("external semantic ref lost")
			}
		}
		if object.Ref.RowType || object.Ref.Schema == "shared" {
			t.Fatal("scope silently expanded")
		}
	}
	var portable sc.Capture
	if json.Unmarshal(contents(t, r)["capture.json"], &portable) != nil || len(portable.Types) != 2 || len(portable.Sequences) != 1 {
		t.Fatal("external/row metadata lost from snapshot")
	}
}
func TestInventoryCoverageIsRequired(t *testing.T) {
	for _, duplicate := range []bool{false, true} {
		c := fixture()
		if duplicate {
			c.Inventories = append(c.Inventories, c.Inventories[0])
		} else {
			c.Inventories = nil
		}
		if _, e := Build(context.Background(), t.TempDir(), c, []string{"public"}, renderer); !errors.Is(e, ErrInvalid) {
			t.Fatal("missing/duplicate inventory accepted as complete")
		}
	}
}
func TestHundredsOfObjectsUseBoundedDescriptors(t *testing.T) {
	before, inventoryErr := os.ReadDir("/dev/fd")
	c := fixture()
	c.Tables = nil
	c.Inventories[0].Tables.Items = nil
	for i := 0; i < 600; i++ {
		table := fixture().Tables[0]
		table.Ref.Name = fmt.Sprintf("table_%04d", i)
		c.Tables = append(c.Tables, table)
		c.Inventories[0].Tables.Items = append(c.Inventories[0].Tables.Items, table.Ref)
	}
	r, e := Build(context.Background(), t.TempDir(), c, []string{"public"}, renderer)
	if e != nil {
		t.Fatal(e)
	}
	defer r.Close()
	if after, err := os.ReadDir("/dev/fd"); inventoryErr == nil && err == nil && len(after) > len(before)+8 {
		t.Fatal("retained one descriptor per object")
	}
	if r.Summary.Included != 600 {
		t.Fatal("large supported schema truncated")
	}
	// The immutable file map stores identities, not one descriptor per object.
	for id := range r.descriptions {
		if _, e = r.Chunk(context.Background(), id, 0, 1); e != nil {
			t.Fatal(e)
		}
	}
}
