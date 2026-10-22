// Package schemacompare compares portable catalog facts, never displayed DDL.
package schemacompare

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"unicode/utf8"
)

var ErrInvalid = errors.New("invalid schema comparison")
var ErrLimit = errors.New("schema comparison limit")

type Fact[T any] struct {
	State string `json:"state"`
	Value *T     `json:"value,omitempty"`
	Code  string `json:"code,omitempty"`
}

func Known[T any](v T) Fact[T]           { return Fact[T]{State: "known", Value: &v} }
func Absent[T any]() Fact[T]             { return Fact[T]{State: "known"} }
func Unknown[T any](code string) Fact[T] { return Fact[T]{State: "unsupported", Code: code} }
func (f Fact[T]) MarshalJSON() ([]byte, error) {
	if f.State == "known" {
		return json.Marshal(struct {
			State string `json:"state"`
			Value *T     `json:"value"`
		}{f.State, f.Value})
	}
	return json.Marshal(struct {
		State string `json:"state"`
		Code  string `json:"code"`
	}{f.State, f.Code})
}

type Collection[T any] struct {
	Items    []T    `json:"items"`
	Complete bool   `json:"complete"`
	State    string `json:"state"`
	Code     string `json:"code,omitempty"`
}

func Complete[T any](v []T) Collection[T] {
	if v == nil {
		v = []T{}
	}
	return Collection[T]{Items: v, Complete: true, State: "known"}
}

type QualifiedName struct {
	Schema string `json:"schema"`
	Name   string `json:"name"`
}
type Ref struct {
	Kind   string `json:"kind"`
	Schema string `json:"schema"`
	Name   string `json:"name"`
	Table  string `json:"table,omitempty"`
}
type NamePair struct {
	Source string `json:"source"`
	Target string `json:"target"`
}
type ObjectPair struct {
	Source QualifiedName `json:"source"`
	Target QualifiedName `json:"target"`
}
type TablePair struct {
	Source      QualifiedName `json:"source"`
	Target      QualifiedName `json:"target"`
	Columns     []NamePair    `json:"columns"`
	Constraints []NamePair    `json:"constraints"`
	Indexes     []NamePair    `json:"indexes"`
}
type Mappings struct {
	Schemas []NamePair   `json:"schemas"`
	Tables  []TablePair  `json:"tables"`
	Types   []ObjectPair `json:"types"`
}
type Limits struct {
	Nodes   int
	Members int
	Bytes   int
	Scalar  int
}

func DefaultLimits() Limits { return Limits{10000, 100000, 64 << 20, 1 << 20} }

type CaptureSpec struct {
	Schemas []string
	Limits  Limits
}
type CaptureContext struct {
	Engine        string         `json:"engine"`
	Version       string         `json:"version"`
	Database      string         `json:"database"`
	StartedAt     string         `json:"startedAt"`
	FinishedAt    string         `json:"finishedAt"`
	Consistency   string         `json:"consistency"`
	Visibility    string         `json:"visibility"`
	EngineContext Fact[[]Option] `json:"engineContext"`
}
type Inventory struct {
	Schema    string          `json:"schema"`
	Existence string          `json:"existence"`
	Tables    Collection[Ref] `json:"tables"`
	Types     Collection[Ref] `json:"types"`
}
type Option struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}
type TypeModifiers struct {
	Length            *int64 `json:"length"`
	Precision         *int64 `json:"precision"`
	Scale             *int64 `json:"scale"`
	DatetimePrecision *int64 `json:"datetimePrecision"`
	Interval          *int64 `json:"interval"`
	ArrayDimensions   int    `json:"arrayDimensions"`
	Unsigned          bool   `json:"unsigned"`
	Zerofill          bool   `json:"zerofill"`
}
type TypeUse struct {
	Ref       Ref                 `json:"ref"`
	Kind      string              `json:"kind"`
	Element   *TypeUse            `json:"element,omitempty"`
	Modifiers Fact[TypeModifiers] `json:"modifiers"`
	Labels    Collection[string]  `json:"labels"`
}
type Expression struct {
	Text         string          `json:"text"`
	Dependencies Collection[Ref] `json:"dependencies"`
}
type Default struct {
	Kind       string      `json:"kind"`
	Type       *TypeUse    `json:"type,omitempty"`
	Encoding   string      `json:"encoding,omitempty"`
	Value      *string     `json:"value,omitempty"`
	Expression *Expression `json:"expression,omitempty"`
	Sequence   *Ref        `json:"sequence,omitempty"`
}
type Generated struct {
	Kind       string      `json:"kind"`
	Expression *Expression `json:"expression,omitempty"`
}
type Identity struct {
	Kind     string `json:"kind"`
	Sequence *Ref   `json:"sequence,omitempty"`
}
type Column struct {
	Ref       Ref              `json:"ref"`
	Ordinal   Fact[int]        `json:"ordinal"`
	Type      Fact[TypeUse]    `json:"type"`
	Nullable  Fact[bool]       `json:"nullable"`
	Default   Fact[Default]    `json:"default"`
	Generated Fact[Generated]  `json:"generated"`
	Identity  Fact[Identity]   `json:"identity"`
	Charset   Fact[string]     `json:"charset"`
	Collation Fact[Ref]        `json:"collation"`
	Visible   Fact[bool]       `json:"visible"`
	Comment   Fact[string]     `json:"comment"`
	OnUpdate  Fact[Expression] `json:"onUpdate"`
}
type ColumnPair struct {
	Source Ref `json:"source"`
	Target Ref `json:"target"`
}
type Constraint struct {
	Ref               Ref                    `json:"ref"`
	Kind              Fact[string]           `json:"kind"`
	Columns           Collection[Ref]        `json:"columns"`
	BackingIndex      Fact[Ref]              `json:"backingIndex"`
	ForeignKeys       Collection[ColumnPair] `json:"foreignKeys"`
	Target            Fact[Ref]              `json:"target"`
	Update            Fact[string]           `json:"update"`
	Delete            Fact[string]           `json:"delete"`
	Match             Fact[string]           `json:"match"`
	SetColumns        Collection[Ref]        `json:"setColumns"`
	Check             Fact[Expression]       `json:"check"`
	Deferrable        Fact[bool]             `json:"deferrable"`
	InitiallyDeferred Fact[bool]             `json:"initiallyDeferred"`
	Validated         Fact[bool]             `json:"validated"`
	Enforced          Fact[bool]             `json:"enforced"`
	NullsDistinct     Fact[bool]             `json:"nullsDistinct"`
	Local             Fact[bool]             `json:"local"`
	Inherited         Fact[bool]             `json:"inherited"`
	NoInherit         Fact[bool]             `json:"noInherit"`
}

func NewConstraint(ref Ref, kind string) Constraint {
	return Constraint{Ref: ref, Kind: Known(kind), Columns: Complete[Ref](nil), BackingIndex: Absent[Ref](), ForeignKeys: Complete[ColumnPair](nil), Target: Absent[Ref](), Update: Absent[string](), Delete: Absent[string](), Match: Absent[string](), SetColumns: Complete[Ref](nil), Check: Absent[Expression](), Deferrable: Known(false), InitiallyDeferred: Known(false), Validated: Known(true), Enforced: Known(true), NullsDistinct: Absent[bool](), Local: Known(true), Inherited: Known(false), NoInherit: Known(false)}
}

type IndexKey struct {
	Column       Fact[Ref]          `json:"column"`
	Expression   Fact[Expression]   `json:"expression"`
	Opclass      Fact[Ref]          `json:"opclass"`
	Collation    Fact[Ref]          `json:"collation"`
	Descending   Fact[bool]         `json:"descending"`
	NullsFirst   Fact[bool]         `json:"nullsFirst"`
	PrefixLength Fact[int64]        `json:"prefixLength"`
	Options      Collection[Option] `json:"options"`
}
type Index struct {
	Ref           Ref                  `json:"ref"`
	Method        Fact[string]         `json:"method"`
	Unique        Fact[bool]           `json:"unique"`
	NullsDistinct Fact[bool]           `json:"nullsDistinct"`
	Keys          Collection[IndexKey] `json:"keys"`
	Includes      Collection[Ref]      `json:"includes"`
	Predicate     Fact[Expression]     `json:"predicate"`
	Options       Collection[Option]   `json:"options"`
	Visible       Fact[bool]           `json:"visible"`
	Valid         Fact[bool]           `json:"valid"`
	Ready         Fact[bool]           `json:"ready"`
	Constraint    Fact[Ref]            `json:"constraint"`
}
type Dependency struct {
	From  Ref    `json:"from"`
	To    Ref    `json:"to"`
	Kind  string `json:"kind"`
	State string `json:"state"`
}
type Table struct {
	Ref          Ref                    `json:"ref"`
	Kind         Fact[string]           `json:"kind"`
	Storage      Fact[string]           `json:"storage"`
	Charset      Fact[string]           `json:"charset"`
	Collation    Fact[Ref]              `json:"collation"`
	Options      Collection[Option]     `json:"options"`
	Columns      Collection[Column]     `json:"columns"`
	Constraints  Collection[Constraint] `json:"constraints"`
	Indexes      Collection[Index]      `json:"indexes"`
	Dependencies Collection[Dependency] `json:"dependencies"`
}
type TypeDefinition struct {
	Ref        Ref                    `json:"ref"`
	Kind       Fact[string]           `json:"kind"`
	Labels     Collection[string]     `json:"labels"`
	Base       Fact[TypeUse]          `json:"base"`
	Default    Fact[Default]          `json:"default"`
	Nullable   Fact[bool]             `json:"nullable"`
	Checks     Collection[Constraint] `json:"checks"`
	Attributes Collection[Column]     `json:"attributes"`
}
type Sequence struct {
	Ref       Ref           `json:"ref"`
	Type      Fact[TypeUse] `json:"type"`
	Start     Fact[string]  `json:"start"`
	Increment Fact[string]  `json:"increment"`
	Min       Fact[string]  `json:"min"`
	Max       Fact[string]  `json:"max"`
	Cache     Fact[string]  `json:"cache"`
	Cycle     Fact[bool]    `json:"cycle"`
	Owner     Fact[Ref]     `json:"owner"`
}
type Issue struct {
	Index          int64  `json:"index"`
	Side           string `json:"side"`
	Ref            *Ref   `json:"ref,omitempty"`
	Property       string `json:"property"`
	Code           string `json:"code"`
	Message        string `json:"message"`
	BlocksEquality bool   `json:"blocksEquality"`
	Planning       string `json:"planning"`
}
type Capture struct {
	Context     CaptureContext   `json:"context"`
	Inventories []Inventory      `json:"inventories"`
	Tables      []Table          `json:"tables"`
	Types       []TypeDefinition `json:"types"`
	Sequences   []Sequence       `json:"sequences"`
	Issues      []Issue          `json:"issues"`
}
type Sink interface {
	Context(CaptureContext) error
	Inventory(Inventory) error
	Table(Table) error
	Type(TypeDefinition) error
	Sequence(Sequence) error
	Issue(Issue) error
}
type Collector struct {
	Capture               Capture
	ctx                   context.Context
	limits                Limits
	nodes, members, bytes int
}

func NewCollector(ctx context.Context, l Limits) *Collector {
	return &Collector{ctx: ctx, limits: l, Capture: Capture{Inventories: []Inventory{}, Tables: []Table{}, Types: []TypeDefinition{}, Sequences: []Sequence{}, Issues: []Issue{}}}
}
func (c *Collector) accept(v any, n, m int) error {
	if e := c.ctx.Err(); e != nil {
		return e
	}
	// Validate nested scalar/member bounds before retaining an assembled node.
	var inspect func(reflect.Value) error
	memberCount := 0
	inspect = func(value reflect.Value) error {
		switch value.Kind() {
		case reflect.Pointer:
			if !value.IsNil() {
				return inspect(value.Elem())
			}
		case reflect.String:
			if value.Len() > c.limits.Scalar {
				return ErrLimit
			}
		case reflect.Struct:
			for i := 0; i < value.NumField(); i++ {
				if e := inspect(value.Field(i)); e != nil {
					return e
				}
			}
		case reflect.Slice:
			memberCount += value.Len()
			if memberCount > c.limits.Members {
				return ErrLimit
			}
			for i := 0; i < value.Len(); i++ {
				if e := inspect(value.Index(i)); e != nil {
					return e
				}
			}
		}
		return nil
	}
	if e := inspect(reflect.ValueOf(v)); e != nil {
		return e
	}
	m = max(m, memberCount)
	b, e := json.Marshal(v)
	if e != nil {
		return ErrInvalid
	}
	c.nodes += n
	c.members += m
	c.bytes += len(b)
	if c.nodes > c.limits.Nodes || c.members > c.limits.Members || c.bytes > c.limits.Bytes {
		return ErrLimit
	}
	return nil
}
func (c *Collector) Context(v CaptureContext) error {
	if e := c.accept(v, 0, 0); e != nil {
		return e
	}
	c.Capture.Context = v
	return nil
}
func (c *Collector) Inventory(v Inventory) error {
	if e := c.accept(v, 0, 0); e != nil {
		return e
	}
	c.Capture.Inventories = append(c.Capture.Inventories, v)
	return nil
}
func (c *Collector) Table(v Table) error {
	linkDependencies(&v)
	if e := c.accept(v, 1, len(v.Columns.Items)+len(v.Constraints.Items)+len(v.Indexes.Items)); e != nil {
		return e
	}
	c.Capture.Tables = append(c.Capture.Tables, v)
	return nil
}
func (c *Collector) Type(v TypeDefinition) error {
	if e := c.accept(v, 1, len(v.Attributes.Items)+len(v.Labels.Items)+len(v.Checks.Items)); e != nil {
		return e
	}
	c.Capture.Types = append(c.Capture.Types, v)
	return nil
}
func (c *Collector) Sequence(v Sequence) error {
	if e := c.accept(v, 1, 0); e != nil {
		return e
	}
	c.Capture.Sequences = append(c.Capture.Sequences, v)
	return nil
}
func (c *Collector) Issue(v Issue) error {
	if e := c.accept(v, 0, 0); e != nil {
		return e
	}
	c.Capture.Issues = append(c.Capture.Issues, v)
	return nil
}
func ValidName(s string) bool {
	return len(s) > 0 && len(s) <= 256 && utf8.ValidString(s) && !strings.ContainsRune(s, 0)
}
func (m Mappings) Valid() bool {
	encoded, err := json.Marshal(m)
	if err != nil || len(encoded) > 1<<20 {
		return false
	}
	if len(m.Schemas) == 0 || len(m.Schemas) > 32 || m.Tables == nil || m.Types == nil {
		return false
	}
	s, t := map[string]string{}, map[string]bool{}
	for _, p := range m.Schemas {
		if !ValidName(p.Source) || !ValidName(p.Target) || s[p.Source] != "" || t[p.Target] {
			return false
		}
		s[p.Source] = p.Target
		t[p.Target] = true
	}
	validPairs := func(pairs []ObjectPair) bool {
		a, b := map[QualifiedName]bool{}, map[QualifiedName]bool{}
		for _, p := range pairs {
			if !ValidName(p.Source.Name) || !ValidName(p.Target.Name) || s[p.Source.Schema] != p.Target.Schema || a[p.Source] || b[p.Target] {
				return false
			}
			a[p.Source] = true
			b[p.Target] = true
		}
		return true
	}
	var tables []ObjectPair
	for _, p := range m.Tables {
		tables = append(tables, ObjectPair{p.Source, p.Target})
		for _, members := range [][]NamePair{p.Columns, p.Constraints, p.Indexes} {
			if members == nil {
				return false
			}
			a, b := map[string]bool{}, map[string]bool{}
			for _, n := range members {
				if !ValidName(n.Source) || !ValidName(n.Target) || a[n.Source] || b[n.Target] {
					return false
				}
				a[n.Source] = true
				b[n.Target] = true
			}
		}
	}
	return len(m.Tables) <= 10000 && len(m.Types) <= 10000 && validPairs(tables) && validPairs(m.Types)
}
