package schemacompare

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"unicode/utf8"
)

type Scope struct {
	Kind                string   `json:"kind"`
	ExcludedObjectKinds []string `json:"excludedObjectKinds"`
}
type Summary struct {
	FormatVersion        int            `json:"formatVersion"`
	Engine               string         `json:"engine"`
	Source               CaptureContext `json:"source"`
	Target               CaptureContext `json:"target"`
	Mappings             Mappings       `json:"mappings"`
	Scope                Scope          `json:"scope"`
	EqualObjects         int64          `json:"equalObjects"`
	SourceOnlyObjects    int64          `json:"sourceOnlyObjects"`
	TargetOnlyObjects    int64          `json:"targetOnlyObjects"`
	ChangedObjects       int64          `json:"changedObjects"`
	IndeterminateObjects int64          `json:"indeterminateObjects"`
	DifferenceCount      int64          `json:"differenceCount"`
	IssueCount           int64          `json:"issueCount"`
	Complete             bool           `json:"complete"`
	FullEquality         bool           `json:"fullEquality"`
	ModelDigest          string         `json:"modelDigest"`
}
type Preview struct {
	Text       string `json:"text"`
	TotalBytes int64  `json:"totalBytes"`
	Truncated  bool   `json:"truncated"`
	ValueRef   string `json:"valueRef"`
}
type Difference struct {
	Index         int64    `json:"index"`
	SourceRef     *Ref     `json:"sourceRef,omitempty"`
	TargetRef     *Ref     `json:"targetRef,omitempty"`
	Property      string   `json:"property"`
	Kind          string   `json:"kind"`
	SourcePreview *Preview `json:"sourcePreview,omitempty"`
	TargetPreview *Preview `json:"targetPreview,omitempty"`
	Planning      string   `json:"planning"`
	ReasonCodes   []string `json:"reasonCodes"`
}
type Page struct {
	Collection string            `json:"collection"`
	Offset     int64             `json:"offset"`
	NextOffset int64             `json:"nextOffset"`
	HasMore    bool              `json:"hasMore"`
	Items      []json.RawMessage `json:"items"`
}
type Chunk struct {
	ValueRef   string `json:"valueRef,omitempty"`
	SHA256     string `json:"sha256,omitempty"`
	TotalBytes int64  `json:"totalBytes"`
	Offset     int64  `json:"offset"`
	NextOffset int64  `json:"nextOffset"`
	DataBase64 string `json:"dataBase64"`
	HasMore    bool   `json:"hasMore"`
}
type Report struct {
	Summary     Summary      `json:"summary"`
	Source      Capture      `json:"source"`
	Target      Capture      `json:"target"`
	Differences []Difference `json:"differences"`
	Issues      []Issue      `json:"issues"`
}
type span struct{ offset, size int64 }
type Result struct {
	Report      Report
	file        *os.File
	values      map[string]span
	dir, hash   string
	size, bytes int64
	ctx         context.Context
	mappings    Mappings
}

// Remap only typed references. Expression text and scalar values remain exact.
func (m Mappings) mapRef(r Ref) Ref {
	original := r
	for _, p := range m.Tables {
		if original.Schema == p.Source.Schema && ((original.Kind == "table" || original.Kind == "type" && original.RowType) && original.Name == p.Source.Name || original.Table == p.Source.Name) {
			r.Schema = p.Target.Schema
			if original.Kind == "table" || original.Kind == "type" && original.RowType {
				r.Name = p.Target.Name
			} else {
				r.Table = p.Target.Name
				var members []NamePair
				switch original.Kind {
				case "column":
					members = p.Columns
				case "constraint":
					members = p.Constraints
				case "index":
					members = p.Indexes
				}
				for _, n := range members {
					if original.Name == n.Source {
						r.Name = n.Target
						break
					}
				}
			}
			return r
		}
	}
	for _, p := range m.Types {
		if original.Kind == "type" && original.Schema == p.Source.Schema && original.Name == p.Source.Name {
			r.Schema = p.Target.Schema
			r.Name = p.Target.Name
			return r
		}
	}
	for _, p := range m.Schemas {
		if r.Schema == p.Source {
			r.Schema = p.Target
			break
		}
	}
	return r
}
func remap(v reflect.Value, m Mappings) {
	if !v.IsValid() {
		return
	}
	if v.Type() == reflect.TypeOf(Ref{}) {
		v.Set(reflect.ValueOf(m.mapRef(v.Interface().(Ref))))
		return
	}
	switch v.Kind() {
	case reflect.Pointer:
		if !v.IsNil() {
			remap(v.Elem(), m)
		}
	case reflect.Struct:
		for i := 0; i < v.NumField(); i++ {
			remap(v.Field(i), m)
		}
	case reflect.Slice:
		for i := 0; i < v.Len(); i++ {
			remap(v.Index(i), m)
		}
	}
}
func unknown(v reflect.Value) bool {
	if !v.IsValid() {
		return false
	}
	switch v.Kind() {
	case reflect.Pointer:
		return !v.IsNil() && unknown(v.Elem())
	case reflect.Struct:
		if f := v.FieldByName("State"); f.IsValid() && f.Kind() == reflect.String && f.String() != "known" && f.String() != "observed" && f.String() != "external" {
			return true
		}
		if f := v.FieldByName("Complete"); f.IsValid() && !f.Bool() {
			return true
		}
		for i := 0; i < v.NumField(); i++ {
			if unknown(v.Field(i)) {
				return true
			}
		}
	case reflect.Slice:
		for i := 0; i < v.Len(); i++ {
			if unknown(v.Index(i)) {
				return true
			}
		}
	}
	return false
}
func nodeRef(v reflect.Value) *Ref {
	if v.IsValid() && v.Kind() == reflect.Struct {
		if f := v.FieldByName("Ref"); f.IsValid() && f.Type() == reflect.TypeOf(Ref{}) {
			r := f.Interface().(Ref)
			return &r
		}
	}
	return nil
}
func refKey(r Ref) string { b, _ := json.Marshal(r); return string(b) }
func (r *Result) preview(v reflect.Value) (*Preview, error) {
	if !v.IsValid() {
		return nil, nil
	}
	b, e := json.Marshal(v.Interface())
	if e != nil {
		return nil, e
	}
	if r.bytes+int64(len(b)) > 192<<20 {
		return nil, ErrLimit
	}
	key := fmt.Sprintf("v%d", len(r.values))
	offset, e := r.file.Seek(0, io.SeekEnd)
	if e != nil {
		return nil, e
	}
	if _, e = r.file.Write(b); e != nil {
		return nil, e
	}
	r.values[key] = span{offset, int64(len(b))}
	r.bytes += int64(len(b))
	n := min(256, len(b))
	for n > 0 && !utf8.Valid(b[:n]) {
		n--
	}
	return &Preview{string(b[:n]), int64(len(b)), n < len(b), key}, nil
}
func (r *Result) diff(a, b reflect.Value, ar, br *Ref, path, kind string) error {
	if e := r.ctx.Err(); e != nil {
		return e
	}
	ap, e := r.preview(a)
	if e != nil {
		return e
	}
	bp, e := r.preview(b)
	if e != nil {
		return e
	}
	planning := "structured"
	reasons := []string{}
	if kind == "indeterminate" || strings.Contains(path, "expression") || strings.Contains(path, "check") || strings.Contains(path, "predicate") {
		planning = "manual"
		reasons = append(reasons, "metadataOrExpressionReview")
	}
	r.Report.Differences = append(r.Report.Differences, Difference{int64(len(r.Report.Differences)), ar, br, path, kind, ap, bp, planning, reasons})
	return nil
}
func (r *Result) compare(a, b reflect.Value, ar, br *Ref, path string) error {
	if e := r.ctx.Err(); e != nil {
		return e
	}
	if !a.IsValid() || !b.IsValid() {
		kind := "sourceOnly"
		if !a.IsValid() {
			kind = "targetOnly"
		}
		return r.diff(a, b, ar, br, path, kind)
	}
	if a.Type() != b.Type() {
		return ErrInvalid
	}
	if ref := nodeRef(a); ref != nil {
		ar = ref
		br = nodeRef(b)
	}
	if a.Type() == reflect.TypeOf(Ref{}) {
		if !reflect.DeepEqual(r.mappings.mapRef(a.Interface().(Ref)), b.Interface()) {
			return r.diff(a, b, ar, br, path, "changed")
		}
		return nil
	}
	if a.Kind() == reflect.Struct {
		if complete := a.FieldByName("Complete"); complete.IsValid() && complete.Kind() == reflect.Bool && (!complete.Bool() || !b.FieldByName("Complete").Bool()) {
			if e := r.diff(complete, b.FieldByName("Complete"), ar, br, path+".observation", "indeterminate"); e != nil {
				return e
			}
			left, right := a.FieldByName("Items"), b.FieldByName("Items")
			if left.Type().Elem().Kind() == reflect.Struct && left.Type().Elem().Field(0).Name == "Ref" {
				for _, pair := range r.nodePairs(left, right) {
					if !pair[0].IsValid() || !pair[1].IsValid() {
						if e := r.diff(pair[0], pair[1], nodeRef(pair[0]), nodeRef(pair[1]), path+".items", "indeterminate"); e != nil {
							return e
						}
					} else if e := r.compare(pair[0], pair[1], nodeRef(pair[0]), nodeRef(pair[1]), path+".items"); e != nil {
						return e
					}
				}
				return nil
			}
		}
		state := a.FieldByName("State")
		if state.IsValid() && strings.HasPrefix(a.Type().Name(), "Fact[") {
			if unknown(a) || unknown(b) {
				return r.diff(a, b, ar, br, path, "indeterminate")
			}
			mapped := reflect.New(a.Type())
			encoded, _ := json.Marshal(a.Interface())
			_ = json.Unmarshal(encoded, mapped.Interface())
			remap(mapped.Elem(), r.mappings)
			if !reflect.DeepEqual(mapped.Elem().Interface(), b.Interface()) {
				return r.diff(a, b, ar, br, path, "changed")
			}
			return nil
		}
		for i := 0; i < a.NumField(); i++ {
			name := strings.Split(a.Type().Field(i).Tag.Get("json"), ",")[0]
			if name == "ref" {
				continue
			}
			next := name
			if path != "" {
				next = path + "." + name
			}
			if e := r.compare(a.Field(i), b.Field(i), ar, br, next); e != nil {
				return e
			}
		}
		return nil
	}
	if a.Kind() == reflect.Slice && a.Type().Elem().Kind() == reflect.Struct && a.Type().Elem().Field(0).Name == "Ref" {
		for _, pair := range r.nodePairs(a, b) {
			if e := r.compare(pair[0], pair[1], nodeRef(pair[0]), nodeRef(pair[1]), path); e != nil {
				return e
			}
		}
		return nil
	}
	mapped := reflect.New(a.Type())
	encoded, _ := json.Marshal(a.Interface())
	_ = json.Unmarshal(encoded, mapped.Interface())
	remap(mapped.Elem(), r.mappings)
	right := b.Interface()
	if a.Type() == reflect.TypeOf([]Dependency{}) {
		leftEdges := mapped.Elem().Interface().([]Dependency)
		rightEdges := append([]Dependency{}, b.Interface().([]Dependency)...)
		key := func(d Dependency) string { return refKey(d.From) + refKey(d.To) + d.Kind + d.State }
		sort.Slice(leftEdges, func(i, j int) bool { return key(leftEdges[i]) < key(leftEdges[j]) })
		sort.Slice(rightEdges, func(i, j int) bool { return key(rightEdges[i]) < key(rightEdges[j]) })
		right = rightEdges
	}
	if !reflect.DeepEqual(mapped.Elem().Interface(), right) {
		return r.diff(a, b, ar, br, path, "changed")
	}
	return nil
}
func (m Mappings) explicit(r Ref) bool {
	for _, p := range m.Tables {
		if r.Schema != p.Source.Schema {
			continue
		}
		if r.Kind == "table" && r.Name == p.Source.Name {
			return true
		}
		if r.Table == p.Source.Name {
			var pairs []NamePair
			switch r.Kind {
			case "column":
				pairs = p.Columns
			case "constraint":
				pairs = p.Constraints
			case "index":
				pairs = p.Indexes
			}
			for _, n := range pairs {
				if r.Name == n.Source {
					return true
				}
			}
		}
	}
	for _, p := range m.Types {
		if r.Kind == "type" && r.Schema == p.Source.Schema && r.Name == p.Source.Name {
			return true
		}
	}
	return false
}
func (r *Result) nodePairs(a, b reflect.Value) [][2]reflect.Value {
	indices := make([]int, a.Len())
	for i := range indices {
		indices[i] = i
	}
	sort.SliceStable(indices, func(i, j int) bool {
		return r.mappings.explicit(*nodeRef(a.Index(indices[i]))) && !r.mappings.explicit(*nodeRef(a.Index(indices[j])))
	})
	targets := map[string]int{}
	for i := 0; i < b.Len(); i++ {
		targets[refKey(*nodeRef(b.Index(i)))] = i
	}
	used := map[int]bool{}
	pairs := [][2]reflect.Value{}
	for _, i := range indices {
		x := a.Index(i)
		mapped := r.mappings.mapRef(*nodeRef(x))
		j, ok := targets[refKey(mapped)]
		var y reflect.Value
		if ok && !used[j] {
			y = b.Index(j)
			used[j] = true
		}
		pairs = append(pairs, [2]reflect.Value{x, y})
	}
	for i := 0; i < b.Len(); i++ {
		if !used[i] {
			pairs = append(pairs, [2]reflect.Value{{}, b.Index(i)})
		}
	}
	return pairs
}
func Build(ctx context.Context, dir string, source, target Capture, m Mappings) (*Result, error) {
	if !m.Valid() || source.Context.Engine != target.Context.Engine {
		return nil, ErrInvalid
	}
	f, e := os.OpenFile(filepath.Join(dir, "values"), os.O_CREATE|os.O_EXCL|os.O_RDWR, 0600)
	if e != nil {
		return nil, e
	}
	r := &Result{file: f, dir: dir, values: map[string]span{}, ctx: ctx, mappings: m, Report: Report{Source: source, Target: target, Differences: []Difference{}, Issues: []Issue{}}}
	ok := false
	defer func() {
		if !ok {
			r.Close()
		}
	}()
	s := Summary{FormatVersion: 1, Engine: source.Context.Engine, Source: source.Context, Target: target.Context, Mappings: m, Scope: Scope{"mappedTableStructure", []string{"views", "routines", "triggers", "privileges", "statistics", "physicalContents", "sequenceCounters", "autoIncrementCounters"}}, Complete: true}
	if s.Engine == "cassandra" {
		// Cassandra's adapter also captures materialized-view structure.
		s.Scope.ExcludedObjectKinds = []string{"routines", "triggers", "privileges", "statistics", "physicalContents"}
	}
	for i, c := range []Capture{source, target} {
		side := "source"
		if i == 1 {
			side = "target"
		}
		if c.Context.Visibility != "complete" || unknown(reflect.ValueOf(c)) {
			s.Complete = false
		}
		for _, issue := range c.Issues {
			issue.Index = int64(len(r.Report.Issues))
			issue.Side = side
			r.Report.Issues = append(r.Report.Issues, issue)
			if issue.BlocksEquality {
				s.Complete = false
			}
		}
		for _, inv := range c.Inventories {
			if inv.Existence == "unknown" || !inv.Tables.Complete || !inv.Types.Complete {
				s.Complete = false
			}
		}
	}
	inventoryComplete := func(c Capture, schema string) bool {
		for _, i := range c.Inventories {
			if i.Schema == schema {
				return i.Existence != "unknown" && i.Tables.Complete && i.Types.Complete && i.Tables.State == "known" && i.Types.State == "known"
			}
		}
		return false
	}
	for _, group := range []struct {
		a, b any
		path string
	}{{source.Tables, target.Tables, "tables"}, {source.Types, target.Types, "types"}, {source.Sequences, target.Sequences, "sequences"}} {
		for _, pair := range r.nodePairs(reflect.ValueOf(group.a), reflect.ValueOf(group.b)) {
			a, b := pair[0], pair[1]
			ar, br := nodeRef(a), nodeRef(b)
			before := len(r.Report.Differences)
			if e = r.compare(a, b, ar, br, group.path); e != nil {
				return nil, e
			}
			uncertain := unknown(a) || unknown(b)
			missingUnknown := false
			if ar != nil && br == nil {
				mapped := m.mapRef(*ar)
				if !inventoryComplete(target, mapped.Schema) {
					missingUnknown = true
					uncertain = true
				}
			}
			if br != nil && ar == nil {
				schema := br.Schema
				for _, p := range m.Schemas {
					if schema == p.Target {
						schema = p.Source
						break
					}
				}
				if !inventoryComplete(source, schema) {
					missingUnknown = true
					uncertain = true
				}
			}
			for i := before; i < len(r.Report.Differences); i++ {
				d := &r.Report.Differences[i]
				if missingUnknown || d.Kind == "indeterminate" {
					uncertain = true
					d.Kind = "indeterminate"
					d.Planning = "manual"
				}
			}
			switch {
			case uncertain:
				s.IndeterminateObjects++
				s.Complete = false
			case !a.IsValid():
				s.TargetOnlyObjects++
			case !b.IsValid():
				s.SourceOnlyObjects++
			case len(r.Report.Differences) > before:
				s.ChangedObjects++
			default:
				s.EqualObjects++
			}
		}
	}
	for _, pair := range m.Schemas {
		var a, b Inventory
		for _, i := range source.Inventories {
			if i.Schema == pair.Source {
				a = i
			}
		}
		for _, i := range target.Inventories {
			if i.Schema == pair.Target {
				b = i
			}
		}
		if a.Existence == "" || b.Existence == "" || a.Existence == "unknown" || b.Existence == "unknown" {
			s.Complete = false
		}
		if a.Existence != b.Existence {
			ar := Ref{Kind: "schema", Name: pair.Source}
			br := Ref{Kind: "schema", Name: pair.Target}
			if e = r.diff(reflect.ValueOf(a.Existence), reflect.ValueOf(b.Existence), &ar, &br, "existence", "changed"); e != nil {
				return nil, e
			}
		}
	}
	if !reflect.DeepEqual(source.Context.EngineContext, target.Context.EngineContext) {
		ref := Ref{Kind: "capture", Name: "engineContext"}
		if e = r.diff(reflect.ValueOf(source.Context.EngineContext), reflect.ValueOf(target.Context.EngineContext), &ref, &ref, "engineContext", "indeterminate"); e != nil {
			return nil, e
		}
		s.Complete = false
	}

	if !s.Complete && len(r.Report.Issues) == 0 {
		r.Report.Issues = append(r.Report.Issues, Issue{Index: 0, Side: "both", Property: "capture", Code: "incompleteMetadata", Message: "Metadata visibility or properties are incomplete; equality cannot be established.", BlocksEquality: true, Planning: "manual"})
	}
	s.DifferenceCount = int64(len(r.Report.Differences))
	s.IssueCount = int64(len(r.Report.Issues))
	s.FullEquality = s.Complete && s.DifferenceCount == 0
	// Digest excludes capture clocks. Canonical JSON retains exact number strings.
	digestSource, digestTarget := source, target
	digestSource.Context.StartedAt = ""
	digestSource.Context.FinishedAt = ""
	digestTarget.Context.StartedAt = ""
	digestTarget.Context.FinishedAt = ""
	h := sha256.New()
	_ = json.NewEncoder(h).Encode(struct {
		Version        int
		Source, Target Capture
		Mappings       Mappings
	}{1, digestSource, digestTarget, m})
	s.ModelDigest = hex.EncodeToString(h.Sum(nil))
	r.Report.Summary = s
	output, e := os.OpenFile(filepath.Join(dir, "report.json"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if e != nil {
		return nil, e
	}
	hash := sha256.New()
	writer := &quotaWriter{w: io.MultiWriter(output, hash), remaining: (192 << 20) - r.bytes}
	e = json.NewEncoder(writer).Encode(r.Report)
	closeErr := output.Close()
	if e != nil {
		return nil, e
	}
	if closeErr != nil {
		return nil, closeErr
	}
	r.hash = hex.EncodeToString(hash.Sum(nil))
	r.size = writer.written
	ok = true
	return r, nil
}

type quotaWriter struct {
	w                  io.Writer
	remaining, written int64
}

func (w *quotaWriter) Write(b []byte) (int, error) {
	if int64(len(b)) > w.remaining {
		return 0, ErrLimit
	}
	n, e := w.w.Write(b)
	w.remaining -= int64(n)
	w.written += int64(n)
	return n, e
}
func (r *Result) Close() error { return r.file.Close() }
func (r *Result) Page(collection string, offset int64, limit, maxBytes int) (Page, error) {
	p := Page{Collection: collection, Offset: offset, NextOffset: offset, Items: []json.RawMessage{}}
	var values []json.RawMessage
	if collection == "differences" {
		for _, v := range r.Report.Differences {
			b, _ := json.Marshal(v)
			values = append(values, b)
		}
	} else if collection == "issues" {
		for _, v := range r.Report.Issues {
			b, _ := json.Marshal(v)
			values = append(values, b)
		}
	} else {
		return p, ErrInvalid
	}
	if offset < 0 || offset > int64(len(values)) {
		return p, ErrInvalid
	}
	for i := offset; i < int64(len(values)) && len(p.Items) < limit; i++ {
		if e := r.ctx.Err(); e != nil {
			return p, e
		}
		p.Items = append(p.Items, values[i])
		p.NextOffset = i + 1
		p.HasMore = p.NextOffset < int64(len(values))
		b, _ := json.Marshal(p)
		if len(b) > maxBytes {
			p.Items = p.Items[:len(p.Items)-1]
			p.NextOffset = i
			p.HasMore = true
			break
		}
	}
	if p.HasMore && len(p.Items) == 0 {
		return p, ErrLimit
	}
	return p, nil
}
func (r *Result) Chunk(ref string, offset int64, maxBytes int, export bool) (Chunk, error) {
	c := Chunk{ValueRef: ref, Offset: offset}
	f := r.file
	var start int64
	if export {
		var e error
		f, e = os.Open(filepath.Join(r.dir, "report.json"))
		if e != nil {
			return c, e
		}
		defer f.Close()
		c.ValueRef = ""
		c.SHA256 = r.hash
		c.TotalBytes = r.size
	} else {
		s, ok := r.values[ref]
		if !ok {
			return c, ErrInvalid
		}
		start = s.offset
		c.TotalBytes = s.size
	}
	if offset < 0 || offset > c.TotalBytes {
		return c, ErrInvalid
	}
	if e := r.ctx.Err(); e != nil {
		return c, e
	}
	b := make([]byte, min(int64(maxBytes), c.TotalBytes-offset))
	if _, e := f.ReadAt(b, start+offset); e != nil && e != io.EOF {
		return c, e
	}
	c.DataBase64 = base64.StdEncoding.EncodeToString(b)
	c.NextOffset = offset + int64(len(b))
	c.HasMore = c.NextOffset < c.TotalBytes
	return c, nil
}
