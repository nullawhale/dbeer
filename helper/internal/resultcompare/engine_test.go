package resultcompare

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
	"sync/atomic"
	"testing"
)

type memorySource struct {
	meta   Metadata
	rows   [][]*string
	closed atomic.Bool
	scan   func(context.Context) error
}

func (s *memorySource) Metadata() Metadata { return s.meta }
func (s *memorySource) Scan(ctx context.Context, visit func(RowRef, []*string) error) error {
	if s.scan != nil {
		return s.scan(ctx)
	}
	for i, row := range s.rows {
		if e := ctx.Err(); e != nil {
			return e
		}
		if e := visit(RowRef{Index: int64(i), Offset: int64(i)}, row); e != nil {
			return e
		}
	}
	return nil
}
func (s *memorySource) ReadRow(ctx context.Context, ref RowRef) ([]*string, error) {
	if e := ctx.Err(); e != nil {
		return nil, e
	}
	if ref.Index < 0 || ref.Index >= int64(len(s.rows)) {
		return nil, ErrReference
	}
	return s.rows[ref.Index], nil
}
func (s *memorySource) Close() error { s.closed.Store(true); return nil }
func text(s string) *string          { return &s }
func cols(types ...string) []Column {
	c := make([]Column, len(types))
	for i, typ := range types {
		c[i] = Column{Index: i, Name: fmt.Sprintf("c%d", i), Engine: "postgresql", NativeType: typ}
		if !legacyScalar(c[i]) {
			c[i].TypeIdentity = "fixture-v1:" + typ
		}
	}
	return c
}
func source(c []Column, rows ...[]*string) *memorySource {
	return &memorySource{meta: Metadata{Columns: c, RowCount: int64(len(rows)), Complete: true}, rows: rows}
}
func compare(t *testing.T, l, r Source, o Options) *Result {
	t.Helper()
	if o.ScratchDir == "" {
		o.ScratchDir = filepath.Join(t.TempDir(), "scratch")
	}
	v, e := Compare(context.Background(), l, r, o)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { v.Close() })
	return v
}
func TestSharedTypedValueFixtures(t *testing.T) {
	data, e := os.ReadFile("../../../protocol/fixtures/result-comparison-v1.json")
	if e != nil {
		t.Fatal(e)
	}
	var f struct {
		Cases []struct {
			Name, Mode                string
			Columns                   []Mapping
			LeftColumns, RightColumns []struct {
				Index                                            int
				Name, Engine, NativeType, TypeIdentity, Encoding string
			}
			LeftRows, RightRows [][]*string
			Expected            map[string]any
		}
	}
	if e = json.Unmarshal(data, &f); e != nil {
		t.Fatal(e)
	}
	for _, c := range f.Cases {
		t.Run(c.Name, func(t *testing.T) {
			convert := func(input []struct {
				Index                                            int
				Name, Engine, NativeType, TypeIdentity, Encoding string
			}) []Column {
				output := make([]Column, len(input))
				for i, v := range input {
					output[i] = Column{Index: v.Index, Name: v.Name, Engine: v.Engine, NativeType: v.NativeType, TypeIdentity: v.TypeIdentity, Encoding: v.Encoding}
				}
				return output
			}
			l, r := source(convert(c.LeftColumns), c.LeftRows...), source(convert(c.RightColumns), c.RightRows...)
			result := compare(t, l, r, Options{Mode: c.Mode, Columns: c.Columns, MemoryBytes: 1, FanIn: 2})
			encoded, _ := json.Marshal(result.Summary())
			var got map[string]any
			json.Unmarshal(encoded, &got)
			for k, v := range c.Expected {
				if !reflect.DeepEqual(got[k], v) {
					t.Fatalf("%s got %v want %v", k, got[k], v)
				}
			}
		})
	}
}
func TestExactTypesPrecisionEncodingAndPartial(t *testing.T) {
	for _, tc := range []struct {
		name, lt, rt, lv, rv, le, re string
		uncertain, changed           int64
	}{
		{name: "precision", lt: "numeric", rt: "numeric", lv: "9007199254740993.000000001", rv: "9007199254740993.000000002", changed: 1},
		{name: "numeric spelling", lt: "numeric", rt: "numeric", lv: "1.00", rv: "1.0", changed: 1},
		{name: "type", lt: "text", rt: "varchar", lv: "same", rv: "same", changed: 1},
		{name: "binary exact spelling", lt: "bytea", rt: "bytea", lv: "AP8=", rv: "AP9=", le: "base64", re: "base64", changed: 1},
		{name: "encoding", lt: "text", rt: "text", lv: "", rv: "", le: "", re: "base64", changed: 1},
		{name: "unresolved", lt: "oid:12", rt: "oid:12", lv: "same", rv: "same", uncertain: 1},
		{name: "missingtype", lt: "", rt: "", lv: "same", rv: "same", uncertain: 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			l, r := source(cols(tc.lt), []*string{text(tc.lv)}), source(cols(tc.rt), []*string{text(tc.rv)})
			l.meta.Columns[0].Encoding = tc.le
			r.meta.Columns[0].Encoding = tc.re
			v := compare(t, l, r, Options{Mode: "rowOrder", Columns: []Mapping{{Left: 0, Right: 0}}})
			s := v.Summary()
			if s.ChangedRows != tc.changed || s.UncertainRows != tc.uncertain || s.FullEquality {
				t.Fatalf("wrong typed outcome %+v", s)
			}
		})
	}
	l, r := source(cols("text"), []*string{text("same")}), source(cols("text"), []*string{text("same")})
	l.meta.Complete = false
	v := compare(t, l, r, Options{Mode: "rowOrder", Columns: []Mapping{{}}})
	if v.Summary().FullEquality || v.Summary().Complete || v.Summary().EqualRows != 1 || len(v.Summary().Warnings) != 1 {
		t.Fatal("partial input asserted complete equality")
	}
}
func TestMappingByIndexExclusionsAndValidation(t *testing.T) {
	c := cols("text", "numeric")
	c[0].Name = "same"
	c[1].Name = "same"
	l := source(c, []*string{text("hi"), text("42")})
	right := []Column{c[1], c[0]}
	right[0].Index = 0
	right[1].Index = 1
	r := source(right, []*string{text("42"), text("hi")})
	v := compare(t, l, r, Options{Mode: "rowOrder", Columns: []Mapping{{0, 1, false}, {1, 0, false}}})
	if !v.Summary().FullEquality {
		t.Fatalf("explicit duplicate-name index mapping failed %+v", v.Summary())
	}
	v = compare(t, l, r, Options{Mode: "rowOrder", Columns: []Mapping{{0, 1, false}}})
	if v.Summary().FullEquality || v.Summary().SchemaDifferenceCount != 2 {
		t.Fatal("exclusions not disclosed")
	}
	for _, o := range []Options{{Mode: "key", Columns: []Mapping{{}}}, {Mode: "rowOrder", Columns: []Mapping{{Key: true}}}, {Mode: "rowOrder", Columns: []Mapping{{}, {}}}, {Mode: "rowOrder", Columns: []Mapping{{Left: 10}}}, {Mode: ""}} {
		o.ScratchDir = filepath.Join(t.TempDir(), "scratch")
		if _, e := Compare(context.Background(), l, r, o); !errors.Is(e, ErrConfiguration) {
			t.Fatal("invalid mapping accepted")
		}
	}
}
func TestSpillMergeDuplicatesAndOriginalIndexes(t *testing.T) {
	l, r := source(cols("text", "text")), source(cols("text", "text"))
	for i := 199; i >= 0; i-- {
		id := fmt.Sprintf("%04d", i)
		l.rows = append(l.rows, []*string{text(id), text("same")})
		r.rows = append(r.rows, []*string{text(id), text("same")})
	}
	l.rows = append(l.rows, []*string{text("0007"), text("duplicate")})
	l.meta.RowCount = int64(len(l.rows))
	r.meta.RowCount = int64(len(r.rows))
	v := compare(t, l, r, Options{Mode: "key", Columns: []Mapping{{0, 0, true}, {1, 1, false}}, MemoryBytes: 200, FanIn: 2})
	s := v.Summary()
	if s.EqualRows != 199 || s.AmbiguousRows != 3 || s.ReportRows != 3 {
		t.Fatalf("spill outcome %+v", s)
	}
	p, e := v.Page(context.Background(), 0, 100, 4096, 0)
	if e != nil {
		t.Fatal(e)
	}
	if len(p.Rows) != 3 || p.Rows[0].Kind != "ambiguous" || *p.Rows[0].LeftIndex != 192 || *p.Rows[1].LeftIndex != 200 || *p.Rows[2].RightIndex != 192 {
		t.Fatalf("arbitrary duplicate pairing/index order %+v", p)
	}
	files, e := os.ReadDir(v.scratch.dir)
	if e != nil || len(files) != 2 {
		t.Fatal("spilled runs not removed")
	}
}
func TestTaggedKeysDoNotCollide(t *testing.T) {
	l := source(cols("text", "text"), []*string{text("a"), text("bc")}, []*string{nil, text("NULL")}, []*string{text(""), text("NULL")})
	r := source(cols("text", "text"), []*string{text("ab"), text("c")}, []*string{text("NULL"), nil}, []*string{text(""), text("NULL")})
	v := compare(t, l, r, Options{Mode: "key", Columns: []Mapping{{0, 0, true}, {1, 1, true}}, MemoryBytes: 1, FanIn: 2})
	s := v.Summary()
	if s.EqualRows != 1 || s.AddedRows != 2 || s.DeletedRows != 2 || s.AmbiguousRows != 0 {
		t.Fatalf("tagged keys collided %+v", s)
	}
}
func TestLargeValuesKeysByteBoundedPagesAndChunks(t *testing.T) {
	large := strings.Repeat("世界🌍\x00", (16*1024*1024-256)/(2*16))
	l := source(cols("text", "text"), []*string{text(large), text(large)})
	r := source(cols("text", "text"), []*string{text(large), text(large + "changed")})
	v := compare(t, l, r, Options{Mode: "key", Columns: []Mapping{{0, 0, true}, {1, 1, false}}, MemoryBytes: 128, FanIn: 2})
	p, e := v.Page(context.Background(), 0, 100, 4096, 1)
	if e != nil {
		t.Fatal(e)
	}
	b, _ := json.Marshal(p)
	if len(b) > 4096 || len(p.Rows) != 1 || len(p.Rows[0].Cells) != 1 || !p.Rows[0].Cells[0].Left.Truncated {
		t.Fatalf("large pair did not fit preview %d %+v", len(b), p)
	}
	ref := p.Rows[0].Cells[0].Right.ValueRef
	var got strings.Builder
	for offset := int64(0); ; {
		chunk, e := v.Value(context.Background(), ref, offset, 65537)
		if e != nil {
			t.Fatal(e)
		}
		data, e := base64.StdEncoding.DecodeString(chunk.DataBase64)
		if e != nil || len(data) > 65537 || chunk.NextOffset != offset+int64(len(data)) {
			t.Fatal("invalid exact byte chunk")
		}
		got.Write(data)
		offset = chunk.NextOffset
		if !chunk.HasMore {
			break
		}
	}
	if got.String() != large+"changed" {
		t.Fatal("large exact value bytes changed")
	}
	if _, e := v.Value(context.Background(), ref+"bad", 0, 1); !errors.Is(e, ErrReference) {
		t.Fatal("forged value reference accepted")
	}
}
func TestWideRowsAllCellsReachableAndSummaryBounded(t *testing.T) {
	c := cols("text")
	c = make([]Column, 3000)
	row := make([]*string, len(c))
	maps := make([]Mapping, len(c))
	for i := range c {
		c[i] = Column{Index: i, Name: "same", Engine: "postgresql", NativeType: "text"}
		row[i] = text(strings.Repeat("\x00", 256))
		maps[i] = Mapping{Left: i, Right: i}
	}
	l, r := source(c, row), source(c, row)
	r.rows = [][]*string{append([]*string{}, row...)}
	r.rows[0][len(c)-1] = text("different")
	v := compare(t, l, r, Options{Mode: "rowOrder", Columns: maps})
	seen := 0
	for seen < len(c) {
		p, e := v.Page(context.Background(), 0, 1, 4096, seen)
		if e != nil {
			t.Fatal(e)
		}
		data, _ := json.Marshal(p)
		if len(data) > 4096 || len(p.Rows) != 1 || p.Rows[0].NextCellOffset <= seen {
			t.Fatal("wide row inaccessible")
		}
		for i, cell := range p.Rows[0].Cells {
			if cell.Mapping != seen+i {
				t.Fatal("noncontiguous mapping")
			}
		}
		seen = p.Rows[0].NextCellOffset
	}
	r.meta.Columns = append([]Column{}, c...)
	for i := range r.meta.Columns {
		r.meta.Columns[i].NativeType = ""
	}
	v = compare(t, l, r, Options{Mode: "rowOrder", Columns: maps})
	s := v.Summary()
	data, _ := json.Marshal(s)
	if s.SchemaDifferenceCount != 6000 || !s.SchemaDifferencesTruncated || len(s.SchemaDifferences) != 64 || len(data) > 16384 {
		t.Fatal("schema summary unbounded or exact count lost")
	}
}
func TestQuotaCancellationAndScanFailureRemoveScratch(t *testing.T) {
	l, r := source(cols("text"), []*string{text("left")}), source(cols("text"), []*string{text("right")})
	dir := filepath.Join(t.TempDir(), "scratch")
	_, e := Compare(context.Background(), l, r, Options{Mode: "key", Columns: []Mapping{{Key: true}}, ScratchDir: dir, QuotaBytes: 10, MemoryBytes: 1, FanIn: 2})
	if !errors.Is(e, ErrQuota) {
		t.Fatalf("quota error %v", e)
	}
	if _, e = os.Stat(dir); !os.IsNotExist(e) {
		t.Fatal("quota scratch leaked")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	dir = filepath.Join(t.TempDir(), "scratch")
	_, e = Compare(ctx, l, r, Options{Mode: "rowOrder", Columns: []Mapping{{}}, ScratchDir: dir})
	if !errors.Is(e, context.Canceled) {
		t.Fatal("cancel ignored")
	}
	if _, e = os.Stat(dir); !os.IsNotExist(e) {
		t.Fatal("cancelled scratch leaked")
	}
	l.scan = func(context.Context) error { return ErrSource }
	dir = filepath.Join(t.TempDir(), "scratch")
	_, e = Compare(context.Background(), l, r, Options{Mode: "rowOrder", Columns: []Mapping{{}}, ScratchDir: dir})
	if !errors.Is(e, ErrSource) {
		t.Fatal("scan failure ignored")
	}
	if _, e = os.Stat(dir); !os.IsNotExist(e) {
		t.Fatal("failed report retained")
	}
}

func TestMaximumSavedRowPairUsesPreviewsAndExactTail(t *testing.T) {
	const maximumRow = 16 * 1024 * 1024
	left := strings.Repeat("a", maximumRow-4)
	right := left[:len(left)-1] + "b"
	l, r := source(cols("text"), []*string{text(left)}), source(cols("text"), []*string{text(right)})
	encoded, e := json.Marshal(l.rows[0])
	if e != nil || len(encoded) != maximumRow {
		t.Fatal("fixture is not the supported maximum saved row")
	}
	v := compare(t, l, r, Options{Mode: "rowOrder", Columns: []Mapping{{}}})
	p, e := v.Page(context.Background(), 0, 1, 4096, 0)
	if e != nil || len(p.Rows) != 1 {
		t.Fatal("pair of maximum rows did not page")
	}
	data, _ := json.Marshal(p)
	if len(data) > 4096 {
		t.Fatal("maximum pair exceeded page budget")
	}
	chunk, e := v.Value(context.Background(), p.Rows[0].Cells[0].Right.ValueRef, int64(len(right)-20), 20)
	tail, _ := base64.StdEncoding.DecodeString(chunk.DataBase64)
	if e != nil || string(tail) != right[len(right)-20:] || chunk.HasMore || chunk.TotalBytes != int64(len(right)) {
		t.Fatal("exact maximum value tail lost")
	}
}
func TestNullPreviewAndExactChunkRemainDistinctFromEmpty(t *testing.T) {
	v := compare(t, source(cols("text"), []*string{nil}), source(cols("text"), []*string{text("")}), Options{Mode: "rowOrder", Columns: []Mapping{{}}})
	p, e := v.Page(context.Background(), 0, 1, 4096, 0)
	if e != nil {
		t.Fatal(e)
	}
	cell := p.Rows[0].Cells[0]
	if !cell.Left.IsNull || cell.Right.IsNull || !cell.Different {
		t.Fatal("NULL/empty preview conflated")
	}
	l, e := v.Value(context.Background(), cell.Left.ValueRef, 0, 1)
	if e != nil || !l.IsNull || l.DataBase64 != "" || l.HasMore || l.TotalBytes != 0 {
		t.Fatal("SQL NULL exact chunk conflated")
	}
	r, e := v.Value(context.Background(), cell.Right.ValueRef, 0, 1)
	if e != nil || r.IsNull || r.DataBase64 != "" || r.HasMore {
		t.Fatal("empty exact value conflated")
	}
}
func TestRowSourceContractFailuresDoNotProduceEquality(t *testing.T) {
	for _, mode := range []string{"key", "rowOrder"} {
		l, r := source(cols("text"), []*string{text("same")}), source(cols("text"), []*string{text("same")})
		l.meta.RowCount = 2
		dir := filepath.Join(t.TempDir(), "scratch")
		_, e := Compare(context.Background(), l, r, Options{Mode: mode, Columns: []Mapping{{Key: mode == "key"}}, ScratchDir: dir})
		if !errors.Is(e, ErrSource) {
			t.Fatal("inaccurate source count produced a comparison")
		}
		if _, e = os.Stat(dir); !os.IsNotExist(e) {
			t.Fatal("source failure scratch retained")
		}
	}
}
