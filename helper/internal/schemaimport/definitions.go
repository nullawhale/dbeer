package schemaimport

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"reflect"
	"sort"
	"strconv"
	"strings"

	"dbeer/helper/internal/schemabundle"
	sc "dbeer/helper/internal/schemacompare"
	sqlitedb "dbeer/helper/internal/sqlite"
)

func noBackslash(c sc.Capture) bool {
	if c.Context.EngineContext.Value != nil {
		for _, o := range *c.Context.EngineContext.Value {
			if strings.EqualFold(o.Name, "sqlMode") {
				for _, mode := range strings.Split(o.Value, ",") {
					if strings.EqualFold(strings.TrimSpace(mode), "NO_BACKSLASH_ESCAPES") {
						return true
					}
				}
			}
		}
	}
	return false
}
func manual(c *sc.Capture, ref sc.Ref, code string) {
	for i := range c.Tables {
		if c.Tables[i].Ref == ref {
			c.Tables[i].Dependencies = sc.Collection[sc.Dependency]{Items: c.Tables[i].Dependencies.Items, State: "unsupported", Code: code}
		}
	}
	for _, i := range c.Issues {
		if i.Code == code && i.Ref != nil && *i.Ref == ref {
			return
		}
	}
	c.Issues = append(c.Issues, sc.Issue{Ref: &ref, Property: "definition", Code: code, Message: "This historical definition contains properties the offline validator cannot independently establish. Review it manually.", BlocksEquality: true, Planning: "manual"})
}
func validateOwnership(c sc.Capture) error {
	seen := map[string]bool{}
	for _, table := range c.Tables {
		if table.Ref.Kind != "table" || !sc.ValidName(table.Ref.Schema) || !sc.ValidName(table.Ref.Name) || table.Ref.Table != "" || seen[refKey(table.Ref)] {
			return ErrInvalid
		}
		seen[refKey(table.Ref)] = true
		columns := map[string]bool{}
		for _, column := range table.Columns.Items {
			if column.Ref.Kind != "column" || column.Ref.Schema != table.Ref.Schema || column.Ref.Table != table.Ref.Name || !sc.ValidName(column.Ref.Name) || columns[column.Ref.Name] {
				return ErrInvalid
			}
			columns[column.Ref.Name] = true
		}
		constraints, indexes := map[string]bool{}, map[string]bool{}
		for _, k := range table.Constraints.Items {
			if constraints[k.Ref.Name] {
				return ErrInvalid
			}
			constraints[k.Ref.Name] = true
			if k.Ref.Kind != "constraint" || k.Ref.Schema != table.Ref.Schema || k.Ref.Table != table.Ref.Name || !sc.ValidName(k.Ref.Name) {
				return ErrInvalid
			}
			for _, col := range k.Columns.Items {
				if col.Kind != "column" || col.Schema != table.Ref.Schema || col.Table != table.Ref.Name || (!columns[col.Name] && !(c.Context.Engine == "mariadb" && mariaDBImplicitPeriodAddress(table, col.Name))) {
					return ErrInvalid
				}
			}
			for _, p := range k.ForeignKeys.Items {
				if p.Source.Kind != "column" || p.Source.Schema != table.Ref.Schema || p.Source.Table != table.Ref.Name || (!columns[p.Source.Name] && !(c.Context.Engine == "mariadb" && mariaDBImplicitPeriodAddress(table, p.Source.Name))) {
					return ErrInvalid
				}
			}
		}
		for _, index := range table.Indexes.Items {
			if indexes[index.Ref.Name] {
				return ErrInvalid
			}
			indexes[index.Ref.Name] = true
			if index.Ref.Kind != "index" || index.Ref.Schema != table.Ref.Schema || index.Ref.Table != table.Ref.Name || !sc.ValidName(index.Ref.Name) {
				return ErrInvalid
			}
			for _, key := range index.Keys.Items {
				if key.Column.Value != nil {
					r := *key.Column.Value
					if r.Kind != "column" || r.Schema != table.Ref.Schema || r.Table != table.Ref.Name || (!columns[r.Name] && !(c.Context.Engine == "mariadb" && mariaDBImplicitPeriodAddress(table, r.Name))) {
						return ErrInvalid
					}
				}
			}
			for _, r := range index.Includes.Items {
				if r.Kind != "column" || r.Schema != table.Ref.Schema || r.Table != table.Ref.Name || (!columns[r.Name] && !(c.Context.Engine == "mariadb" && mariaDBImplicitPeriodAddress(table, r.Name))) {
					return ErrInvalid
				}
			}
		}
		for _, k := range table.Constraints.Items {
			if k.BackingIndex.Value == nil {
				continue
			}
			found := false
			for _, x := range table.Indexes.Items {
				if x.Ref == *k.BackingIndex.Value {
					found = true
					if x.Constraint.Value == nil || *x.Constraint.Value != k.Ref {
						return ErrInvalid
					}
				}
			}
			if !found {
				return ErrInvalid
			}
		}
		for _, x := range table.Indexes.Items {
			if x.Constraint.Value == nil {
				continue
			}
			found := false
			for _, k := range table.Constraints.Items {
				if k.Ref == *x.Constraint.Value {
					found = true
					if k.BackingIndex.Value == nil || *k.BackingIndex.Value != x.Ref {
						return ErrInvalid
					}
					if len(k.Columns.Items) != len(x.Keys.Items) && !(c.Context.Engine == "mariadb" && mariaDBImplicitPrimarySuffix(table, k, len(x.Keys.Items))) {
						return ErrInvalid
					}
					for i, key := range x.Keys.Items {
						if key.Column.Value == nil || *key.Column.Value != k.Columns.Items[i] {
							return ErrInvalid
						}
					}
				}
			}
			if !found {
				return ErrInvalid
			}
		}
	}
	for _, typ := range c.Types {
		if typ.Ref.Kind != "type" || !sc.ValidName(typ.Ref.Name) || seen[refKey(typ.Ref)] {
			return ErrInvalid
		}
		seen[refKey(typ.Ref)] = true
	}
	for _, sequence := range c.Sequences {
		if sequence.Ref.Kind != "sequence" || !sc.ValidName(sequence.Ref.Name) || seen[refKey(sequence.Ref)] {
			return ErrInvalid
		}
		seen[refKey(sequence.Ref)] = true
	}
	if c.Context.Engine == "postgresql" {
		relations := map[string]bool{}
		for _, table := range c.Tables {
			relations[table.Ref.Schema+"\x00"+table.Ref.Name] = true
		}
		for _, sequence := range c.Sequences {
			key := sequence.Ref.Schema + "\x00" + sequence.Ref.Name
			if relations[key] {
				return ErrInvalid
			}
			relations[key] = true
		}
		for _, typ := range c.Types {
			if !typ.Ref.RowType && relations[typ.Ref.Schema+"\x00"+typ.Ref.Name] {
				return ErrInvalid
			}
		}
	}
	return nil
}

func defaultMatchesSQL(f sc.Fact[sc.Default], ts []token, engine string) bool {
	if f.State != "known" || f.Value == nil {
		return false
	}
	d := f.Value
	switch d.Kind {
	case "none":
		return len(ts) == 0
	case "sqlNull":
		return len(ts) == 1 && ts[0].is("NULL")
	case "expression":
		if d.Expression == nil {
			return false
		}
		parsed, e := lex(context.Background(), d.Expression.Text, engine, false)
		return e == nil && tokensSame(parsed, ts)
	case "literal":
		if d.Value == nil {
			return false
		}
		if engine == "mariadb" && d.Encoding == "base64" && len(ts) == 2 && ts[0].is("X") && ts[1].kind == 's' {
			expected, e := base64.StdEncoding.DecodeString(*d.Value)
			actual, e2 := hex.DecodeString(ts[1].value)
			return e == nil && e2 == nil && bytes.Equal(expected, actual)
		}
		if engine == "mariadb" && d.Encoding == "text" && d.Type != nil && d.Type.Ref.Name == "bit" && len(ts) == 2 && ts[0].is("B") && ts[1].kind == 's' {
			value, e := strconv.ParseUint(ts[1].value, 2, 64)
			return e == nil && strconv.FormatUint(value, 10) == *d.Value
		}
		if d.Encoding == "base64" {
			b, e := base64.StdEncoding.DecodeString(*d.Value)
			if e != nil || len(ts) < 1 || ts[0].kind != 's' {
				return false
			}
			actual := ts[0].value
			if !strings.HasPrefix(actual, "\\x") {
				return false
			}
			decoded, e := hex.DecodeString(actual[2:])
			return e == nil && bytes.Equal(b, decoded) && (len(ts) == 1 || len(ts) == 3 && ts[1].value == "::" && ts[2].is("BYTEA"))
		}
		if len(ts) == 1 && ts[0].kind == 's' {
			return ts[0].value == *d.Value
		}
		text, ok := numericText(ts)
		return ok && text == *d.Value
	case "sequence":
		if d.Sequence == nil {
			return false
		}
		quote := func(s string) string { return `"` + strings.ReplaceAll(s, `"`, `""`) + `"` }
		name := quote(d.Sequence.Name)
		if d.Sequence.Schema != "" {
			name = quote(d.Sequence.Schema) + "." + name
		}
		return len(ts) == 6 && ts[0].is("NEXTVAL") && ts[1].value == "(" && ts[2].kind == 's' && ts[2].value == name && ts[3].value == "::" && ts[4].is("REGCLASS") && ts[5].value == ")"
	}
	return false
}
func simpleOwnedStatement(stmt []token, ref sc.Ref, engine string) bool {
	c := cursor{ts: stmt, engine: engine}
	if c.take("COMMENT") {
		return validateOwnedStatement(stmt, ref, engine) == nil
	}
	if c.take("ALTER") {
		c.take("TABLE")
		if _, _, e := c.qualified(ref.Schema); e != nil || !c.take("ADD") {
			return false
		}
		_, _, e := parseConstraint(stmt[c.i:], ref, engine)
		return e == nil
	}
	_, e := parseStandaloneIndex(stmt, ref, engine)
	return e == nil
}
func removeOtherFacts(t *sc.Table, stmts [][]token, engine string) {
	constraints, indexes := map[string]bool{}, map[string]bool{}
	for _, stmt := range stmts {
		c := cursor{ts: stmt, engine: engine}
		if c.take("ALTER") {
			c.take("TABLE")
			c.qualified(t.Ref.Schema)
			c.take("ADD")
			if c.take("CONSTRAINT") {
				if name, e := c.ident(); e == nil {
					constraints[name] = true
				}
			}
		} else if c.take("COMMENT") && c.take("ON") && c.take("COLUMN") {
			if _, _, err := c.qualified(t.Ref.Schema); err == nil && c.take(".") {
				if name, err := c.ident(); err == nil {
					for i := range t.Columns.Items {
						if t.Columns.Items[i].Ref.Name == name {
							t.Columns.Items[i].Comment = sc.Known("")
						}
					}
				}
			}
		} else if c.take("CREATE") {
			c.take("UNIQUE")
			if c.take("INDEX") {
				if name, e := c.ident(); e == nil {
					indexes[name] = true
				}
			}
		}
	}
	kept := []sc.Constraint{}
	for _, k := range t.Constraints.Items {
		if !constraints[k.Ref.Name] {
			kept = append(kept, k)
		}
	}
	t.Constraints.Items = kept
	keptIndexes := []sc.Index{}
	for _, x := range t.Indexes.Items {
		if !indexes[x.Ref.Name] {
			keptIndexes = append(keptIndexes, x)
		}
	}
	t.Indexes.Items = keptIndexes
}
func importDefinitions(ctx context.Context, capture sc.Capture, manifest schemabundle.Manifest, files []SQLFile, render sc.DefinitionRenderer) (sc.Capture, int, error) {
	if err := validateOwnership(capture); err != nil {
		return sc.Capture{}, 0, err
	}
	if capture.Context.Engine == "sqlite" {
		return importSQLite(ctx, capture, manifest, files)
	}
	for _, object := range manifest.Objects {
		if object.State != "included" || object.Ref.Kind == "table" {
			continue
		}
		definition, e := render(ctx, capture, object.Ref)
		if e != nil {
			return sc.Capture{}, 0, e
		}
		ast, e := parseDefinition(ctx, definition.SQL, capture.Context.Engine, object.Ref.Schema, noBackslash(capture))
		if e != nil {
			return sc.Capture{}, 0, e
		}
		candidate := newObjectEdits()
		_, e = candidate.apply(ctx, SQLFile{Ref: &object.Ref, SQL: definition.SQL}, ast, capture, object.Ref.Schema, map[string]bool{})
		if e == ErrUnsupported {
			if e = validateOtherRoot(ast, object.Ref, capture.Context.Engine); e != nil {
				return sc.Capture{}, 0, e
			}
			manual(&capture, object.Ref, "offlineDefinitionUnproven")
		} else if e != nil {
			return sc.Capture{}, 0, e
		}
	}
	return importRelational(ctx, capture, manifest, files, render)
}
func importSQLite(ctx context.Context, original sc.Capture, manifest schemabundle.Manifest, files []SQLFile) (sc.Capture, int, error) {
	states := map[string]string{}
	for _, o := range manifest.Objects {
		states[refKey(o.Ref)] = o.State
	}
	definitions := []string{}
	unparsed := map[string]sc.Ref{}
	for _, file := range files {
		if err := ctx.Err(); err != nil {
			return sc.Capture{}, 0, err
		}
		if file.Ref != nil && states[refKey(*file.Ref)] != "included" {
			if file.Changed {
				return sc.Capture{}, 0, ErrUnsupported
			}
			unparsed[refKey(*file.Ref)] = *file.Ref
			continue
		}
		if file.Missing {
			continue
		}
		ast, err := parseDefinition(ctx, file.SQL, "sqlite", "main", false)
		if err != nil {
			return sc.Capture{}, 0, err
		}
		for _, table := range ast.tables {
			if table.ref.Schema != "main" {
				return sc.Capture{}, 0, ErrUnsupported
			}
		}
		for _, stmt := range ast.other {
			c := cursor{ts: stmt, engine: "sqlite"}
			c.take("CREATE")
			c.take("UNIQUE")
			if !c.take("INDEX") && !c.take("TRIGGER") {
				return sc.Capture{}, 0, ErrUnsupported
			}
		}
		definitions = append(definitions, file.SQL)
	}
	// Validate the original typed baseline against independently reconstructed
	// SQLite facts before applying edited membership. Removing a referenced
	// table can legitimately change dependency evidence in unchanged files.
	baselineDefinitions := []string{}
	for _, o := range manifest.Objects {
		if o.State == "included" {
			d, e := sqlitedb.RenderSchemaDefinition(ctx, original, o.Ref)
			if e != nil || d.Limited {
				return sc.Capture{}, 0, ErrInvalid
			}
			baselineDefinitions = append(baselineDefinitions, d.SQL)
		}
	}
	baseline, err := sqlitedb.ImportDefinitions(ctx, baselineDefinitions, sc.DefaultLimits())
	if err != nil {
		return sc.Capture{}, 0, err
	}
	baseline, err = schemabundle.Canonical(ctx, baseline)
	if err != nil {
		return sc.Capture{}, 0, err
	}
	for _, table := range original.Tables {
		if states[refKey(table.Ref)] != "included" {
			continue
		}
		found := false
		for _, parsed := range baseline.Tables {
			if parsed.Ref == table.Ref {
				found = true
				if !reflect.DeepEqual(parsed, table) {
					return sc.Capture{}, 0, ErrInvalid
				}
			}
		}
		if !found {
			return sc.Capture{}, 0, ErrInvalid
		}
	}
	fresh, err := sqlitedb.ImportDefinitions(ctx, definitions, sc.DefaultLimits())
	if err != nil {
		return sc.Capture{}, 0, err
	}
	fresh, err = schemabundle.Canonical(ctx, fresh)
	if err != nil {
		return sc.Capture{}, 0, err
	}

	count := 0
	for _, table := range original.Tables {
		if _, ok := unparsed[refKey(table.Ref)]; ok {
			fresh.Tables = append(fresh.Tables, table)
			manual(&fresh, table.Ref, "offlineDefinitionUnproven")
			count++
		}
	}
	// Keep the original capture's explicit limits and denied/missing inventory
	// observations. New facts never manufacture visibility of excluded objects.
	if len(fresh.Inventories) != 1 {
		return sc.Capture{}, 0, ErrInvalid
	}
	for _, i := range original.Inventories {
		if i.Schema == "main" {
			fresh.Inventories[0].Existence = i.Existence
			fresh.Inventories[0].Tables.Complete = i.Tables.Complete
			fresh.Inventories[0].Tables.State = i.Tables.State
			fresh.Inventories[0].Tables.Code = i.Tables.Code
		}
	}
	for _, table := range fresh.Tables {
		present := false
		for _, r := range fresh.Inventories[0].Tables.Items {
			if r == table.Ref {
				present = true
			}
		}
		if !present {
			fresh.Inventories[0].Tables.Items = append(fresh.Inventories[0].Tables.Items, table.Ref)
		}
	}
	for _, issue := range original.Issues {
		if issue.Ref == nil {
			fresh.Issues = append(fresh.Issues, issue)
		}
	}
	fresh.Context = original.Context
	return fresh, count, nil
}

func importRelational(ctx context.Context, original sc.Capture, manifest schemabundle.Manifest, files []SQLFile, render sc.DefinitionRenderer) (sc.Capture, int, error) {
	engine := original.Context.Engine
	result := original
	states := map[string]string{}
	for _, o := range manifest.Objects {
		states[refKey(o.Ref)] = o.State
	}
	edits := newObjectEdits()
	oldTables := map[string]sc.Table{}
	for _, t := range original.Tables {
		oldTables[refKey(t.Ref)] = t
	}
	remove := map[string]bool{}
	updates := map[string]sc.Table{}
	count := 0
	seenRoots := map[string]bool{}
	for _, file := range files {
		if err := ctx.Err(); err != nil {
			return sc.Capture{}, 0, err
		}
		if file.Ref != nil && states[refKey(*file.Ref)] != "included" {
			if file.Changed {
				return sc.Capture{}, 0, ErrUnsupported
			}
			if file.Ref.Kind != "schema" {
				manual(&result, *file.Ref, "offlineDefinitionUnproven")
				count++
			}
			continue
		}
		if file.Missing {
			if file.Ref == nil {
				return sc.Capture{}, 0, ErrUnsupported
			}
			if file.Ref.Kind == "table" {
				remove[refKey(*file.Ref)] = true
			} else if e := edits.remove(*file.Ref); e != nil {
				return sc.Capture{}, 0, e
			}
			continue
		}
		defaultSchema := ""
		if file.Ref != nil {
			defaultSchema = file.Ref.Schema
		}
		if defaultSchema == "" && len(manifest.Schemas) == 1 {
			defaultSchema = manifest.Schemas[0]
		}
		ast, err := parseDefinition(ctx, file.SQL, engine, defaultSchema, noBackslash(original))
		if err != nil {
			return sc.Capture{}, 0, err
		}
		if file.Ref != nil && file.Ref.Kind != "table" || len(ast.tables) == 0 && len(ast.other) > 0 {
			if len(ast.tables) > 0 {
				return sc.Capture{}, 0, ErrUnsupported
			}
			candidate := newObjectEdits()
			localSeen := map[string]bool{}
			for key, value := range seenRoots {
				localSeen[key] = value
			}
			_, e := candidate.apply(ctx, file, ast, original, defaultSchema, localSeen)
			if e != nil {
				if !file.Changed && file.Ref != nil && e == ErrUnsupported {
					if e = validateOtherRoot(ast, *file.Ref, engine); e != nil {
						return sc.Capture{}, 0, e
					}
					manual(&result, *file.Ref, "offlineDefinitionUnproven")
					count++
					continue
				}
				return sc.Capture{}, 0, e
			}
			for key, value := range candidate.types {
				edits.types[key] = value
			}
			for key, value := range candidate.sequences {
				edits.sequences[key] = value
			}
			for key, value := range candidate.removeTypes {
				edits.removeTypes[key] = value
			}
			for key, value := range candidate.removeSequences {
				edits.removeSequences[key] = value
			}
			seenRoots = localSeen
			continue
		}
		if file.Ref != nil && !file.Changed && (len(ast.tables) != 1 || ast.tables[0].ref != *file.Ref) {
			return sc.Capture{}, 0, ErrInvalid
		}
		if file.Ref != nil {
			remove[refKey(*file.Ref)] = true
		}
		if len(ast.tables) == 0 && len(ast.other) > 0 {
			return sc.Capture{}, 0, ErrUnsupported
		}
		for _, node := range ast.tables {
			key := refKey(node.ref)
			if seenRoots[key] {
				return sc.Capture{}, 0, ErrInvalid
			}
			seenRoots[key] = true
			var old *sc.Table
			var oldAST *tableAST
			if table, ok := oldTables[key]; ok {
				t := table
				old = &t
				definition, e := render(ctx, original, t.Ref)
				if e != nil {
					return sc.Capture{}, 0, e
				}
				parsed, e := parseDefinition(ctx, definition.SQL, engine, t.Ref.Schema, noBackslash(original))
				if e != nil || len(parsed.tables) != 1 {
					return sc.Capture{}, 0, ErrUnsupported
				}
				a := parsed.tables[0]
				a.statements = parsed.other
				oldAST = &a
				if file.Ref == nil || *file.Ref != table.Ref {
					return sc.Capture{}, 0, ErrInvalid
				}
			}
			changed := file.Changed
			table, limited, e := applyTableAST(ctx, node, oldAST, old, engine, changed)
			if e != nil {
				return sc.Capture{}, 0, e
			}
			// Separate statements must be independently classified and tied to
			// this root. Unmodelled changed statements never retain stale facts.
			if len(ast.other) > 0 {
				if oldAST == nil || !termsSame(oldAST.statements, ast.other) {
					if oldAST != nil {
						removeOtherFacts(&table, oldAST.statements, engine)
					}
					if e = applyOtherStatements(&table, ast.other, engine); e != nil {
						return sc.Capture{}, 0, e
					}
				} else {
					for _, stmt := range ast.other {
						if e = validateOwnedStatement(stmt, table.Ref, engine); e != nil {
							return sc.Capture{}, 0, e
						}
						if !simpleOwnedStatement(stmt, table.Ref, engine) {
							limited = true
						} else {
							independent := table
							independent.Constraints = sc.Complete[sc.Constraint](nil)
							independent.Indexes = sc.Complete[sc.Index](nil)
							if e = applyOtherStatements(&independent, [][]token{stmt}, engine); e != nil {
								return sc.Capture{}, 0, e
							}
							if !capturedOtherFactsMatch(table, independent) {
								limited = true
							}
						}
					}
				}
			}
			if len(ast.other) == 0 && oldAST != nil && len(oldAST.statements) > 0 && changed {
				removeOtherFacts(&table, oldAST.statements, engine)
			}
			completeIndexDefaults(&table, engine)
			if limited {
				table.Dependencies = sc.Collection[sc.Dependency]{Items: table.Dependencies.Items, State: "unsupported", Code: "offlineDefinitionUnproven"}
			}
			updates[key] = table
			if limited {
				manual(&result, table.Ref, "offlineDefinitionUnproven")
				count++
			}
		}
	}
	result.Tables = nil
	for _, table := range original.Tables {
		key := refKey(table.Ref)
		if replacement, ok := updates[key]; ok {
			result.Tables = append(result.Tables, replacement)
			delete(updates, key)
		} else if !remove[key] {
			result.Tables = append(result.Tables, table)
		}
	}
	for _, table := range updates {
		result.Tables = append(result.Tables, table)
	}
	edits.finish(&result)
	if e := resolveNamedTypes(&result); e != nil {
		return sc.Capture{}, 0, e
	}
	// Rebuild only table membership; retained type inventories remain historical.
	bySchema := map[string][]sc.Ref{}
	for _, table := range result.Tables {
		bySchema[table.Ref.Schema] = append(bySchema[table.Ref.Schema], table.Ref)
	}
	for i := range result.Inventories {
		refs := bySchema[result.Inventories[i].Schema]
		if refs == nil {
			refs = []sc.Ref{}
		}
		result.Inventories[i].Tables.Items = refs
		delete(bySchema, result.Inventories[i].Schema)
	}
	for schema, refs := range bySchema {
		if !sc.ValidName(schema) || len(result.Inventories) >= 32 {
			return sc.Capture{}, 0, ErrLimit
		}
		result.Inventories = append(result.Inventories, sc.Inventory{Schema: schema, Existence: "present", Tables: sc.Complete(refs), Types: sc.Complete[sc.Ref](nil)})
	}
	// Apply manual markers after replacing edited objects.
	for _, file := range files {
		if file.Ref == nil {
			continue
		}
		for _, issue := range result.Issues {
			if issue.Code == "offlineDefinitionUnproven" && issue.Ref != nil && *issue.Ref == *file.Ref {
				manual(&result, *file.Ref, issue.Code)
			}
		}
	}
	if err := validateOwnership(result); err != nil {
		return sc.Capture{}, 0, err
	}
	return result, count, nil
}

func validateOtherRoot(ast definitionAST, ref sc.Ref, engine string) error {
	if len(ast.tables) != 0 || len(ast.other) == 0 {
		return ErrInvalid
	}
	for _, stmt := range ast.other {
		c := cursor{ts: stmt, engine: engine}
		if c.take("COMMENT") {
			continue
		}
		if !c.take("CREATE") || !c.take(asciiUpper(ref.Kind)) {
			return ErrUnsupported
		}
		schema, name, e := c.qualified(ref.Schema)
		if e != nil || schema != ref.Schema || name != ref.Name {
			return ErrInvalid
		}
	}
	return nil
}
func validateOwnedStatement(stmt []token, ref sc.Ref, engine string) error {
	c := cursor{ts: stmt, engine: engine}
	if c.take("COMMENT") && c.take("ON") {
		column := c.take("COLUMN")
		if !column && !c.take("TABLE") {
			return ErrUnsupported
		}
		schema, name, e := c.qualified(ref.Schema)
		if e != nil || schema != ref.Schema || name != ref.Name {
			return ErrInvalid
		}
		if column {
			if !c.take(".") {
				return ErrUnsupported
			}
			if _, e = c.ident(); e != nil {
				return e
			}
		}
		if !c.take("IS") || c.i+1 != len(stmt) || stmt[c.i].kind != 's' {
			return ErrUnsupported
		}
		return nil
	}
	if c.take("ALTER") && c.take("TABLE") {
		schema, name, e := c.qualified(ref.Schema)
		if e != nil || schema != ref.Schema || name != ref.Name || !c.take("ADD") {
			return ErrInvalid
		}
		return validateMemberTokens(stmt[c.i:], engine)
	}
	if c.take("CREATE") {
		c.take("UNIQUE")
		if !c.take("INDEX") {
			return ErrUnsupported
		}
		if _, e := c.ident(); e != nil {
			return e
		}
		if !c.take("ON") {
			return ErrUnsupported
		}
		schema, name, e := c.qualified(ref.Schema)
		if e != nil || schema != ref.Schema || name != ref.Name {
			return ErrInvalid
		}
		return nil
	}
	return ErrUnsupported
}
func validateMemberTokens(ts []token, engine string) error {
	_, _, e := parseConstraint(ts, sc.Ref{Kind: "table", Schema: "scope", Name: "scope"}, engine)
	return e
}

func oldColumnAST(table *tableAST, name string) *columnAST {
	if table != nil {
		for _, c := range table.columns {
			if c.name == name {
				v := c
				return &v
			}
		}
	}
	return nil
}
func applyTableAST(ctx context.Context, ast tableAST, previous *tableAST, original *sc.Table, engine string, changed bool) (sc.Table, bool, error) {
	table := sc.Table{Ref: ast.ref, Kind: sc.Known("r"), Storage: sc.Known("p"), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Options: sc.Complete[sc.Option](nil), Columns: sc.Complete[sc.Column](nil), Constraints: sc.Complete[sc.Constraint](nil), Indexes: sc.Complete[sc.Index](nil), Dependencies: sc.Complete[sc.Dependency](nil)}
	if engine == "mysql" || engine == "mariadb" {
		table.Kind = sc.Known("table")
		table.Storage = sc.Unknown[string]("offlineDefaultEngine")
		table.Charset = sc.Unknown[string]("offlineDefaultCharset")
		table.Collation = sc.Unknown[sc.Ref]("offlineDefaultCollation")
	}
	if original != nil {
		table = *original
		table.Columns = sc.Complete[sc.Column](nil)
		if engine == "postgresql" && (original.Storage.Value == nil || (*original.Storage.Value == "u") != ast.unlogged) {
			return table, false, ErrUnsupported
		}
	} else if ast.unlogged {
		table.Storage = sc.Known("u")
	}
	limited := false
	if original != nil && previous != nil {
		unproven, e := validateTableBaseline(*original, *previous, engine)
		if e != nil {
			return table, false, e
		}
		limited = unproven
	}
	if previous != nil && !tokensSame(previous.suffix, ast.suffix) {
		return table, false, ErrUnsupported
	}
	if original == nil {
		if e := applyTableSuffix(&table, ast.suffix, engine); e != nil {
			return table, false, e
		}
	}
	for ordinal, columnAST := range ast.columns {
		if e := ctx.Err(); e != nil {
			return table, false, e
		}
		var old *sc.Column
		if original != nil {
			for _, c := range original.Columns.Items {
				if c.Ref.Name == columnAST.name {
					v := c
					old = &v
					break
				}
			}
		}
		before := oldColumnAST(previous, columnAST.name)
		column, manual, e := applyColumnAST(columnAST, before, old, ast.ref, ordinal, engine)
		if old == nil || before == nil || !tokensSame(columnAST.typ, before.typ) || !tokensSame(columnAST.attrs["charset"], before.attrs["charset"]) || !tokensSame(columnAST.attrs["collation"], before.attrs["collation"]) {
			inheritColumnProperties(&column, table, columnAST, engine)
			manual = manual || column.Charset.State == "unsupported" || column.Collation.State == "unsupported"
		}
		if e != nil {
			return table, false, e
		}
		limited = limited || manual
		table.Columns.Items = append(table.Columns.Items, column)
	}
	if engine == "mariadb" && original == nil {
		if e := mariaDBTableProperties(&table, ast); e != nil {
			return table, false, e
		}
	}
	if original != nil && previous != nil && termsSame(previous.members, ast.members) {
		if e := validateCapturedMembers(table, ast.members, engine); e != nil {
			if e != ErrUnsupported {
				return table, false, e
			}
			limited = true
		}
	} else {
		table.Constraints = sc.Complete[sc.Constraint](nil)
		table.Indexes = sc.Complete[sc.Index](nil)
		for _, term := range ast.members {
			constraint, index, e := parseConstraint(term, ast.ref, engine)
			if e != nil {
				return table, false, e
			}
			if constraint != nil {
				table.Constraints.Items = append(table.Constraints.Items, *constraint)
			}
			if index != nil {
				table.Indexes.Items = append(table.Indexes.Items, *index)
			}
		}
	}
	if engine == "mariadb" && original == nil {
		for i := range table.Constraints.Items {
			k := &table.Constraints.Items[i]
			for j := range table.Indexes.Items {
				x := &table.Indexes.Items[j]
				if k.BackingIndex.Value != nil && x.Ref == *k.BackingIndex.Value {
					mariaDBImplicitPrimary(&table, k, x)
				}
			}
		}
	}
	if limited {
		table.Dependencies = sc.Collection[sc.Dependency]{Items: table.Dependencies.Items, State: "unsupported", Code: "offlineDefinitionUnproven"}
	}
	return table, limited, nil
}
func termsSame(a, b [][]token) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if !tokensSame(a[i], b[i]) {
			return false
		}
	}
	return true
}
func applyColumnAST(ast columnAST, before *columnAST, old *sc.Column, table sc.Ref, ordinal int, engine string) (sc.Column, bool, error) {
	c := sc.Column{Ref: sc.Ref{Kind: "column", Schema: table.Schema, Table: table.Name, Name: ast.name}, Ordinal: sc.Known(ordinal), Nullable: sc.Known(true), Default: sc.Known(sc.Default{Kind: "none"}), Generated: sc.Known(sc.Generated{Kind: "none"}), Identity: sc.Known(sc.Identity{Kind: "none"}), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Visible: sc.Known(true), Comment: sc.Known(""), OnUpdate: sc.Absent[sc.Expression]()}
	if old != nil {
		c = *old
		c.Ordinal = sc.Known(ordinal)
	}
	if engine == "mariadb" && before != nil && (!tokensSame(ast.attrs["systemPeriod"], before.attrs["systemPeriod"]) || !tokensSame(ast.attrs["versioning"], before.attrs["versioning"])) {
		return c, false, ErrUnsupported
	}
	limited := false
	if old != nil && before != nil {
		unproven, e := validateColumnBaseline(*old, *before, engine)
		if e != nil {
			return c, false, e
		}
		limited = unproven
	}
	if !ast.supported {
		if old == nil || before == nil || !tokensSame(ast.raw, before.raw) {
			return c, false, ErrUnsupported
		}
		return c, true, nil
	}
	parsedType, e := builtinType(ast.typ, engine)
	if e != nil {
		parsedType, e = namedType(ast.typ, engine)
	}
	if e != nil {
		if old == nil || before == nil || !tokensSame(ast.typ, before.typ) {
			return c, false, e
		}
		return c, true, nil
	}
	typeChanged := before == nil || !tokensSame(ast.typ, before.typ)
	if !typeChanged && old != nil {
		if old.Type.Value == nil || old.Type.Value.Ref != parsedType.Ref || parsedType.Kind != "offlineNamed" && old.Type.Value.Kind != parsedType.Kind {
			return c, false, ErrInvalid
		}
	} else {
		c.Type = sc.Known(parsedType)
		if old != nil && (old.Collation.Value != nil || old.Charset.Value != nil) {
			return c, false, ErrUnsupported
		}
		if c.Default.Value != nil && c.Default.Value.Kind == "literal" && c.Default.Value.Type != nil {
			copyDefault := *c.Default.Value
			copyDefault.Type = &parsedType
			c.Default = sc.Known(copyDefault)
		}
	}
	for _, name := range []string{"nullable", "default", "charset", "collation", "comment", "identity", "visible", "systemPeriod"} {
		ts := ast.attrs[name]
		unchanged := before != nil && tokensSame(ts, before.attrs[name])
		if unchanged {
			continue
		}
		switch name {
		case "systemPeriod":
			if len(ts) == 0 {
				continue
			}
			if engine != "mariadb" {
				return c, false, ErrUnsupported
			}
			if role := mariaDBPeriodRole(ast); role != "" {
				c.Generated = sc.Known(sc.Generated{Kind: role})
				if len(ast.attrs["nullable"]) == 0 {
					c.Nullable = sc.Known(false)
				}
			}
		case "nullable":
			c.Nullable = sc.Known(len(ts) == 0 || !ts[0].is("NOT"))
		case "default":
			d, e := pureDefault(ts, engine)
			if e != nil {
				return c, false, e
			}
			if d.Kind == "literal" && (engine == "mysql" || engine == "mariadb") {
				u := parsedType
				d.Type = &u
			}
			c.Default = sc.Known(d)
		case "charset":
			if len(ts) == 0 {
				c.Charset = sc.Absent[string]()
			} else {
				value, ok := ts[0].identifier(engine)
				if !ok {
					return c, false, ErrUnsupported
				}
				c.Charset = sc.Known(value)
			}
		case "collation":
			if len(ts) == 0 {
				c.Collation = sc.Absent[sc.Ref]()
				c.CollationProperties = nil
			} else {
				p := cursor{ts: ts, engine: engine}
				schema, name, e := p.qualified("")
				if e != nil || p.i != len(ts) {
					return c, false, ErrUnsupported
				}
				c.Collation = sc.Known(sc.Ref{Kind: "collation", Schema: schema, Name: name})
				c.CollationProperties = nil
			}
		case "comment":
			value := ""
			if len(ts) > 0 {
				value = ts[0].value
			}
			c.Comment = sc.Known(value)
		case "identity":
			kind := "none"
			if len(ts) > 0 {
				if engine != "mysql" && engine != "mariadb" {
					return c, false, ErrUnsupported
				}
				kind = "autoIncrement"
			}
			c.Identity = sc.Known(sc.Identity{Kind: kind})
		case "visible":
			c.Visible = sc.Known(len(ts) == 0 || !ts[0].is("INVISIBLE"))
		}
	}
	return c, limited, nil
}
func applyTableSuffix(t *sc.Table, ts []token, engine string) error {
	if engine == "postgresql" {
		if len(ts) > 0 {
			return ErrUnsupported
		}
		return nil
	}
	c := cursor{ts: ts, engine: engine}
	for c.i < len(ts) {
		if c.take("ENGINE") {
			c.take("=")
			name, e := c.ident()
			if e != nil {
				return ErrUnsupported
			}
			if engine == "mariadb" {
				switch strings.ToLower(name) {
				case "innodb":
					name = "InnoDB"
				case "aria":
					name = "Aria"
				case "myisam":
					name = "MyISAM"
				default:
					return ErrUnsupported
				}
				t.Storage = sc.Known(name)
			} else {
				if !strings.EqualFold(name, "InnoDB") {
					return ErrUnsupported
				}
				t.Storage = sc.Known("InnoDB")
			}
		} else if c.take("DEFAULT") {
			if !c.take("CHARACTER") || !c.take("SET") {
				return ErrUnsupported
			}
			c.take("=")
			name, e := c.ident()
			if e != nil {
				return e
			}
			t.Charset = sc.Known(name)
		} else if c.take("CHARSET") {
			c.take("=")
			name, e := c.ident()
			if e != nil {
				return e
			}
			t.Charset = sc.Known(name)
		} else if c.take("COLLATE") {
			c.take("=")
			name, e := c.ident()
			if e != nil {
				return e
			}
			t.Collation = sc.Known(sc.Ref{Kind: "collation", Name: name})
		} else if c.take("COMMENT") {
			c.take("=")
			if c.i >= len(ts) || ts[c.i].kind != 's' {
				return ErrUnsupported
			}
			t.Options.Items = append(t.Options.Items, sc.Option{Name: "comment", Value: ts[c.i].value})
			c.i++
		} else if engine == "mariadb" && c.take("WITH") {
			if !c.take("SYSTEM") || !c.take("VERSIONING") {
				return ErrUnsupported
			}
			t.Kind = sc.Known("systemVersioned")
		} else if c.take("ROW_FORMAT") {
			c.take("=")
			name, e := c.ident()
			if e != nil {
				return e
			}
			name = asciiUpper(name)
			if name != "DEFAULT" && name != "DYNAMIC" && name != "FIXED" && name != "COMPRESSED" && name != "REDUNDANT" && name != "COMPACT" {
				return ErrUnsupported
			}
			t.Options.Items = append(t.Options.Items, sc.Option{Name: "row_format", Value: name})
		} else {
			return ErrUnsupported
		}
	}
	return nil
}
func validateCapturedMembers(t sc.Table, members [][]token, engine string) error {
	seen := map[string]bool{}
	for _, term := range members {
		constraint, index, e := parseConstraint(term, t.Ref, engine)
		if e != nil {
			return e
		}
		if engine == "mariadb" && constraint != nil && index != nil {
			mariaDBImplicitPrimary(&t, constraint, index)
		}
		if constraint != nil {
			found := false
			for _, old := range t.Constraints.Items {
				if old.Ref == constraint.Ref {
					found = true
					if old.Kind.Value == nil || constraint.Kind.Value == nil || *old.Kind.Value != *constraint.Kind.Value || !reflect.DeepEqual(old.Columns.Items, constraint.Columns.Items) {
						return ErrInvalid
					}
					if constraint.Target.Value != nil && (!reflect.DeepEqual(old.Target, constraint.Target) || !reflect.DeepEqual(old.ForeignKeys.Items, constraint.ForeignKeys.Items)) {
						return ErrInvalid
					}
					a, b := old, *constraint
					a.BackingIndex = sc.Absent[sc.Ref]()
					b.BackingIndex = sc.Absent[sc.Ref]()
					if (engine == "mysql" || engine == "mariadb") && (b.Kind.Value != nil && (*b.Kind.Value == "p" || *b.Kind.Value == "u")) {
						b.NullsDistinct = sc.Known(true)
					}
					if !sameJSON(a, b) {
						return ErrUnsupported
					}
					if old.BackingIndex.Value != nil && !(engine == "mariadb" && index != nil && *old.BackingIndex.Value == index.Ref) {
						return ErrUnsupported
					}
				}
			}
			if !found {
				return ErrInvalid
			}
			seen[refKey(constraint.Ref)] = true
		}
		if index != nil {
			found := false
			for _, old := range t.Indexes.Items {
				if old.Ref == index.Ref {
					found = true
					if old.Unique.Value == nil || *old.Unique.Value != *index.Unique.Value || len(old.Keys.Items) != len(index.Keys.Items) {
						return ErrInvalid
					}
					for i := range old.Keys.Items {
						if !reflect.DeepEqual(old.Keys.Items[i].Column, index.Keys.Items[i].Column) {
							return ErrInvalid
						}
					}
					if !sameJSON(old, *index) {
						return ErrUnsupported
					}
				}
			}
			if !found {
				return ErrInvalid
			}
			seen[refKey(index.Ref)] = true
		}
	}
	for _, k := range t.Constraints.Items {
		if k.Kind.Value != nil && *k.Kind.Value != "f" && !seen[refKey(k.Ref)] {
			return ErrInvalid
		}
	}
	return nil
}

func applyOtherStatements(t *sc.Table, stmts [][]token, engine string) error {
	for _, stmt := range stmts {
		if e := validateOwnedStatement(stmt, t.Ref, engine); e != nil {
			return e
		}
		c := cursor{ts: stmt, engine: engine}
		if c.take("ALTER") {
			c.take("TABLE")
			c.qualified(t.Ref.Schema)
			c.take("ADD")
			constraint, index, e := parseConstraint(stmt[c.i:], t.Ref, engine)
			if e != nil {
				return e
			}
			if constraint != nil {
				replaceConstraint(t, *constraint)
			}
			if index != nil {
				replaceIndex(t, *index)
			}
		} else if c.take("CREATE") {
			index, e := parseStandaloneIndex(stmt, t.Ref, engine)
			if e != nil {
				return e
			}
			replaceIndex(t, index)
		} else if c.take("COMMENT") && c.take("ON") {
			if !c.take("COLUMN") {
				return ErrUnsupported
			}
			schema, owner, e := c.qualified(t.Ref.Schema)
			if e != nil || schema != t.Ref.Schema || owner != t.Ref.Name || !c.take(".") {
				return ErrInvalid
			}
			name, e := c.ident()
			if e != nil || !c.take("IS") || c.i+1 != len(stmt) || stmt[c.i].kind != 's' {
				return ErrUnsupported
			}
			found := false
			for i := range t.Columns.Items {
				if t.Columns.Items[i].Ref.Name == name {
					t.Columns.Items[i].Comment = sc.Known(stmt[c.i].value)
					found = true
				}
			}
			if !found {
				return ErrInvalid
			}
		} else {
			return ErrUnsupported
		}
	}
	return nil
}
func replaceConstraint(t *sc.Table, c sc.Constraint) {
	for i := range t.Constraints.Items {
		if t.Constraints.Items[i].Ref == c.Ref {
			t.Constraints.Items[i] = c
			return
		}
	}
	t.Constraints.Items = append(t.Constraints.Items, c)
}
func replaceIndex(t *sc.Table, x sc.Index) {
	for i := range t.Indexes.Items {
		if t.Indexes.Items[i].Ref == x.Ref {
			t.Indexes.Items[i] = x
			return
		}
	}
	t.Indexes.Items = append(t.Indexes.Items, x)
}

func columnList(c *cursor, table sc.Ref) ([]sc.Ref, error) {
	group, e := c.group()
	if e != nil {
		return nil, e
	}
	parts, e := commaTerms(group)
	if e != nil || len(parts) == 0 || len(parts) > 32 {
		return nil, ErrUnsupported
	}
	out := []sc.Ref{}
	seen := map[string]bool{}
	for _, p := range parts {
		q := cursor{ts: p, engine: c.engine}
		name, e := q.ident()
		if e != nil || q.i != len(p) || seen[name] {
			return nil, ErrUnsupported
		}
		seen[name] = true
		out = append(out, sc.Ref{Kind: "column", Schema: table.Schema, Table: table.Name, Name: name})
	}
	return out, nil
}
func parseConstraint(ts []token, table sc.Ref, engine string) (*sc.Constraint, *sc.Index, error) {
	c := cursor{ts: ts, engine: engine}
	if engine == "mariadb" && c.take("PERIOD") {
		if !c.take("FOR") || !c.take("SYSTEM_TIME") {
			return nil, nil, ErrUnsupported
		}
		columns, e := columnList(&c, table)
		if e != nil || len(columns) != 2 || c.i != len(ts) {
			return nil, nil, ErrUnsupported
		}
		return nil, nil, nil
	}
	name := ""
	if c.take("CONSTRAINT") {
		var e error
		name, e = c.ident()
		if e != nil {
			return nil, nil, e
		}
	}
	kind := ""
	unique := false
	if c.take("PRIMARY") {
		if !c.take("KEY") {
			return nil, nil, ErrUnsupported
		}
		kind = "p"
		if name == "" {
			if engine == "mysql" || engine == "mariadb" {
				name = "PRIMARY"
			} else {
				return nil, nil, ErrUnsupported
			}
		}
	} else if c.take("UNIQUE") {
		unique = true
		if c.take("KEY") || c.take("INDEX") {
			if name == "" {
				var e error
				name, e = c.ident()
				if e != nil {
					return nil, nil, e
				}
			}
			return parseInlineIndex(&c, table, name, true)
		}
		kind = "u"
	} else if c.take("FOREIGN") {
		if !c.take("KEY") {
			return nil, nil, ErrUnsupported
		}
		kind = "f"
	} else if c.take("CHECK") {
		return nil, nil, ErrUnsupported
	} else if c.take("KEY") || c.take("INDEX") {
		if name != "" {
			return nil, nil, ErrUnsupported
		}
		var e error
		name, e = c.ident()
		if e != nil {
			return nil, nil, e
		}
		return parseInlineIndex(&c, table, name, unique)
	} else {
		return nil, nil, ErrUnsupported
	}
	if name == "" {
		return nil, nil, ErrUnsupported
	}
	constraint := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: table.Schema, Table: table.Name, Name: name}, kind)
	if engine == "mariadb" && (kind == "p" || kind == "u") {
		index, e := mariaDBIndex(&c, table, name, true)
		if e != nil {
			return nil, nil, e
		}
		for _, key := range index.Keys.Items {
			if key.Column.Value == nil {
				return nil, nil, ErrUnsupported
			}
			constraint.Columns.Items = append(constraint.Columns.Items, *key.Column.Value)
		}
		constraint.BackingIndex = sc.Known(index.Ref)
		constraint.NullsDistinct = sc.Known(true)
		index.Constraint = sc.Known(constraint.Ref)
		return &constraint, index, nil
	}

	columns, e := columnList(&c, table)
	if e != nil {
		return nil, nil, e
	}
	constraint.Columns = sc.Complete(columns)
	if kind == "f" {
		if !c.take("REFERENCES") {
			return nil, nil, ErrUnsupported
		}
		schema, target, e := c.qualified(table.Schema)
		if e != nil {
			return nil, nil, e
		}
		ref := sc.Ref{Kind: "table", Schema: schema, Name: target}
		constraint.Target = sc.Known(ref)
		targetCols, e := columnList(&c, ref)
		if e != nil || len(columns) != len(targetCols) {
			return nil, nil, ErrUnsupported
		}
		pairs := []sc.ColumnPair{}
		for i := range columns {
			pairs = append(pairs, sc.ColumnPair{Source: columns[i], Target: targetCols[i]})
		}
		constraint.ForeignKeys = sc.Complete(pairs)
		constraint.Update = sc.Known("NO ACTION")
		constraint.Delete = sc.Known("NO ACTION")
		constraint.Match = sc.Known("NONE")
		if engine == "postgresql" {
			constraint.Update = sc.Known("a")
			constraint.Delete = sc.Known("a")
			constraint.Match = sc.Known("s")
		}
	}
	for c.i < len(ts) {
		if c.take("ON") {
			update := c.take("UPDATE")
			if !update && !c.take("DELETE") {
				return nil, nil, ErrUnsupported
			}
			action := ""
			if c.take("CASCADE") {
				action = "CASCADE"
			} else if c.take("RESTRICT") {
				action = "RESTRICT"
			} else if c.take("NO") && c.take("ACTION") {
				action = "NO ACTION"
			} else if c.take("SET") {
				if c.take("NULL") {
					action = "SET NULL"
				} else if c.take("DEFAULT") {
					action = "SET DEFAULT"
				} else {
					return nil, nil, ErrUnsupported
				}
			} else {
				return nil, nil, ErrUnsupported
			}
			if engine == "postgresql" {
				action = map[string]string{"NO ACTION": "a", "RESTRICT": "r", "CASCADE": "c", "SET NULL": "n", "SET DEFAULT": "d"}[action]
			}
			if update {
				constraint.Update = sc.Known(action)
			} else {
				constraint.Delete = sc.Known(action)
			}
		} else if c.take("MATCH") {
			if c.take("SIMPLE") {
				v := "SIMPLE"
				if engine == "postgresql" {
					v = "s"
				}
				constraint.Match = sc.Known(v)
			} else if c.take("FULL") {
				v := "FULL"
				if engine == "postgresql" {
					v = "f"
				}
				constraint.Match = sc.Known(v)
			} else {
				return nil, nil, ErrUnsupported
			}
		} else if c.take("DEFERRABLE") {
			constraint.Deferrable = sc.Known(true)
		} else if c.take("INITIALLY") {
			if c.take("DEFERRED") {
				constraint.InitiallyDeferred = sc.Known(true)
			} else if !c.take("IMMEDIATE") {
				return nil, nil, ErrUnsupported
			}
		} else if c.take("NOT") {
			if c.take("DEFERRABLE") {
				constraint.Deferrable = sc.Known(false)
			} else if c.take("VALID") {
				constraint.Validated = sc.Known(false)
			} else if c.take("ENFORCED") {
				constraint.Enforced = sc.Known(false)
			} else {
				return nil, nil, ErrUnsupported
			}
		} else if c.take("ENFORCED") {
			constraint.Enforced = sc.Known(true)
		} else {
			return nil, nil, ErrUnsupported
		}
	}
	if kind == "p" || kind == "u" {
		index := simpleIndex(table, name, columns, true)
		index.Constraint = sc.Known(constraint.Ref)
		constraint.BackingIndex = sc.Known(index.Ref)
		if engine == "mysql" || engine == "mariadb" {
			constraint.NullsDistinct = sc.Known(true)
			for i := range index.Keys.Items {
				index.Keys.Items[i].NullsFirst = sc.Known(true)
			}
		}
		if engine == "postgresql" {
			for i := range index.Keys.Items {
				index.Keys.Items[i].Opclass = sc.Unknown[sc.Ref]("offlineDefaultOpclass")
			}
		}
		return &constraint, &index, nil
	}
	return &constraint, nil, nil
}
func parseInlineIndex(c *cursor, table sc.Ref, name string, unique bool) (*sc.Constraint, *sc.Index, error) {
	if c.engine == "mariadb" {
		index, e := mariaDBIndex(c, table, name, unique)
		if e != nil {
			return nil, nil, e
		}
		if unique {
			constraint := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: table.Schema, Table: table.Name, Name: name}, "u")
			for _, key := range index.Keys.Items {
				if key.Column.Value == nil {
					return nil, nil, ErrUnsupported
				}
				constraint.Columns.Items = append(constraint.Columns.Items, *key.Column.Value)
			}
			constraint.BackingIndex = sc.Known(index.Ref)
			constraint.NullsDistinct = sc.Known(true)
			index.Constraint = sc.Known(constraint.Ref)
			return &constraint, index, nil
		}
		return nil, index, nil
	}

	columns, e := columnList(c, table)
	if e != nil || c.i != len(c.ts) {
		return nil, nil, ErrUnsupported
	}
	index := simpleIndex(table, name, columns, unique)
	if c.engine == "mysql" || c.engine == "mariadb" {
		for i := range index.Keys.Items {
			index.Keys.Items[i].NullsFirst = sc.Known(true)
		}
	}
	if c.engine == "postgresql" {
		for i := range index.Keys.Items {
			index.Keys.Items[i].Opclass = sc.Unknown[sc.Ref]("offlineDefaultOpclass")
		}
	}
	if unique && (c.engine == "mysql" || c.engine == "mariadb") {
		constraint := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: table.Schema, Table: table.Name, Name: name}, "u")
		constraint.Columns = sc.Complete(columns)
		constraint.BackingIndex = sc.Known(index.Ref)
		constraint.NullsDistinct = sc.Known(true)
		index.Constraint = sc.Known(constraint.Ref)
		return &constraint, &index, nil
	}
	return nil, &index, nil
}
func simpleIndex(table sc.Ref, name string, columns []sc.Ref, unique bool) sc.Index {
	keys := []sc.IndexKey{}
	for _, r := range columns {
		keys = append(keys, sc.IndexKey{Column: sc.Known(r), Expression: sc.Absent[sc.Expression](), Opclass: sc.Absent[sc.Ref](), Collation: sc.Absent[sc.Ref](), Descending: sc.Known(false), NullsFirst: sc.Known(false), PrefixLength: sc.Absent[int64](), Options: sc.Complete[sc.Option](nil)})
	}
	return sc.Index{Ref: sc.Ref{Kind: "index", Schema: table.Schema, Table: table.Name, Name: name}, Method: sc.Known("btree"), Unique: sc.Known(unique), NullsDistinct: sc.Known(true), Keys: sc.Complete(keys), Includes: sc.Complete[sc.Ref](nil), Predicate: sc.Absent[sc.Expression](), Options: sc.Complete[sc.Option](nil), Visible: sc.Known(true), Valid: sc.Known(true), Ready: sc.Known(true), Constraint: sc.Absent[sc.Ref]()}
}
func parseStandaloneIndex(ts []token, table sc.Ref, engine string) (sc.Index, error) {
	c := cursor{ts: ts, engine: engine}
	if !c.take("CREATE") {
		return sc.Index{}, ErrUnsupported
	}
	unique := c.take("UNIQUE")
	if !c.take("INDEX") {
		return sc.Index{}, ErrUnsupported
	}
	name, e := c.ident()
	if e != nil || !c.take("ON") {
		return sc.Index{}, ErrUnsupported
	}
	schema, owner, e := c.qualified(table.Schema)
	if e != nil || schema != table.Schema || owner != table.Name {
		return sc.Index{}, ErrInvalid
	}
	if c.take("USING") {
		method, e := c.ident()
		if e != nil || !strings.EqualFold(method, "btree") {
			return sc.Index{}, ErrUnsupported
		}
	}
	if engine == "mariadb" {
		index, e := mariaDBIndex(&c, table, name, unique)
		if e != nil {
			return sc.Index{}, e
		}
		return *index, nil
	}
	columns, e := columnList(&c, table)
	if e != nil || c.i != len(ts) {
		return sc.Index{}, ErrUnsupported
	}
	index := simpleIndex(table, name, columns, unique)
	if engine == "mysql" || engine == "mariadb" {
		for i := range index.Keys.Items {
			index.Keys.Items[i].NullsFirst = sc.Known(true)
		}
	}
	if engine == "postgresql" {
		for i := range index.Keys.Items {
			index.Keys.Items[i].Opclass = sc.Unknown[sc.Ref]("offlineDefaultOpclass")
		}
	}
	return index, nil
}

func sortCapture(c *sc.Capture) {
	sort.Slice(c.Tables, func(i, j int) bool { return refKey(c.Tables[i].Ref) < refKey(c.Tables[j].Ref) })
}

type mariaDBPeriodFact struct {
	Name, NativeType, DataType, Generated string
	Implicit                              bool
}

func mariaDBTableProperties(table *sc.Table, ast tableAST) error {
	var start, end *columnAST
	for i := range ast.columns {
		column := &ast.columns[i]
		if versioning := column.attrs["versioning"]; len(versioning) > 0 {
			if versioning[0].is("WITHOUT") {
				table.Options.Items = append(table.Options.Items, sc.Option{Name: "columnSystemVersioning:" + column.name, Value: "without"})
			}
		}
		switch mariaDBPeriodRole(*column) {
		case "systemRowStart":
			if start != nil {
				return ErrUnsupported
			}
			start = column
		case "systemRowEnd":
			if end != nil {
				return ErrUnsupported
			}
			end = column
		}
	}
	var declared []sc.Ref
	for _, term := range ast.members {
		if len(term) > 0 && term[0].is("PERIOD") {
			c := cursor{ts: term, engine: "mariadb"}
			c.take("PERIOD")
			if !c.take("FOR") || !c.take("SYSTEM_TIME") || declared != nil {
				return ErrUnsupported
			}
			columns, e := columnList(&c, table.Ref)
			if e != nil || len(columns) != 2 || c.i != len(term) {
				return ErrUnsupported
			}
			declared = columns
		}
	}
	versioned := table.Kind.Value != nil && *table.Kind.Value == "systemVersioned"
	if !versioned {
		if start != nil || end != nil || declared != nil {
			return ErrUnsupported
		}
		return nil
	}
	periods := []mariaDBPeriodFact{}
	if start == nil && end == nil && declared == nil {
		periods = []mariaDBPeriodFact{{Name: "ROW_START", NativeType: "timestamp(6)", DataType: "timestamp", Generated: "ROW START", Implicit: true}, {Name: "ROW_END", NativeType: "timestamp(6)", DataType: "timestamp", Generated: "ROW END", Implicit: true}}
	} else {
		if start == nil || end == nil || len(declared) != 2 || declared[0].Name != start.name || declared[1].Name != end.name {
			return ErrUnsupported
		}
		for i, column := range []*columnAST{start, end} {
			typ, e := builtinType(column.typ, "mariadb")
			if e != nil || typ.Modifiers.Value == nil {
				return ErrUnsupported
			}
			m := typ.Modifiers.Value
			native := typ.Ref.Name
			switch native {
			case "timestamp":
				if m.DatetimePrecision == nil || *m.DatetimePrecision != 6 {
					return ErrUnsupported
				}
				native += "(6)"
			case "bigint":
				if !m.Unsigned || m.Length == nil {
					return ErrUnsupported
				}
				native += "(" + strconv.FormatInt(*m.Length, 10) + ") unsigned"
			default:
				return ErrUnsupported
			}
			role := "ROW START"
			if i == 1 {
				role = "ROW END"
			}
			periods = append(periods, mariaDBPeriodFact{Name: column.name, NativeType: native, DataType: typ.Ref.Name, Generated: role})
		}
	}
	for _, period := range periods {
		raw, e := json.Marshal(period)
		if e != nil {
			return ErrUnsupported
		}
		table.Options.Items = append(table.Options.Items, sc.Option{Name: "systemPeriod:" + period.Generated, Value: string(raw)})
	}
	return nil
}

// Native implicit history PK metadata includes row_end in KCU, while
// STATISTICS omits that automatically maintained term. No visible ordinal exists.
func mariaDBImplicitPrimary(table *sc.Table, k *sc.Constraint, x *sc.Index) {
	if k.Kind.Value == nil || *k.Kind.Value != "p" || !mariaDBImplicitPeriodAddress(*table, "row_end") {
		return
	}
	end := sc.Ref{Kind: "column", Schema: table.Ref.Schema, Table: table.Ref.Name, Name: "row_end"}
	if len(k.Columns.Items) == 0 || !strings.EqualFold(k.Columns.Items[len(k.Columns.Items)-1].Name, end.Name) {
		k.Columns.Items = append(k.Columns.Items, end)
	} else {
		k.Columns.Items[len(k.Columns.Items)-1] = end
	}
	if len(x.Keys.Items) > 0 {
		last := x.Keys.Items[len(x.Keys.Items)-1]
		if last.Column.Value != nil && mariaDBImplicitPeriodAddress(*table, last.Column.Value.Name) && strings.EqualFold(last.Column.Value.Name, end.Name) {
			x.Keys.Items = x.Keys.Items[:len(x.Keys.Items)-1]
		}
	}
}
func mariaDBImplicitPrimarySuffix(table sc.Table, k sc.Constraint, keys int) bool {
	return k.Kind.Value != nil && *k.Kind.Value == "p" && len(k.Columns.Items) == keys+1 && keys > 0 && strings.EqualFold(k.Columns.Items[keys].Name, "row_end") && mariaDBImplicitPeriodAddress(table, k.Columns.Items[keys].Name)
}

func mariaDBImplicitPeriodAddress(table sc.Table, name string) bool {
	if table.Kind.Value == nil || *table.Kind.Value != "systemVersioned" {
		return false
	}
	periods := map[string]mariaDBPeriodFact{}
	for _, option := range table.Options.Items {
		if strings.HasPrefix(option.Name, "systemPeriod:") {
			var period mariaDBPeriodFact
			decoder := json.NewDecoder(strings.NewReader(option.Value))
			decoder.DisallowUnknownFields()
			if decoder.Decode(&period) != nil || !period.Implicit || period.NativeType != "timestamp(6)" || period.DataType != "timestamp" || option.Name != "systemPeriod:"+period.Generated {
				return false
			}
			if _, duplicate := periods[period.Generated]; duplicate {
				return false
			}
			periods[period.Generated] = period
		}
	}
	start, startOK := periods["ROW START"]
	end, endOK := periods["ROW END"]
	return len(periods) == 2 && startOK && endOK && start.Name == "ROW_START" && end.Name == "ROW_END" && (strings.EqualFold(name, start.Name) || strings.EqualFold(name, end.Name))
}

func mariaDBIndex(c *cursor, table sc.Ref, name string, unique bool) (*sc.Index, error) {
	method := "BTREE"
	readMethod := func() error {
		value, e := c.ident()
		if e != nil {
			return e
		}
		value = strings.ToUpper(value)
		if value != "BTREE" && value != "HASH" {
			return ErrUnsupported
		}
		method = value
		return nil
	}
	if c.take("USING") {
		if e := readMethod(); e != nil {
			return nil, e
		}
	}
	group, e := c.group()
	if e != nil {
		return nil, e
	}
	terms, e := commaTerms(group)
	if e != nil || len(terms) == 0 {
		return nil, ErrUnsupported
	}
	keys := []sc.IndexKey{}
	columns := []sc.Ref{}
	for _, term := range terms {
		p := cursor{ts: term, engine: "mariadb"}
		column, e := p.ident()
		if e != nil {
			return nil, e
		}
		prefix := sc.Absent[int64]()
		if p.i < len(term) && term[p.i].value == "(" {
			group, e := p.group()
			if e != nil {
				return nil, e
			}
			n, e := intLiteral(group)
			if e != nil || n < 1 || n > 65535 {
				return nil, ErrUnsupported
			}
			prefix = sc.Known(n)
		}
		descending := p.take("DESC")
		if !descending {
			p.take("ASC")
		}
		if p.i != len(term) {
			return nil, ErrUnsupported
		}
		ref := sc.Ref{Kind: "column", Schema: table.Schema, Table: table.Name, Name: column}
		columns = append(columns, ref)
		keys = append(keys, sc.IndexKey{Column: sc.Known(ref), Expression: sc.Absent[sc.Expression](), Opclass: sc.Absent[sc.Ref](), Collation: sc.Absent[sc.Ref](), Descending: sc.Known(descending), NullsFirst: sc.Known(!descending), PrefixLength: prefix, Options: sc.Complete[sc.Option](nil)})
	}
	index := simpleIndex(table, name, columns, unique)
	index.Keys = sc.Complete(keys)
	seen := map[string]bool{}
	for c.i < len(c.ts) {
		key := ""
		switch {
		case c.take("USING"):
			key = "method"
			if e := readMethod(); e != nil {
				return nil, e
			}
		case c.take("IGNORED"):
			key = "visible"
			index.Visible = sc.Known(false)
		case c.take("NOT"):
			key = "visible"
			if !c.take("IGNORED") {
				return nil, ErrUnsupported
			}
			index.Visible = sc.Known(true)
		case c.take("COMMENT"):
			key = "comment"
			if c.i >= len(c.ts) || c.ts[c.i].kind != 's' {
				return nil, ErrUnsupported
			}
			index.Options.Items = append(index.Options.Items, sc.Option{Name: "comment", Value: c.ts[c.i].value})
			c.i++
		default:
			return nil, ErrUnsupported
		}
		if seen[key] {
			return nil, ErrUnsupported
		}
		seen[key] = true
	}
	if name == "PRIMARY" && index.Visible.Value != nil && !*index.Visible.Value {
		return nil, ErrUnsupported
	}
	index.Method = sc.Known(method)
	return &index, nil
}
