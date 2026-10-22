package schemacompare

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func testCapture(schema string) Capture {
	ref := Ref{Kind: "table", Schema: schema, Name: "orders"}
	typ := TypeUse{Ref: Ref{Kind: "type", Schema: "pg_catalog", Name: "numeric"}, Kind: "builtin", Modifiers: Known(TypeModifiers{}), Labels: Complete[string](nil)}
	column := Column{Ref: Ref{Kind: "column", Schema: schema, Table: "orders", Name: "id"}, Ordinal: Known(0), Type: Known(typ), Nullable: Known(false), Default: Known(Default{Kind: "none"}), Generated: Known(Generated{Kind: "none"}), Identity: Known(Identity{Kind: "none"}), Charset: Absent[string](), Collation: Absent[Ref](), Visible: Known(true), Comment: Known(""), OnUpdate: Absent[Expression]()}
	return Capture{Context: CaptureContext{Engine: "postgresql", Version: "17", Database: "fixture", StartedAt: "2026-10-22T10:00:00Z", FinishedAt: "2026-10-22T10:00:01Z", Consistency: "repeatableRead", Visibility: "complete", EngineContext: Known([]Option{})}, Inventories: []Inventory{{Schema: schema, Existence: "present", Tables: Complete([]Ref{ref}), Types: Complete[Ref](nil)}}, Tables: []Table{{Ref: ref, Kind: Known("r"), Storage: Known("p"), Charset: Absent[string](), Collation: Absent[Ref](), Options: Complete[Option](nil), Columns: Complete([]Column{column}), Constraints: Complete[Constraint](nil), Indexes: Complete[Index](nil), Dependencies: Complete[Dependency](nil)}}, Types: []TypeDefinition{}, Sequences: []Sequence{}, Issues: []Issue{}}
}
func testMappings() Mappings {
	return Mappings{Schemas: []NamePair{{"a", "b"}}, Tables: []TablePair{}, Types: []ObjectPair{}}
}
func buildTest(t *testing.T, a, b Capture, m Mappings) *Result {
	t.Helper()
	r, e := Build(context.Background(), t.TempDir(), a, b, m)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { r.Close() })
	return r
}
func TestPortableFactsUnknownsAndObjectCounts(t *testing.T) {
	a, b := testCapture("a"), testCapture("b")
	r := buildTest(t, a, b, testMappings())
	if !r.Report.Summary.FullEquality || r.Report.Summary.EqualObjects != 1 {
		t.Fatal("schema remapping failed")
	}
	b.Tables[0].Columns.Items[0].Nullable = Unknown[bool]("inaccessible")
	a.Tables[0].Columns.Items[0].Nullable = Unknown[bool]("inaccessible")
	r = buildTest(t, a, b, testMappings())
	if r.Report.Summary.FullEquality || r.Report.Summary.Complete || r.Report.Summary.IndeterminateObjects != 1 {
		t.Fatal("unknown/unknown established equality")
	}
	a, b = testCapture("a"), testCapture("b")
	b.Tables[0].Columns.Items = append(b.Tables[0].Columns.Items, b.Tables[0].Columns.Items[0])
	b.Tables[0].Columns.Items[1].Ref.Name = "new"
	b.Tables[0].Columns.Items[1].Ordinal = Known(1)
	r = buildTest(t, a, b, testMappings())
	if r.Report.Summary.ChangedObjects != 1 || r.Report.Summary.TargetOnlyObjects != 0 {
		t.Fatal("member addition incorrectly counted as whole object")
	}
}
func TestExplicitOverridesConsumeEndpointsAndNeverRewriteExpressions(t *testing.T) {
	a, b := testCapture("a"), testCapture("b")
	a.Tables = append(a.Tables, a.Tables[0])
	a.Tables[1].Ref.Name = "other"
	a.Tables[1].Columns.Items = []Column{}
	b.Tables = append(b.Tables, b.Tables[0])
	b.Tables[1].Ref.Name = "other"
	b.Tables[1].Columns.Items = []Column{}
	m := testMappings()
	m.Tables = []TablePair{{Source: QualifiedName{"a", "orders"}, Target: QualifiedName{"b", "other"}, Columns: []NamePair{}, Constraints: []NamePair{}, Indexes: []NamePair{}}}
	r := buildTest(t, a, b, m)
	if r.Report.Summary.SourceOnlyObjects != 1 || r.Report.Summary.TargetOnlyObjects != 1 {
		t.Fatal("explicit mapping did not consume endpoints")
	}
	a, b = testCapture("a"), testCapture("b")
	a.Tables[0].Columns.Items[0].Default = Known(Default{Kind: "expression", Expression: &Expression{Text: "'a.orders'", Dependencies: Complete[Ref](nil)}})
	b.Tables[0].Columns.Items[0].Default = Known(Default{Kind: "expression", Expression: &Expression{Text: "'b.orders'", Dependencies: Complete[Ref](nil)}})
	r = buildTest(t, a, b, testMappings())
	if r.Report.Summary.DifferenceCount != 1 {
		t.Fatal("expression text was rewritten")
	}
}
func TestBoundedPagesExactChunksExportAndDigest(t *testing.T) {
	a, b := testCapture("a"), testCapture("b")
	a.Tables[0].Columns.Items[0].Comment = Known(strings.Repeat("猫", 1000))
	r := buildTest(t, a, b, testMappings())
	p, e := r.Page("differences", 0, 1, 4096)
	if e != nil || len(p.Items) != 1 || p.NextOffset != 1 {
		t.Fatal("page failed")
	}
	var d Difference
	if json.Unmarshal(p.Items[0], &d) != nil || !d.SourcePreview.Truncated {
		t.Fatal("preview missing")
	}
	var value []byte
	for offset := int64(0); ; {
		c, e := r.Chunk(d.SourcePreview.ValueRef, offset, 17, false)
		if e != nil {
			t.Fatal(e)
		}
		part, _ := base64.StdEncoding.DecodeString(c.DataBase64)
		value = append(value, part...)
		offset = c.NextOffset
		if !c.HasMore {
			break
		}
	}
	var fact Fact[string]
	if json.Unmarshal(value, &fact) != nil || fact.Value == nil || *fact.Value != strings.Repeat("猫", 1000) {
		t.Fatal("exact property changed")
	}
	c, e := r.Chunk("", 0, 1<<20, true)
	if e != nil {
		t.Fatal(e)
	}
	report, _ := base64.StdEncoding.DecodeString(c.DataBase64)
	hash := sha256.Sum256(report)
	if hex.EncodeToString(hash[:]) != c.SHA256 {
		t.Fatal("export digest mismatch")
	}
	if info, e := os.Stat(r.dir + "/report.json"); e != nil || info.Mode().Perm() != 0600 {
		t.Fatal("report is not private")
	}
	a.Context.StartedAt = "later"
	again := buildTest(t, a, b, testMappings())
	if r.Report.Summary.ModelDigest != again.Report.Summary.ModelDigest {
		t.Fatal("capture clock changed semantic digest")
	}
	if _, e = r.Page("differences", -1, 1, 4096); e == nil {
		t.Fatal("negative offset accepted")
	}
}
func TestIncompleteInventoryNeverInfersAbsence(t *testing.T) {
	a, b := testCapture("a"), testCapture("b")
	b.Tables = []Table{}
	b.Inventories[0].Tables.Complete = false
	b.Context.Visibility = "unknown"
	r := buildTest(t, a, b, testMappings())
	if r.Report.Summary.FullEquality || r.Report.Summary.SourceOnlyObjects != 0 || r.Report.Differences[0].Kind != "indeterminate" {
		t.Fatal("partial inventory inferred absence")
	}
}
