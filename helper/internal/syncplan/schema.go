package syncplan

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"sort"
	"strings"

	sc "dbeer/helper/internal/schemacompare"
)

// SchemaOperation contains only immutable catalog facts. Source references are
// mapped to target names; expression text is deliberately never rewritten.
type SchemaOperation struct {
	Action         string
	Ref            sc.Ref
	Property       string
	Source, Target sc.Capture
}
type SchemaRenderer func(context.Context, SchemaOperation) (sql, manualReason string, err error)

type schemaCandidate struct {
	op          SchemaOperation
	manual      string
	destructive bool
	deps        map[string]bool
}

func schemaKey(r sc.Ref) string { b, _ := json.Marshal(r); return string(b) }

func mappedRef(r sc.Ref, m sc.Mappings) sc.Ref {
	original := r
	if r.Kind == "schema" {
		for _, p := range m.Schemas {
			if r.Name == p.Source {
				r.Name = p.Target
				return r
			}
		}
	}
	for _, p := range m.Tables {
		if r.Schema != p.Source.Schema {
			continue
		}
		if (r.Kind == "table" || r.Kind == "type" && r.RowType) && r.Name == p.Source.Name {
			r.Schema, r.Name = p.Target.Schema, p.Target.Name
			return r
		}
		if r.Table == p.Source.Name {
			r.Schema, r.Table = p.Target.Schema, p.Target.Name
			var pairs []sc.NamePair
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
					r.Name = n.Target
					break
				}
			}
			return r
		}
	}
	for _, p := range m.Types {
		if r.Kind == "type" && r.Schema == p.Source.Schema && r.Name == p.Source.Name {
			r.Schema, r.Name = p.Target.Schema, p.Target.Name
			return r
		}
	}
	for _, p := range m.Schemas {
		if original.Schema == p.Source {
			r.Schema = p.Target
			break
		}
	}
	return r
}

func mapSchemaValue(v reflect.Value, m sc.Mappings) {
	if !v.IsValid() {
		return
	}
	if v.Type() == reflect.TypeOf(sc.Ref{}) {
		v.Set(reflect.ValueOf(mappedRef(v.Interface().(sc.Ref), m)))
		return
	}
	switch v.Kind() {
	case reflect.Pointer:
		if !v.IsNil() {
			mapSchemaValue(v.Elem(), m)
		}
	case reflect.Struct:
		for i := 0; i < v.NumField(); i++ {
			mapSchemaValue(v.Field(i), m)
		}
	case reflect.Slice:
		for i := 0; i < v.Len(); i++ {
			mapSchemaValue(v.Index(i), m)
		}
	}
}

// Schema builds a bounded dependency-ordered plan without any server access.
// Unknown facts and transformations outside an adapter's generator stay manual.
func Schema(ctx context.Context, report sc.Report, render SchemaRenderer) (Plan, error) {
	plan := New("schema", report.Summary.Engine, report.Summary.ModelDigest)
	if render == nil || !DigestValid(plan.ModelDigest) || (plan.Engine != "postgresql" && plan.Engine != "mysql") || !report.Summary.Mappings.Valid() {
		return Plan{}, ErrInvalid
	}
	if len(report.Differences) > MaxSteps*16 {
		return Plan{}, ErrLimit
	}
	var source sc.Capture
	data, err := json.Marshal(report.Source)
	if err != nil {
		return Plan{}, err
	}
	if err = json.Unmarshal(data, &source); err != nil {
		return Plan{}, err
	}
	mapSchemaValue(reflect.ValueOf(&source).Elem(), report.Summary.Mappings)
	for i := range source.Inventories {
		for _, p := range report.Summary.Mappings.Schemas {
			if source.Inventories[i].Schema == p.Source {
				source.Inventories[i].Schema = p.Target
				break
			}
		}
	}
	entries := map[string]*schemaCandidate{}
	add := func(ref sc.Ref, action, property, reason string) *schemaCandidate {
		key := schemaKey(ref)
		if old := entries[key]; old != nil {
			if old.op.Property != property {
				old.op.Property = "*"
			}
			if reason != "" {
				old.manual = reason
			}
			return old
		}
		c := &schemaCandidate{op: SchemaOperation{action, ref, property, source, report.Target}, manual: reason, destructive: action == "drop" || action == "alter", deps: map[string]bool{}}
		entries[key] = c
		return c
	}
	for _, d := range report.Differences {
		if err := ctx.Err(); err != nil {
			return Plan{}, err
		}
		// Dependency edges are derived observations, not a SQL transformation.
		if strings.Contains(d.Property, ".dependencies") {
			continue
		}
		var ref sc.Ref
		if d.SourceRef != nil {
			ref = mappedRef(*d.SourceRef, report.Summary.Mappings)
		} else if d.TargetRef != nil {
			ref = *d.TargetRef
		} else {
			continue
		}
		action, reason := "alter", ""
		if d.Kind == "sourceOnly" {
			action = "create"
		}
		if d.Kind == "targetOnly" {
			action = "drop"
		}
		if d.Kind == "indeterminate" {
			reason = "Required captured metadata is incomplete or uncertain."
		}
		if ref.Kind == "schema" {
			for _, s := range source.Inventories {
				for _, t := range report.Target.Inventories {
					if s.Schema == ref.Name && t.Schema == ref.Name {
						if s.Existence == "present" && t.Existence == "absent" {
							action = "create"
						} else if s.Existence == "absent" && t.Existence == "present" {
							action = "drop"
						} else {
							reason = "Schema existence is uncertain."
						}
					}
				}
			}
		}
		add(ref, action, d.Property, reason)
	}
	// New table columns belong to its base CREATE. Constraints and indexes are
	// separate dependency units, so foreign keys can follow both base tables.
	for _, t := range source.Tables {
		c := entries[schemaKey(t.Ref)]
		if c == nil || c.op.Action != "create" {
			continue
		}
		for _, x := range t.Constraints.Items {
			add(x.Ref, "create", "*", "")
		}
		for _, x := range t.Indexes.Items {
			if x.Constraint.State == "known" && x.Constraint.Value != nil {
				continue
			}
			add(x.Ref, "create", "*", "")
		}
	}
	// A constraint owns its backing index. Never emit an independent operation
	// that might remove or duplicate the index underpinning a primary/unique key.
	for _, capture := range []sc.Capture{source, report.Target} {
		for _, t := range capture.Tables {
			for _, x := range t.Indexes.Items {
				if x.Constraint.Value == nil {
					continue
				}
				if c := entries[schemaKey(x.Ref)]; c != nil {
					constraint := entries[schemaKey(*x.Constraint.Value)]
					if constraint == nil {
						constraint = add(*x.Constraint.Value, c.op.Action, "*", "Backing-index changes require coordinated constraint replacement.")
					}
					if c.op.Action != "create" {
						constraint.manual = "Backing-index changes require coordinated constraint replacement."
					}
					delete(entries, schemaKey(x.Ref))
				}
			}
		}
	}
	if len(entries) > MaxSteps {
		return Plan{}, ErrLimit
	}
	// Resolve references to a creation unit, falling back from a member to its
	// newly-created parent table. External/unobserved dependencies stay manual.
	resolve := func(ref sc.Ref) string {
		if ref.Kind == "type" && ref.RowType {
			ref = sc.Ref{Kind: "table", Schema: ref.Schema, Name: ref.Name}
		}
		key := schemaKey(ref)
		if entries[key] != nil {
			return key
		}
		if ref.Table != "" {
			key = schemaKey(sc.Ref{Kind: "table", Schema: ref.Schema, Name: ref.Table})
			if entries[key] != nil && entries[key].op.Action == "create" {
				return key
			}
		}
		return ""
	}
	knownDependency := func(ref, owner sc.Ref) bool {
		if ref == owner {
			return true
		}
		if ref.Schema == "pg_catalog" && plan.Engine == "postgresql" {
			switch ref.Kind {
			case "type":
				return true
			case "collation":
				return ref.Name == "default" || ref.Name == "C" || ref.Name == "POSIX" || ref.Name == "ucs_basic"
			case "opclass":
				for _, name := range []string{"array_ops", "bit_ops", "bool_ops", "bpchar_ops", "bpchar_pattern_ops", "bytea_ops", "char_ops", "cidr_ops", "date_ops", "enum_ops", "float4_ops", "float8_ops", "inet_ops", "int2_ops", "int4_ops", "int8_ops", "interval_ops", "jsonb_ops", "jsonb_path_ops", "macaddr_ops", "macaddr8_ops", "money_ops", "multirange_ops", "name_ops", "numeric_ops", "oid_ops", "oidvector_ops", "range_ops", "record_ops", "text_ops", "text_pattern_ops", "time_ops", "timestamp_ops", "timestamptz_ops", "timetz_ops", "tsquery_ops", "tsvector_ops", "uuid_ops", "varbit_ops", "varchar_ops", "varchar_pattern_ops", "xid_ops", "xid8_ops"} {
					if ref.Name == name {
						return true
					}
				}
			}
		}
		if plan.Engine == "mysql" && ref.Schema == "" {
			if ref.Kind == "type" {
				return strings.ToLower(ref.Name) != "vector"
			}
			if ref.Kind == "collation" {
				// This baseline exists in both supported MySQL 8.0 and 8.4.
				for _, name := range []string{"binary", "ascii_bin", "ascii_general_ci", "latin1_bin", "latin1_general_ci", "latin1_swedish_ci", "utf8_bin", "utf8_general_ci", "utf8_unicode_ci", "utf8mb3_bin", "utf8mb3_general_ci", "utf8mb3_unicode_ci", "utf8mb4_bin", "utf8mb4_general_ci", "utf8mb4_unicode_ci", "utf8mb4_unicode_520_ci", "utf8mb4_0900_ai_ci", "utf8mb4_0900_as_ci", "utf8mb4_0900_as_cs"} {
					if ref.Name == name {
						return true
					}
				}
			}
		}
		if ref.Kind == "type" && ref.RowType {
			ref = sc.Ref{Kind: "table", Schema: ref.Schema, Name: ref.Name}
		}
		if ref.Kind == "type" {
			for _, typ := range report.Target.Types {
				if typ.Ref == ref {
					return SchemaFactsReason(typ) == ""
				}
			}
			return false
		}
		if ref.Kind == "schema" {
			for _, inv := range report.Target.Inventories {
				if inv.Schema == ref.Name && inv.Existence == "present" {
					return true
				}
			}
			return false
		}
		for _, table := range report.Target.Tables {
			if table.Ref == ref {
				return true
			}
			for _, col := range table.Columns.Items {
				if col.Ref == ref {
					return true
				}
			}
			for _, constraint := range table.Constraints.Items {
				if constraint.Ref == ref {
					return true
				}
			}
			for _, index := range table.Indexes.Items {
				if index.Ref == ref {
					return true
				}
			}
		}
		// A primary/unique constraint and its backing index form one unit.
		for _, table := range source.Tables {
			for _, index := range table.Indexes.Items {
				if index.Ref == ref && index.Constraint.Value != nil && *index.Constraint.Value == owner {
					return true
				}
			}
		}
		return false
	}
	for key, c := range entries {
		if c.op.Action == "drop" {
			c.manual = "Dependencies outside the captured scope may exist; review this removal manually. No CASCADE is generated."
		}
		if c.op.Ref.Table != "" {
			parent := resolve(sc.Ref{Kind: "table", Schema: c.op.Ref.Schema, Name: c.op.Ref.Table})
			if parent != "" && parent != key && entries[parent].op.Action == "create" {
				c.deps[parent] = true
			}
		}
		// MySQL's AFTER requires a preceding new column to exist even when the
		// reviewer selects only a subset of additions.
		if c.op.Action == "create" && c.op.Ref.Kind == "column" {
			column, found := SchemaColumn(source, c.op.Ref)
			if table, exists := SchemaTable(source, c.op.Ref); found && exists && column.Ordinal.Value != nil {
				for _, previous := range table.Columns.Items {
					if previous.Ordinal.Value != nil && *previous.Ordinal.Value == *column.Ordinal.Value-1 {
						dep := resolve(previous.Ref)
						if dep != "" && dep != key && entries[dep].op.Action == "create" {
							c.deps[dep] = true
						}
					}
				}
			}
		}
		if c.op.Action == "create" && c.op.Ref.Kind == "constraint" {
			if table, exists := SchemaTable(source, c.op.Ref); exists {
				for _, constraint := range table.Constraints.Items {
					if constraint.Ref == c.op.Ref && constraint.Target.Value != nil {
						if referenced, found := SchemaTable(source, *constraint.Target.Value); found {
							for _, unique := range referenced.Constraints.Items {
								if unique.Kind.Value != nil && (*unique.Kind.Value == "p" || *unique.Kind.Value == "u") {
									dep := resolve(unique.Ref)
									if dep != "" && dep != key {
										c.deps[dep] = true
									}
								}
							}
						}
					}
				}
			}
		}
		for _, inv := range source.Inventories {
			if inv.Schema != c.op.Ref.Schema {
				continue
			}
			parent := resolve(sc.Ref{Kind: "schema", Name: inv.Schema})
			if parent != "" && parent != key {
				c.deps[parent] = true
			}
		}
		for _, issue := range report.Issues {
			if !issue.BlocksEquality {
				continue
			}
			if issue.Ref == nil {
				c.manual = "Capture visibility or required metadata is incomplete."
				continue
			}
			ref := *issue.Ref
			if issue.Side == "source" {
				ref = mappedRef(ref, report.Summary.Mappings)
			}
			if ref == c.op.Ref || ref.Kind == "table" && c.op.Ref.Schema == ref.Schema && c.op.Ref.Table == ref.Name || c.op.Ref.Kind == "table" && ref.Schema == c.op.Ref.Schema && ref.Table == c.op.Ref.Name {
				c.manual = "Required captured metadata is unavailable; manual review is required."
			}
		}
		for _, t := range source.Tables {
			owned := t.Ref == c.op.Ref || c.op.Ref.Schema == t.Ref.Schema && c.op.Ref.Table == t.Ref.Name
			if !owned {
				continue
			}
			if !t.Dependencies.Complete || t.Dependencies.State != "known" {
				c.manual = "The captured dependency closure is incomplete."
			}
			for _, edge := range t.Dependencies.Items {
				// Base CREATE includes columns, while constraint/index ownership
				// edges point to separate later steps and must not form a cycle.
				if c.op.Ref.Kind == "table" && edge.From == c.op.Ref && edge.To.Schema == c.op.Ref.Schema && edge.To.Table == c.op.Ref.Name && (edge.To.Kind == "column" || edge.To.Kind == "constraint" || edge.To.Kind == "index") {
					continue
				}
				if edge.From != c.op.Ref && !(c.op.Ref.Kind == "table" && edge.From.Kind == "column" && edge.From.Table == t.Ref.Name) {
					continue
				}
				if edge.State != "observed" && edge.State != "known" {
					c.manual = "A required dependency is not fully observed."
				}
				if plan.Engine == "postgresql" && edge.To.Kind == "collation" && !reflect.DeepEqual(source.Context.EngineContext, report.Target.Context.EngineContext) {
					c.manual = "Database collation environments differ; collation-bearing operations require manual review."
				}
				dep := resolve(edge.To)
				if dep != "" && dep != key {
					c.deps[dep] = true
				} else if dep == "" && !knownDependency(edge.To, c.op.Ref) {
					c.manual = "A dependency is outside the captured target facts; its existence and definition require manual review."
				}
			}
		}
	}
	keys := make([]string, 0, len(entries))
	for key := range entries {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	ids := map[string]string{}
	emitted := map[string]bool{}
	bytesUsed := 0
	for len(emitted) < len(keys) {
		progress := false
		for _, key := range keys {
			if emitted[key] {
				continue
			}
			c := entries[key]
			ready := true
			for dep := range c.deps {
				if !emitted[dep] {
					ready = false
				}
			}
			if !ready {
				continue
			}
			deps := []string{}
			for dep := range c.deps {
				deps = append(deps, ids[dep])
				if entries[dep].manual != "" {
					c.manual = "A prerequisite requires manual work; review this operation after resolving it."
				}
			}
			sort.Strings(deps)
			path := []string{}
			if c.op.Ref.Schema != "" {
				path = append(path, displayPlanName(c.op.Ref.Schema, 1024))
			}
			if c.op.Ref.Table != "" {
				path = append(path, displayPlanName(c.op.Ref.Table, 1024))
			}
			path = append(path, displayPlanName(c.op.Ref.Name, 1024))
			step := Step{ID: fmt.Sprintf("schema-%d", len(plan.Steps)+1), Title: boundedPlanTitle(strings.ToUpper(c.op.Action[:1]) + c.op.Action[1:] + " " + c.op.Ref.Kind + " " + strings.Join(path, ".")), Destructive: c.destructive, DependsOn: deps}
			if c.manual == "" {
				step.SQL, c.manual, err = render(ctx, c.op)
				if err != nil {
					return Plan{}, err
				}
			}
			if c.manual != "" || strings.TrimSpace(step.SQL) == "" {
				if c.manual == "" {
					c.manual = "This transformation requires manual SQL."
				}
				step.Manual, step.Reason, step.SQL = true, c.manual, ""
			} else {
				step.Selected = !step.Destructive
				for dep := range c.deps {
					for _, previous := range plan.Steps {
						if previous.ID == ids[dep] && !previous.Selected {
							step.Selected = false
						}
					}
				}
			}
			encoded, encodeErr := json.Marshal(step)
			if encodeErr != nil {
				return Plan{}, ErrInvalid
			}
			bytesUsed += len(encoded) + 1
			if bytesUsed > MaxBytes {
				return Plan{}, ErrLimit
			}
			plan.Steps = append(plan.Steps, step)
			ids[key], emitted[key], progress = step.ID, true, true
		}
		if !progress {
			for _, key := range keys {
				if !emitted[key] {
					entries[key].manual = "Cyclic dependencies require a manually ordered migration."
					entries[key].deps = map[string]bool{}
				}
			}
		}
	}
	if err := plan.Validate(); err != nil {
		return Plan{}, err
	}
	return plan, nil
}
