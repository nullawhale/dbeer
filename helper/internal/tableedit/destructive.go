package tableedit

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

type Consequence struct {
	Kind    string `json:"kind"`
	Object  string `json:"object"`
	Message string `json:"message"`
}
type ValidationCheck struct {
	ID                string   `json:"id"`
	Summary           string   `json:"summary"`
	SQL               *string  `json:"sql,omitempty"`
	Risks             []string `json:"risks"`
	UnavailableReason *string  `json:"unavailableReason,omitempty"`
}
type ValidationResult struct {
	ID          string  `json:"id"`
	State       string  `json:"state"`
	InvalidRows *string `json:"invalidRows,omitempty"`
	Message     string  `json:"message,omitempty"`
}
type ValidationOutcome struct {
	ExecutionID string             `json:"executionId"`
	PlanID      string             `json:"planId"`
	Digest      string             `json:"digest"`
	State       string             `json:"state"`
	Checks      []ValidationResult `json:"checks"`
}
type ValidationAdapter interface {
	StructureValidate(context.Context, Baseline, Plan) []ValidationResult
}

func (d Draft) NeedsAuthoringV4() bool {
	if d.DropTable || d.AuthoringVersion == 4 {
		return true
	}
	for _, c := range d.Changes {
		if c.Drop || c.UsingExpression != nil || c.Unsigned != nil || c.Charset != nil || c.Collation != nil || d.AuthoringVersion >= 4 && c.Type != nil {
			return true
		}
	}
	return false
}
func (c ColumnChange) Conversion() bool {
	return c.Type != nil || c.UsingExpression != nil || c.Unsigned != nil || c.Charset != nil || c.Collation != nil
}
func changeDestructiveValid(c ColumnChange) bool {
	if c.Drop {
		return c.RenameTo == nil && c.Generated == nil && c.Identity == nil && c.Nullable == nil && c.Default == nil && !c.Conversion()
	}
	if c.UsingExpression != nil && (c.Type == nil || !authoredText(*c.UsingExpression)) {
		return false
	}
	if c.Charset != nil && !Identifier(*c.Charset) {
		return false
	}
	if c.Collation != nil && (!Identifier(c.Collation.Name) || c.Collation.Schema != "" && !Identifier(c.Collation.Schema)) {
		return false
	}
	if (c.Unsigned != nil || c.Charset != nil || c.Collation != nil || c.UsingExpression != nil) && (c.Generated != nil || c.Identity != nil || c.RenameTo != nil) {
		return false
	}
	return true
}
func CheckConversion(b Baseline, c ColumnChange) error {
	if b.Engine != "postgresql" && b.Engine != "mysql" {
		return ErrUnsupported
	}
	if b.Engine == "postgresql" && (c.Unsigned != nil || c.Charset != nil || c.Collation != nil && c.Collation.Schema == "") {
		return errors.New("PostgreSQL signedness and per-column encoding cannot be changed; COLLATE requires an exact qualified collation. Database encoding is fixed when the database is created.")
	}
	if b.Engine == "mysql" && (c.UsingExpression != nil || c.Collation != nil && c.Collation.Schema != "") {
		return errors.New("MySQL does not support PostgreSQL USING; select an unqualified native collation name.")
	}
	if c.Type != nil && c.Type.Reference != nil {
		return errors.New("Existing-column conversion requires a built-in target type; custom casts and support-code preservation require an explicit reviewed migration.")
	}
	old, ok := FindColumn(b, c.Name)
	if !ok || old.Type.Value == nil || old.Type.Value.Kind != "builtin" || old.Type.Value.Modifiers.Value == nil || old.Generated.Value == nil || old.Identity.Value == nil || old.Generated.Value.Kind != "none" || old.Identity.Value.Kind != "none" || unavailableColumnExpression(old) {
		return errors.New("Conversion requires an ordinary built-in column with complete generation, identity and expression evidence.")
	}
	if b.Engine == "postgresql" && !PostgresBuiltinIdentity(old, b.Attributes[c.Name]) {
		return errors.New("Conversion and validation require the actual captured PostgreSQL built-in type identity.")
	}

	oldType, ok := ColumnType(old)
	if !ok {
		return errors.New("The selected native source type or modifiers are not supported for typed conversion.")
	}
	if old.Default.Value == nil || old.Default.Value.Kind != "none" && !(b.Engine == "mysql" && old.Default.Value.Kind == "sqlNull") {
		return errors.New("Remove the existing DEFAULT in a separate reviewed plan before converting this column; USING does not convert defaults.")
	}
	if c.Default != nil || c.Nullable != nil || c.Generated != nil || c.Identity != nil {
		return errors.New("Review type, signedness and encoding conversion separately from default, nullability and generation changes.")
	}
	if b.Engine == "postgresql" && (c.Type != nil || c.Collation != nil) {
		attrs := b.Attributes[c.Name]
		if len(attrs) > 0 {
			if attrs["attstorage"] != b.Facts.TypeStorage[oldType.Kind] || attrs["attcompression"] != "" {
				return errors.New("The selected column has custom storage/compression settings; preserve them in an explicit reviewed conversion migration.")
			}
		}
	}
	target := oldType
	if c.Type != nil {
		target = *c.Type
	}
	if !map[string]bool{"integer": true, "bigint": true, "numeric": true, "varchar": true, "text": true, "boolean": true}[target.Kind] || b.Engine == "mysql" && target.Kind == "boolean" {
		return errors.New("The selected target type is outside this engine's typed conversion support.")
	}
	if c.Unsigned != nil && target.Kind != "integer" && target.Kind != "bigint" && target.Kind != "numeric" {
		return errors.New("Signedness applies only to MySQL integer and decimal columns.")
	}
	if c.Charset != nil && c.Collation == nil {
		return errors.New("Choose the exact target collation together with the target character set.")
	}
	if (c.Charset != nil || c.Collation != nil) && target.Kind != "varchar" && target.Kind != "text" {
		return errors.New("Encoding and collation require a textual target type.")
	}
	if c.UsingExpression != nil {
		if _, err := ExpressionSlot("postgresql", *c.UsingExpression); err != nil {
			return err
		}
	}
	if b.Facts != nil {
		if deps := append(append([]string{}, b.Facts.Dependents[""]...), b.Facts.Dependents[c.Name]...); len(deps) > 0 {
			return fmt.Errorf("Conversion of column %s is blocked by dependencies: %s.", c.Name, strings.Join(deps, ", "))
		}
	}
	if err := CheckRename(b, c.Name); err != nil {
		return fmt.Errorf("Conversion of column %s requires dependency repair: %w", c.Name, err)
	}
	for _, incoming := range b.Facts.Incoming {
		for _, name := range incoming.Columns {
			if name == c.Name {
				return fmt.Errorf("Conversion is blocked by incoming foreign key %s.%s.%s.", incoming.Schema, incoming.Table, incoming.Name)
			}
		}
	}
	for _, k := range b.Keys {
		for _, name := range k.Columns {
			if name == c.Name {
				return fmt.Errorf("Remove dependent key %s in a separate reviewed plan before conversion.", k.Name)
			}
		}
	}
	for _, x := range b.Indexes {
		if indexUsesColumn(b, x, c.Name) {
			return fmt.Errorf("Remove dependent index %s in a separate reviewed plan before conversion.", x.Name)
		}
	}
	return nil
}
func CheckDropTable(b Baseline) error {
	if b.Target.Create || b.Facts == nil || !b.Facts.Proof || !b.Facts.Table.Columns.Complete || !b.Facts.Table.Constraints.Complete || !b.Facts.Table.Indexes.Complete {
		return errors.New("DROP TABLE requires complete column, key, index and incoming-dependency metadata.")
	}
	for name, deps := range b.Facts.Dependents {
		if len(deps) > 0 {
			return fmt.Errorf("DROP TABLE is blocked by dependents of %s: %s. Repair them explicitly; CASCADE is never generated.", name, strings.Join(deps, ", "))
		}
	}
	for _, x := range b.Facts.Incoming {
		if x.Schema != b.Target.Schema || x.Table != b.Target.Table {
			return fmt.Errorf("DROP TABLE is blocked by incoming foreign key %s.%s.%s.", x.Schema, x.Table, x.Name)
		}
	}
	return nil
}
func indexUsesColumn(b Baseline, x Index, name string) bool {
	for _, n := range x.Columns {
		if n == name {
			return true
		}
	}
	for _, fact := range b.Facts.Table.Indexes.Items {
		if fact.Ref.Name != x.Name {
			continue
		}
		depends := func(e *sc.Expression) bool {
			if e == nil {
				return false
			}
			if !e.Dependencies.Complete {
				return true
			}
			for _, r := range e.Dependencies.Items {
				if r.Kind == "column" && r.Schema == b.Target.Schema && r.Table == b.Target.Table && r.Name == name {
					return true
				}
			}
			return false
		}
		if depends(fact.Predicate.Value) {
			return true
		}
		for _, k := range fact.Keys.Items {
			if depends(k.Expression.Value) {
				return true
			}
		}
		for _, r := range fact.Includes.Items {
			if r.Name == name {
				return true
			}
		}
	}
	return false
}
func CheckDropColumn(b Baseline, d Draft, name string) error {
	old, ok := FindColumn(b, name)
	if !ok {
		return ErrInvalid
	}
	if unavailableColumnExpression(old) {
		return errors.New("DROP COLUMN requires describable expression metadata; custom-support raw evidence must be handled in an explicit reviewed migration.")
	}
	source := b
	source.Facts = cloneFacts(b.Facts)
	if source.Facts == nil {
		return ErrUnsupported
	}
	for _, k := range b.Keys {
		for _, n := range k.Columns {
			if n != name {
				continue
			}
			removed := false
			for _, e := range d.Keys {
				removed = removed || e.Name == k.Name && e.Action == "drop"
			}
			if !removed {
				return fmt.Errorf("Explicitly remove dependent key %s before dropping column %s.", k.Name, name)
			}
		}
	}
	for _, x := range b.Indexes {
		if !indexUsesColumn(b, x, name) {
			continue
		}
		removed := false
		for _, e := range d.Indexes {
			removed = removed || e.Name == x.Name && e.Action == "drop"
		}
		for _, e := range d.Keys {
			removed = removed || x.Owner != "" && e.Name == x.Owner && e.Action == "drop"
		}
		if !removed {
			return fmt.Errorf("Explicitly remove dependent index %s before dropping column %s.", x.Name, name)
		}
	}
	// Only explicit removals may eliminate local dependency evidence.
	indexes := []sc.Index{}
	for _, x := range source.Facts.Table.Indexes.Items {
		remove := false
		for _, e := range d.Indexes {
			remove = remove || e.Name == x.Ref.Name && e.Action == "drop"
		}
		for _, e := range d.Keys {
			remove = remove || x.Constraint.Value != nil && e.Name == x.Constraint.Value.Name && e.Action == "drop"
		}
		if !remove {
			indexes = append(indexes, x)
		}
	}
	source.Facts.Table.Indexes.Items = indexes
	constraints := []sc.Constraint{}
	for _, k := range source.Facts.Table.Constraints.Items {
		remove := false
		for _, e := range d.Keys {
			remove = remove || e.Name == k.Ref.Name && e.Action == "drop"
		}
		if !remove {
			constraints = append(constraints, k)
		}
	}
	source.Facts.Table.Constraints.Items = constraints
	if deps := append(append([]string{}, source.Facts.Dependents[""]...), source.Facts.Dependents[name]...); len(deps) > 0 {
		return fmt.Errorf("DROP COLUMN %s is blocked by dependencies: %s.", name, strings.Join(deps, ", "))
	}
	if err := CheckRename(source, name); err != nil {
		return fmt.Errorf("DROP COLUMN %s requires dependency repair: %w", name, err)
	}
	for _, x := range b.Facts.Incoming {
		for _, n := range x.Columns {
			if n != name {
				continue
			}
			removed := false
			if x.Schema == b.Target.Schema && x.Table == b.Target.Table {
				for _, e := range d.Keys {
					removed = removed || e.Name == x.Name && e.Action == "drop"
				}
			}
			if !removed {
				return fmt.Errorf("DROP COLUMN is blocked by incoming foreign key %s.%s.%s.", x.Schema, x.Table, x.Name)
			}
		}
	}
	remaining := len(b.Columns) + len(d.Columns)
	for _, c := range d.Changes {
		if c.Drop {
			remaining--
		}
	}
	if remaining < 1 {
		return errors.New("Keep at least one column; review DROP TABLE separately to remove the table.")
	}
	return nil
}
func validReview(consequences []Consequence, checks []ValidationCheck) bool {
	if len(consequences) > 512 || len(checks) > 64 {
		return false
	}
	seen := map[string]bool{}
	for _, c := range consequences {
		if !authoredText(c.Kind) || !authoredText(c.Object) || !authoredText(c.Message) {
			return false
		}
	}
	for _, c := range checks {
		if !ID(c.ID) || seen[c.ID] || !authoredText(c.Summary) || len(c.Risks) > 16 || (c.SQL == nil) == (c.UnavailableReason == nil) {
			return false
		}
		seen[c.ID] = true
		if c.SQL != nil && (len(*c.SQL) == 0 || len(*c.SQL) > MaxSQLBytes || strings.ContainsRune(*c.SQL, 0)) {
			return false
		}
		if c.UnavailableReason != nil && !authoredText(*c.UnavailableReason) {
			return false
		}
		for _, r := range c.Risks {
			if !authoredText(r) {
				return false
			}
		}
	}
	return true
}
func (s *Store) Validate(ctx context.Context, a Adapter, r Apply) (Reply, error) {
	p, err := s.Resolve(r)
	if err != nil {
		return Reply{}, err
	}
	adapter, ok := a.(ValidationAdapter)
	if !ok || len(p.ValidationChecks) == 0 {
		return Reply{}, ErrUnsupported
	}
	outcome := &ValidationOutcome{ExecutionID: r.ExecutionID, PlanID: p.ID, Digest: p.Digest, State: "completed", Checks: make([]ValidationResult, len(p.ValidationChecks))}
	for i, c := range p.ValidationChecks {
		outcome.Checks[i] = ValidationResult{ID: c.ID, State: "notStarted"}
	}
	if ctx.Err() != nil {
		outcome.State = "cancelled"
		s.validation = outcome
		return Reply{Validation: outcome}, nil
	}
	results := adapter.StructureValidate(ctx, *s.baseline, *p)
	invalid := false
	for i, x := range results {
		if i >= len(outcome.Checks) || x.ID != outcome.Checks[i].ID {
			invalid = true
			break
		}
		switch x.State {
		case "passed", "failed":
			if x.InvalidRows == nil {
				invalid = x.State == "passed" || x.Message == ""
			} else if n, e := strconv.ParseUint(*x.InvalidRows, 10, 64); e != nil || strconv.FormatUint(n, 10) != *x.InvalidRows || x.State == "passed" && n != 0 || x.State == "failed" && n == 0 {
				invalid = true
			}
		case "unavailable", "cancelled", "notStarted":
			if x.InvalidRows != nil {
				invalid = true
			}
		default:
			invalid = true
		}
		if len(x.Message) > 4096 {
			invalid = true
		}
		if invalid {
			break
		}
		outcome.Checks[i] = x
	}
	if invalid {
		outcome.State = "failed"
		for i := range outcome.Checks {
			outcome.Checks[i] = ValidationResult{ID: outcome.Checks[i].ID, State: "notStarted", Message: "The validation response was invalid. No Apply was authorized."}
		}
	} else if ctx.Err() != nil {
		outcome.State = "cancelled"
	} else {
		for _, x := range outcome.Checks {
			if x.State == "cancelled" {
				outcome.State = "cancelled"
			} else if outcome.State != "cancelled" && (x.State == "notStarted" || x.State == "failed" && x.InvalidRows == nil) {
				outcome.State = "failed"
			}
		}
	}
	s.validation = outcome
	return Reply{Validation: outcome}, nil
}

// ExpectedChangedType keeps every untouched modifier; authored targets reset only type-specific modifiers.
func ExpectedChangedType(engine string, old sc.TypeUse, c ColumnChange) sc.TypeUse {
	result := old
	if c.Type != nil {
		result = ExpectedNewType(engine, *c.Type)
		if engine == "mysql" && result.Modifiers.Value != nil && old.Modifiers.Value != nil {
			result.Modifiers.Value.Unsigned = (c.Type.Kind == "integer" || c.Type.Kind == "bigint" || c.Type.Kind == "numeric") && old.Modifiers.Value.Unsigned
		}
	}
	if result.Modifiers.Value != nil {
		m := *result.Modifiers.Value
		result.Modifiers.Value = &m
		if c.Unsigned != nil {
			m.Unsigned = *c.Unsigned
		}
		if engine == "mysql" && (result.Ref.Name == "int" || result.Ref.Name == "bigint") {
			p := int64(10)
			if result.Ref.Name == "bigint" {
				p = 19
				if m.Unsigned {
					p = 20
				}
			}
			m.Precision = &p
		}
	}
	return result
}

func CanWidenColumn(b Baseline, c ColumnChange) bool {
	old, ok := FindColumn(b, c.Name)
	return ok && c.Type != nil && CanWiden(old, *c.Type)
}

func PostgresBuiltinIdentity(c sc.Column, attrs map[string]any) bool {
	if c.Type.Value == nil || c.Type.Value.Kind != "builtin" || c.Type.Value.Ref.Schema != "pg_catalog" {
		return false
	}
	expected := map[string]string{"int4": "23", "int8": "20", "numeric": "1700", "varchar": "1043", "text": "25", "bool": "16"}[c.Type.Value.Ref.Name]
	if expected == "" {
		return false
	}
	switch oid := attrs["atttypid"].(type) {
	case string:
		return oid == expected
	case float64:
		return strconv.FormatFloat(oid, 'f', -1, 64) == expected
	default:
		return false
	}
}
