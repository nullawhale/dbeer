// Package tablecapture defines bounded, immutable table-data inputs for R17.
package tablecapture

import (
	"context"
	"crypto/sha256"
	sc "dbeer/helper/internal/schemacompare"
	"encoding/hex"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"unicode/utf8"
)

const QuotaBytes int64 = 256 << 20
const MaxColumns = 4096
const MaxRowBytes = 16 << 20

var ErrInvalid = errors.New("invalid table capture")
var ErrUnsupported = errors.New("unsupported table capture")
var ErrChanged = errors.New("table metadata changed")
var ErrQuota = errors.New("table capture quota")

type Table struct {
	Schema string `json:"schema"`
	Name   string `json:"name"`
}

func (t Table) Valid() bool { return Name(t.Schema) && Name(t.Name) }
func Name(v string) bool {
	return len(v) > 0 && len(v) <= 256 && utf8.ValidString(v) && !strings.ContainsRune(v, 0)
}

type Column struct {
	Index      int             `json:"index"`
	Name       string          `json:"name"`
	NativeType string          `json:"nativeType"`
	TypeLabel  string          `json:"typeLabel"`
	Encoding   string          `json:"encoding,omitempty"`
	PrimaryKey int             `json:"primaryKey"`
	Numeric    bool            `json:"numeric"`
	Generated  bool            `json:"generated"`
	Identity   bool            `json:"identity"`
	Nullable   bool            `json:"nullable"`
	Definition json.RawMessage `json:"definition"`
}
type Descriptor struct {
	FormatVersion int             `json:"formatVersion"`
	Engine        string          `json:"engine"`
	Table         Table           `json:"table"`
	Columns       []Column        `json:"columns"`
	Definition    json.RawMessage `json:"definition"`
	Digest        string          `json:"digest"`
}

func (d *Descriptor) Seal() error {
	if !d.Table.Valid() || len(d.Columns) == 0 || len(d.Columns) > MaxColumns {
		return ErrUnsupported
	}
	seen := map[string]bool{}
	for i, c := range d.Columns {
		if c.Index != i || !Name(c.Name) || seen[c.Name] || len(c.NativeType) > 65536 || !utf8.ValidString(c.NativeType) {
			return ErrUnsupported
		}
		seen[c.Name] = true
	}
	d.FormatVersion = 1
	d.Digest = ""
	b, e := json.Marshal(d)
	if e != nil || len(b) > 1<<20 {
		return ErrUnsupported
	}
	h := sha256.Sum256(b)
	d.Digest = hex.EncodeToString(h[:])
	return nil
}

type Mapping struct {
	Source string `json:"source"`
	Target string `json:"target"`
	Key    bool   `json:"key"`
}
type Filter struct {
	Column   string  `json:"column"`
	Operator string  `json:"operator"`
	Value    *string `json:"value,omitempty"`
}

func (f Filter) Valid() bool {
	if !Name(f.Column) {
		return false
	}
	switch f.Operator {
	case "isNull", "isNotNull":
		return f.Value == nil
	case "eq", "ne", "lt", "lte", "gt", "gte", "contains":
		return f.Value != nil && len(*f.Value) <= 4096 && utf8.ValidString(*f.Value) && !strings.ContainsRune(*f.Value, 0)
	}
	return false
}

type Spec struct {
	Table            Table
	DescriptorDigest string
	Columns          []string
	Filters          []Filter
	Keys             []string
	ReadLimit        int
}
type Outcome struct {
	StartedAt        string   `json:"startedAt"`
	FinishedAt       string   `json:"finishedAt"`
	Consistency      string   `json:"consistency"`
	Rendering        string   `json:"rendering"`
	StoredRows       int64    `json:"storedRows"`
	ObservedAtLeast  int64    `json:"observedAtLeast"`
	ReadLimit        int      `json:"readLimit"`
	PartialReasons   []string `json:"partialReasons"`
	FullOriginals    bool     `json:"fullOriginals"`
	DescriptorDigest string   `json:"descriptorDigest"`
	CaptureDigest    string   `json:"captureDigest"`
	Table            Table    `json:"table"`
	Engine           string   `json:"engine"`
	ExcludedColumns  int      `json:"excludedColumns"`
}
type Sink interface{ Row([]*string) error }
type Reader interface {
	DescribeTable(context.Context, Table) (Descriptor, error)
	CaptureTable(context.Context, Spec, Sink) (Descriptor, Outcome, error)
}

// Validate resolves names against freshly loaded metadata before generated SQL.
func Validate(d Descriptor, s Spec) error {
	if s.Table != d.Table || s.DescriptorDigest != d.Digest {
		return ErrChanged
	}
	if s.ReadLimit < 1 || s.ReadLimit > 100000 || len(s.Columns) == 0 || len(s.Columns) > MaxColumns || len(s.Keys) == 0 || len(s.Keys) > 32 || len(s.Filters) > 32 {
		return ErrInvalid
	}
	names := map[string]Column{}
	for _, c := range d.Columns {
		names[c.Name] = c
	}
	seen := map[string]bool{}
	for _, name := range s.Columns {
		if _, ok := names[name]; !ok || seen[name] {
			return ErrInvalid
		}
		seen[name] = true
	}
	for _, key := range s.Keys {
		if !seen[key] {
			return ErrInvalid
		}
	}
	for _, f := range s.Filters {
		if _, ok := names[f.Column]; !ok || !f.Valid() {
			return ErrInvalid
		}
	}
	return nil
}

// Structural type identity includes modifiers and referenced definitions, never OIDs.
func PostgresType(u sc.TypeUse, definitions []sc.TypeDefinition) (string, error) {
	if u.Modifiers.State != "known" {
		return "", ErrUnsupported
	}
	refs := map[sc.Ref]bool{}
	byRef := map[sc.Ref]sc.TypeDefinition{}
	for _, d := range definitions {
		byRef[d.Ref] = d
	}
	var visit func(sc.TypeUse) error
	visit = func(t sc.TypeUse) error {
		if t.Modifiers.State != "known" {
			return ErrUnsupported
		}
		if refs[t.Ref] && t.Element == nil {
			return nil
		}
		refs[t.Ref] = true
		if d, ok := byRef[t.Ref]; ok {
			if d.Kind.State != "known" {
				return ErrUnsupported
			}
			if d.Base.Value != nil {
				if e := visit(*d.Base.Value); e != nil {
					return e
				}
			}
			for _, attribute := range d.Attributes.Items {
				if attribute.Type.Value == nil {
					return ErrUnsupported
				}
				if e := visit(*attribute.Type.Value); e != nil {
					return e
				}
			}
		}
		if t.Element != nil {
			return visit(*t.Element)
		}
		return nil
	}
	if e := visit(u); e != nil {
		return "", e
	}
	selected := []sc.TypeDefinition{}
	for _, d := range definitions {
		if refs[d.Ref] {
			if d.Kind.State != "known" {
				return "", ErrUnsupported
			}
			selected = append(selected, d)
		}
	}
	sort.Slice(selected, func(i, j int) bool {
		if selected[i].Ref.Schema != selected[j].Ref.Schema {
			return selected[i].Ref.Schema < selected[j].Ref.Schema
		}
		return selected[i].Ref.Name < selected[j].Ref.Name
	})
	b, e := json.Marshal(struct {
		Type        sc.TypeUse          `json:"type"`
		Definitions []sc.TypeDefinition `json:"definitions"`
	}{u, selected})
	return string(b), e
}
