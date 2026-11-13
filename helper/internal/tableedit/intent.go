package tableedit

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strings"
)

type ColumnChange struct {
	Drop            bool           `json:"drop,omitempty"`
	UsingExpression *string        `json:"usingExpression,omitempty"`
	Unsigned        *bool          `json:"unsigned,omitempty"`
	Charset         *string        `json:"charset,omitempty"`
	Collation       *TypeReference `json:"collation,omitempty"`
	Name            string         `json:"name"`
	RenameTo        *string        `json:"renameTo,omitempty"`
	Generated       *Generation    `json:"generated,omitempty"`
	Identity        *Identity      `json:"identity,omitempty"`
	Nullable        *bool          `json:"nullable,omitempty"`
	Default         *Default       `json:"default,omitempty"`
	Type            *DataType      `json:"type,omitempty"`
}
type Index struct {
	Definition *IndexDefinition `json:"definition,omitempty"`
	Name       string           `json:"name"`
	Columns    []string         `json:"columns"`
	Unique     bool             `json:"unique"`
	Supported  bool             `json:"supported"`
	Owner      string           `json:"owner,omitempty"`
}
type IndexEdit struct {
	Definition *IndexDefinition `json:"definition,omitempty"`
	Action     string           `json:"action"`
	Name       string           `json:"name"`
	Columns    []string         `json:"columns,omitempty"`
	Unique     bool             `json:"unique,omitempty"`
}
type Key struct {
	Kind             string   `json:"kind"`
	Name             string   `json:"name"`
	Columns          []string `json:"columns"`
	Reference        *Target  `json:"reference,omitempty"`
	ReferenceColumns []string `json:"referenceColumns,omitempty"`
	OnUpdate         string   `json:"onUpdate,omitempty"`
	OnDelete         string   `json:"onDelete,omitempty"`
	Supported        bool     `json:"supported"`
}
type KeyEdit struct {
	Action           string   `json:"action"`
	Kind             string   `json:"kind"`
	Name             string   `json:"name"`
	Columns          []string `json:"columns,omitempty"`
	Reference        *Target  `json:"reference,omitempty"`
	ReferenceColumns []string `json:"referenceColumns,omitempty"`
	OnUpdate         string   `json:"onUpdate,omitempty"`
	OnDelete         string   `json:"onDelete,omitempty"`
}
type Incoming struct {
	Schema  string
	Table   string
	Name    string
	Columns []string
}
type Facts struct {
	IndexAttributes            map[string]map[string]string
	IndexBuiltinFunctions      map[string][]string
	IndexDefaultCollations     map[string][]bool
	IndexCatalogGuards         map[string][]IndexGuard
	IndexDefaultOpclasses      map[string][]bool
	RawExpressions             map[string]string
	ExpressionKeywords         []string
	ServerVersion              int
	Sequences                  []sc.Sequence
	EngineContext              []sc.Option
	DefaultCollationProperties *sc.Collection[sc.Option]
	TypeStorage                map[string]string
	Table                      sc.Table
	Types                      []sc.TypeDefinition
	Incoming                   []Incoming
	Dependents                 map[string][]string
	Proof                      bool
}
type Prepared struct {
	Reconstruction   *Reconstruction
	DroppedTarget    bool
	Consequences     []Consequence
	ValidationChecks []ValidationCheck
	IndexGuards      []IndexGuard
	Conditions       []Condition
	SQL              []string
	Risks            []string
	References       []Baseline
	ResultTarget     *Target
	Types            []TypeGuard
}
type AdvancedAdapter interface {
	StructurePrepare(context.Context, Baseline, Draft) (Prepared, error)
	StructureApplySteps(context.Context, Baseline, Plan) []Execution
}

func columnsValid(names []string) bool {
	if len(names) == 0 || len(names) > 32 {
		return false
	}
	seen := map[string]bool{}
	for _, n := range names {
		if !Identifier(n) || seen[n] {
			return false
		}
		seen[n] = true
	}
	return true
}
func Action(a string) bool { return a == "add" || a == "drop" || a == "replace" }
func (d Draft) Destructive() bool {
	if d.NeedsAuthoringV4() || d.NeedsAuthoringV5() {
		return true
	}
	for _, x := range d.Indexes {
		if x.Action != "add" {
			return true
		}
	}
	for _, x := range d.Keys {
		if x.Action != "add" {
			return true
		}
	}
	return false
}
func (d Draft) Validate() error {
	if d.AuthoringVersion != 0 && d.AuthoringVersion != 2 && d.AuthoringVersion != 3 && d.AuthoringVersion != 4 && d.AuthoringVersion != 5 || d.NeedsAuthoringV2() && d.AuthoringVersion < 2 || d.NeedsAuthoringV3() && d.AuthoringVersion < 3 || d.NeedsAuthoringV4() && d.AuthoringVersion < 4 {
		return ErrInvalid
	}
	if err := d.validateReconstruction(); err != nil {
		return err
	}
	if len(d.Columns) > MaxColumns || len(d.Changes)+len(d.Indexes)+len(d.Keys) > 64 || len(d.Columns)+len(d.Changes)+len(d.Indexes)+len(d.Keys) == 0 && d.RenameTable == nil && !d.DropTable && !d.NeedsAuthoringV5() || d.RenameTable != nil && !Identifier(*d.RenameTable) {
		return ErrInvalid
	}
	if d.DropTable && (len(d.Columns)+len(d.Changes)+len(d.Indexes)+len(d.Keys) != 0 || d.RenameTable != nil) {
		return ErrInvalid
	}
	seen := map[string]bool{}
	for _, c := range d.Columns {
		if !c.Valid() || seen[c.Name] {
			return ErrInvalid
		}
		seen[c.Name] = true
	}
	for _, c := range d.Changes {
		if !Identifier(c.Name) || seen[c.Name] || c.Nullable == nil && c.Default == nil && c.Type == nil && c.RenameTo == nil && c.Generated == nil && c.Identity == nil && !c.Drop && c.Unsigned == nil && c.Charset == nil && c.Collation == nil || !changeDestructiveValid(c) || c.Default != nil && !c.Default.Valid() || c.Type != nil && !c.Type.Valid() || !changeAuthoredValid(c) {
			return ErrInvalid
		}
		seen[c.Name] = true
	}
	seen = map[string]bool{}
	for _, x := range d.Indexes {
		if !Action(x.Action) || !Identifier(x.Name) || seen[x.Name] || x.Action != "drop" && (x.Definition == nil && !columnsValid(x.Columns) || x.Definition != nil && (x.Columns != nil || !x.Definition.Valid())) || x.Action == "drop" && (len(x.Columns) > 0 || x.Unique || x.Definition != nil) {
			return ErrInvalid
		}
		seen[x.Name] = true
	}
	seen = map[string]bool{}
	for _, x := range d.Keys {
		if !Action(x.Action) || !Identifier(x.Name) || seen[x.Name] || x.Kind != "primary" && x.Kind != "unique" && x.Kind != "foreign" {
			return ErrInvalid
		}
		seen[x.Name] = true
		if x.Action == "drop" {
			if len(x.Columns) > 0 || x.Reference != nil || len(x.ReferenceColumns) > 0 || x.OnDelete != "" || x.OnUpdate != "" {
				return ErrInvalid
			}
			continue
		}
		if !columnsValid(x.Columns) {
			return ErrInvalid
		}
		if x.Kind == "foreign" {
			if x.Reference == nil || !x.Reference.Valid() || x.Reference.Create || x.Reference.Reconcile || !columnsValid(x.ReferenceColumns) || len(x.Columns) != len(x.ReferenceColumns) || !ReferentialAction(x.OnDelete) || !ReferentialAction(x.OnUpdate) {
				return ErrInvalid
			}
		} else if x.Reference != nil || len(x.ReferenceColumns) > 0 || x.OnDelete != "" || x.OnUpdate != "" {
			return ErrInvalid
		}
	}
	if d.Destructive() && !d.AllowDestructive {
		return errors.New("Select explicit destructive permission before previewing removal or a value-changing conversion.")
	}
	return nil
}
func ReferentialAction(s string) bool {
	return s == "NO ACTION" || s == "RESTRICT" || s == "CASCADE" || s == "SET NULL"
}
func ColumnType(c sc.Column) (DataType, bool) {
	if c.Type.Value == nil || c.Type.Value.Kind != "builtin" || c.Type.Value.Modifiers.Value == nil {
		return DataType{}, false
	}
	t := c.Type.Value
	m := t.Modifiers.Value
	if m.ArrayDimensions != 0 || m.Zerofill {
		return DataType{}, false
	}
	kind := map[string]string{"int4": "integer", "int": "integer", "integer": "integer", "int8": "bigint", "bigint": "bigint", "bool": "boolean", "boolean": "boolean", "numeric": "numeric", "decimal": "numeric", "varchar": "varchar", "text": "text"}[t.Ref.Name]
	d := DataType{Kind: kind}
	switch kind {
	case "varchar":
		if m.Length == nil {
			return d, false
		}
		d.Length = int(*m.Length)
	case "numeric":
		if m.Precision == nil || m.Scale == nil {
			return d, false
		}
		d.Precision = int(*m.Precision)
		d.Scale = int(*m.Scale)
	}
	return d, d.Valid()
}
func FindColumn(b Baseline, name string) (sc.Column, bool) {
	if b.Facts != nil {
		for _, c := range b.Facts.Table.Columns.Items {
			if c.Ref.Name == name {
				return c, true
			}
		}
	}
	return sc.Column{}, false
}
func CanWiden(c sc.Column, t DataType) bool {
	old, ok := ColumnType(c)
	return ok && (old.Kind == "integer" && t.Kind == "bigint" || old.Kind == "varchar" && t.Kind == "varchar" && t.Length > old.Length)
}
func IndexSupported(x sc.Index) bool {
	if x.Method.Value == nil || !strings.EqualFold(*x.Method.Value, "btree") || x.Unique.Value == nil || !x.Keys.Complete || len(x.Keys.Items) == 0 || !x.Includes.Complete || len(x.Includes.Items) > 0 || x.Predicate.Value != nil || !x.Options.Complete || len(x.Options.Items) > 0 || x.Visible.Value == nil || !*x.Visible.Value || x.Valid.Value == nil || !*x.Valid.Value || x.Ready.Value == nil || !*x.Ready.Value {
		return false
	}
	for _, k := range x.Keys.Items {
		if k.Column.Value == nil || k.Expression.Value != nil || k.PrefixLength.Value != nil || !k.Options.Complete || len(k.Options.Items) > 0 || k.Descending.Value == nil || *k.Descending.Value || k.Opclass.State == "unsupported" {
			return false
		}
		if k.Opclass.Value != nil {
			switch k.Opclass.Value.Name {
			case "int4_ops", "int8_ops", "bool_ops", "numeric_ops", "text_ops":
			default:
				return false
			}
		}
	}
	return true
}
func KeySupported(c sc.Constraint, indexes []sc.Index) bool {
	if c.Kind.Value == nil || !c.Columns.Complete || len(c.Columns.Items) == 0 || c.Validated.Value == nil || !*c.Validated.Value || c.Enforced.Value == nil || !*c.Enforced.Value || c.Deferrable.Value == nil || *c.Deferrable.Value || c.Inherited.Value == nil || *c.Inherited.Value {
		return false
	}
	switch *c.Kind.Value {
	case "p", "u":
		if c.BackingIndex.Value == nil {
			return false
		}
		for _, x := range indexes {
			if x.Ref.Name == c.BackingIndex.Value.Name {
				return IndexSupported(x)
			}
		}
		return false
	case "f":
		return c.Target.Value != nil && c.ForeignKeys.Complete && len(c.ForeignKeys.Items) == len(c.Columns.Items) && len(c.SetColumns.Items) == 0
	default:
		return false
	}
}
func Summarize(b *Baseline) {
	b.Keys = []Key{}
	b.Indexes = []Index{}
	if b.Facts == nil {
		return
	}
	f := b.Facts
	b.DependencyProof = f.Proof
	for i := range b.Columns {
		if c, ok := FindColumn(*b, b.Columns[i].Name); ok {
			if t, valid := ColumnType(c); valid {
				b.Columns[i].EditableType = &t
			}
			if c.Type.Value != nil && c.Type.Value.Modifiers.Value != nil && b.Engine == "mysql" {
				unsigned := c.Type.Value.Modifiers.Value.Unsigned
				b.Columns[i].Unsigned = &unsigned
			}
			if c.Charset.Value != nil {
				v := *c.Charset.Value
				b.Columns[i].Charset = &v
			}
			if c.Collation.Value != nil {
				b.Columns[i].Collation = &TypeReference{Schema: c.Collation.Value.Schema, Name: c.Collation.Value.Name}
			}
			b.Columns[i].CanModify = c.Generated.Value != nil && c.Generated.Value.Kind == "none" && c.Identity.Value != nil && c.Identity.Value.Kind == "none" && !unavailableColumnExpression(c)
		}
	}
	if len(f.IndexAttributes) > 0 {
		const limitation = "Indexes with unexposed comments, tablespaces, cluster/replica identity, statistics or parser/engine attributes are read-only. Preview explains the selected index's prerequisite; use an explicit reviewed migration."
		present := false
		for _, value := range b.Limitations {
			present = present || strings.Contains(value, limitation)
		}
		if !present {
			if len(b.Limitations) < 64 {
				b.Limitations = append(b.Limitations, limitation)
			} else if len(b.Limitations[63])+len(limitation)+1 <= 4096 {
				b.Limitations[63] += "\n" + limitation
			}
		}
	}
	for _, x := range f.Table.Indexes.Items {
		item := Index{Name: x.Ref.Name, Columns: []string{}, Supported: IndexSupported(x)}
		if definition, ok := ObservedIndexDefinition(b.Engine, x); ok {
			item.Definition = definition
			item.Supported = true
		}
		if x.Unique.Value != nil {
			item.Unique = *x.Unique.Value
		}
		if x.Constraint.Value != nil {
			item.Owner = x.Constraint.Value.Name
		}
		for _, c := range x.Keys.Items {
			if c.Column.Value != nil {
				item.Columns = append(item.Columns, c.Column.Value.Name)
			}
		}
		b.Indexes = append(b.Indexes, item)
	}
	for _, c := range f.Table.Constraints.Items {
		if c.Kind.Value != nil && *c.Kind.Value == "n" {
			continue
		}
		k := Key{Name: c.Ref.Name, Columns: []string{}, Supported: KeySupported(c, f.Table.Indexes.Items)}
		if c.Kind.Value != nil {
			k.Kind = map[string]string{"p": "primary", "u": "unique", "f": "foreign"}[*c.Kind.Value]
		}
		if k.Kind == "" {
			k.Kind = "unsupported"
		}
		for _, x := range c.Columns.Items {
			k.Columns = append(k.Columns, x.Name)
		}
		if c.Target.Value != nil {
			k.Reference = &Target{Schema: c.Target.Value.Schema, Table: c.Target.Value.Name}
			for _, p := range c.ForeignKeys.Items {
				k.ReferenceColumns = append(k.ReferenceColumns, p.Target.Name)
			}
			k.OnDelete = NormalizeAction(c.Delete.Value)
			k.OnUpdate = NormalizeAction(c.Update.Value)
		}
		b.Keys = append(b.Keys, k)
	}
}
func NormalizeAction(p *string) string {
	if p == nil {
		return ""
	}
	switch *p {
	case "a":
		return "NO ACTION"
	case "r":
		return "RESTRICT"
	case "c":
		return "CASCADE"
	case "n":
		return "SET NULL"
	default:
		return *p
	}
}
func CheckChange(b Baseline, c ColumnChange) error {
	if c.Drop {
		return ErrInvalid
	}
	if c.UsingExpression != nil || c.Unsigned != nil || c.Charset != nil || c.Collation != nil || c.Type != nil && b.Engine != "sqlite" && !CanWidenColumn(b, c) {
		return CheckConversion(b, c)
	}
	if c.Type != nil && c.Type.Reference != nil {
		return ErrUnsupported
	}
	old, ok := FindColumn(b, c.Name)
	if !ok || old.Generated.Value == nil || old.Identity.Value == nil {
		return ErrUnsupported
	}
	if unavailableColumnExpression(old) {
		return errors.New("This column's expression metadata requires custom type support code and is unavailable for attribute changes; its raw catalog proof is retained. Use an explicit reviewed migration.")
	}
	if c.Generated != nil || c.Identity != nil {
		if c.Type != nil || c.Nullable != nil || c.Default != nil || c.Generated != nil && c.Identity != nil {
			return errors.New("Review generation and identity changes separately from other column attributes.")
		}
		return nil
	}
	if c.Type != nil && (old.Generated.Value.Kind != "none" || old.Identity.Value.Kind != "none") {
		return ErrUnsupported
	}
	if c.Type != nil {
		if old.Default.Value == nil || old.Default.Value.Kind != "none" && !(b.Engine == "mysql" && old.Default.Value.Kind == "sqlNull") {
			return errors.New("Type widening requires a column without a default expression.")
		}
		if !CanWiden(old, *c.Type) {
			return errors.New("Only integer to bigint or an increased varchar length is supported; signedness and encoding stay unchanged.")
		}
		if b.Facts == nil || !b.Facts.Proof || len(b.Facts.Dependents[""]) > 0 || len(b.Facts.Dependents[c.Name]) > 0 {
			return errors.New("Type widening requires complete, dependency-free metadata; views, triggers, routines or other dependents block it. Dynamic SQL dependencies cannot be proven absent.")
		}
		for _, k := range b.Keys {
			for _, n := range k.Columns {
				if n == c.Name {
					return ErrUnsupported
				}
			}
		}
		for _, x := range b.Indexes {
			for _, n := range x.Columns {
				if n == c.Name {
					return ErrUnsupported
				}
			}
		}
	}
	return nil
}
func CheckRemoval(b Baseline, d Draft, name string, key bool) error {
	sensitive := false
	if key {
		for _, k := range b.Keys {
			if k.Name == name && k.Kind != "foreign" {
				sensitive = true
			}
		}
	} else {
		for _, x := range b.Indexes {
			if x.Name == name && x.Unique {
				sensitive = true
			}
		}
	}
	if b.Facts == nil || sensitive && !b.Facts.Proof {
		return errors.New("Removal requires complete incoming-dependency visibility.")
	}
	attributeName := name
	if key {
		for _, index := range b.Indexes {
			if index.Owner == name {
				attributeName = index.Name
				break
			}
		}
	}
	if attributes := b.Facts.IndexAttributes[attributeName]; len(attributes) > 0 {
		return fmt.Errorf("Index %s has unexposed %s; removal/replacement requires an explicit reviewed migration so those properties cannot be silently lost.", attributeName, attributes["reason"])
	}
	for _, incoming := range b.Facts.Incoming {
		if !sensitive {
			continue
		}
		if incoming.Schema != b.Target.Schema || incoming.Table != b.Target.Table {
			return fmt.Errorf("Removal is blocked by incoming foreign key %s.%s.%s.", incoming.Schema, incoming.Table, incoming.Name)
		}
		dropped := false
		for _, k := range d.Keys {
			if k.Name == incoming.Name && k.Kind == "foreign" && k.Action != "add" {
				dropped = true
			}
		}
		if !dropped {
			return errors.New("Explicitly remove the dependent foreign key in this reviewed draft before removing a referenced key.")
		}
	}
	if key {
		for _, k := range b.Keys {
			if k.Name == name && k.Supported {
				return nil
			}
		}
	} else {
		for _, x := range b.Indexes {
			if x.Name == name && x.Supported && x.Owner == "" {
				return nil
			}
		}
	}
	return errors.New("Unsupported keys or constraint-owned indexes cannot be removed independently.")
}
func ValidateForeign(source Baseline, k KeyEdit, target Baseline) error {
	if target.Facts == nil || !target.Facts.Table.Columns.Complete || !target.Facts.Table.Constraints.Complete {
		return ErrUnsupported
	}
	found := false
	for _, key := range target.Keys {
		if key.Supported && (key.Kind == "primary" || key.Kind == "unique") && reflect.DeepEqual(key.Columns, k.ReferenceColumns) {
			found = true
		}
	}
	if !found {
		return errors.New("A foreign key must reference a supported primary or unique key in exactly the selected column order.")
	}
	for i, n := range k.Columns {
		a, ok := FindColumn(source, n)
		b, other := FindColumn(target, k.ReferenceColumns[i])
		if !ok || !other || a.Type.Value == nil || b.Type.Value == nil || !sameForeignType(a, b) || !reflect.DeepEqual(a.Charset, b.Charset) || !reflect.DeepEqual(a.Collation, b.Collation) {
			return errors.New("Foreign-key types, signedness, charset and collation must match.")
		}
		if k.OnDelete == "SET NULL" || k.OnUpdate == "SET NULL" {
			if a.Nullable.Value == nil || !*a.Nullable.Value {
				return errors.New("SET NULL requires nullable source columns.")
			}
		}
	}
	return nil
}

func sameForeignType(a, b sc.Column) bool {
	x, ok := ColumnType(a)
	y, other := ColumnType(b)
	return ok && other && x == y && a.Type.Value.Modifiers.Value.Unsigned == b.Type.Value.Modifiers.Value.Unsigned
}
func PlanningSource(b Baseline, d Draft, engine string) Baseline {
	var f Facts
	if b.Facts != nil {
		raw, _ := json.Marshal(b.Facts)
		_ = json.Unmarshal(raw, &f)
	} else {
		f = Facts{Proof: b.Target.Create, Table: sc.Table{Ref: sc.Ref{Kind: "table", Schema: b.Target.Schema, Name: b.Target.Table}, Columns: sc.Complete[sc.Column](nil), Constraints: sc.Complete[sc.Constraint](nil), Indexes: sc.Complete[sc.Index](nil)}, Dependents: map[string][]string{}}
	}
	b.Facts = &f
	for _, c := range d.Columns {
		m := sc.TypeModifiers{}
		if c.Type.Kind == "varchar" {
			n := int64(c.Type.Length)
			m.Length = &n
		}
		if c.Type.Kind == "numeric" {
			p, s := int64(c.Type.Precision), int64(c.Type.Scale)
			m.Precision = &p
			m.Scale = &s
		}
		name := c.Type.Kind
		schema := ""
		if engine == "postgresql" {
			schema = "pg_catalog"
			name = map[string]string{"integer": "int4", "bigint": "int8", "boolean": "bool", "numeric": "numeric", "varchar": "varchar", "text": "text"}[name]
		} else {
			name = map[string]string{"integer": "int", "bigint": "bigint", "numeric": "decimal", "varchar": "varchar", "text": "text"}[name]
		}
		col := sc.Column{Ref: sc.Ref{Kind: "column", Schema: b.Target.Schema, Table: b.Target.Table, Name: c.Name}, Type: sc.Known(sc.TypeUse{Ref: sc.Ref{Kind: "type", Schema: schema, Name: name}, Kind: "builtin", Modifiers: sc.Known(m), Labels: sc.Complete[string](nil)}), Nullable: sc.Known(c.Nullable), Default: sc.Known(sc.Default{Kind: "none"}), Generated: sc.Known(sc.Generated{Kind: "none"}), Identity: sc.Known(sc.Identity{Kind: "none"}), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Visible: sc.Known(true), Comment: sc.Known(""), OnUpdate: sc.Absent[sc.Expression]()}
		if c.Type.Kind == "text" || c.Type.Kind == "varchar" {
			if engine == "postgresql" {
				col.Collation = sc.Known(sc.Ref{Kind: "collation", Schema: "pg_catalog", Name: "default"})
				col.CollationProperties = f.DefaultCollationProperties
			} else {
				col.Charset = f.Table.Charset
				col.Collation = f.Table.Collation
			}
		}
		col.Type = sc.Known(ExpectedColumnType(engine, c))
		if c.Resolved != nil {
			col.Collation = c.Resolved.Collation
			col.CollationProperties = c.Resolved.CollationProperties
		}
		f.Table.Columns.Items = append(f.Table.Columns.Items, col)
	}
	for _, change := range d.Changes {
		for i := range f.Table.Columns.Items {
			col := &f.Table.Columns.Items[i]
			if col.Ref.Name != change.Name {
				continue
			}
			if (change.Type != nil || change.Unsigned != nil) && col.Type.Value != nil {
				col.Type = sc.Known(ExpectedChangedType(engine, *col.Type.Value, change))
			}
			if change.Charset != nil {
				col.Charset = sc.Known(*change.Charset)
			}
			if change.Collation != nil {
				col.Collation = sc.Known(sc.Ref{Kind: "collation", Schema: change.Collation.Schema, Name: change.Collation.Name})
			}
			if change.Nullable != nil {
				col.Nullable = sc.Known(*change.Nullable)
			}
			if change.Default != nil {
				value := sc.Default{Kind: "none"}
				switch change.Default.Kind {
				case "null":
					value.Kind = "sqlNull"
				case "text", "numeric", "boolean":
					value.Kind = "literal"
					value.Value = change.Default.Value
					value.Type = col.Type.Value
				}
				col.Default = sc.Known(value)
			}
		}
	}
	return b
}

func ExpectedWidenType(engine string, old sc.TypeUse, want DataType) sc.TypeUse {
	raw, _ := json.Marshal(old)
	var result sc.TypeUse
	_ = json.Unmarshal(raw, &result)
	if want.Kind == "bigint" {
		if engine == "postgresql" {
			result.Ref.Name = "int8"
		} else {
			result.Ref.Name = "bigint"
			p := int64(19)
			if result.Modifiers.Value.Unsigned {
				p = 20
			}
			result.Modifiers.Value.Precision = &p
		}
	} else if want.Kind == "varchar" {
		n := int64(want.Length)
		result.Modifiers.Value.Length = &n
	}
	return result
}
func ExpectedNewType(engine string, want DataType) sc.TypeUse {
	m := sc.TypeModifiers{}
	name := want.Kind
	schema := ""
	if engine == "postgresql" {
		schema = "pg_catalog"
		name = map[string]string{"integer": "int4", "bigint": "int8", "boolean": "bool", "numeric": "numeric", "varchar": "varchar", "text": "text"}[name]
	} else {
		name = map[string]string{"integer": "int", "bigint": "bigint", "numeric": "decimal", "varchar": "varchar", "text": "text"}[name]
		if want.Kind == "integer" || want.Kind == "bigint" {
			p, s := int64(10), int64(0)
			if want.Kind == "bigint" {
				p = 19
			}
			m.Precision = &p
			m.Scale = &s
		}
	}
	if want.Kind == "varchar" {
		n := int64(want.Length)
		m.Length = &n
	}
	if want.Kind == "numeric" {
		p, s := int64(want.Precision), int64(want.Scale)
		m.Precision = &p
		m.Scale = &s
	}
	return sc.TypeUse{Ref: sc.Ref{Kind: "type", Schema: schema, Name: name}, Kind: "builtin", Modifiers: sc.Known(m), Labels: sc.Complete[string](nil)}
}

func unavailableColumnExpression(c sc.Column) bool {
	return c.Default.Value != nil && c.Default.Value.Expression != nil && c.Default.Value.Expression.Dependencies.Code == "customTypeSupport" || c.Generated.Value != nil && c.Generated.Value.Expression != nil && c.Generated.Value.Expression.Dependencies.Code == "customTypeSupport"
}
