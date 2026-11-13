package sqlite

import (
	"context"
	"sort"
	"strings"

	sc "dbeer/helper/internal/schemacompare"
	lib "zombiezen.com/go/sqlite"
)

type schemaProgramCatalog struct {
	objects  map[string]sc.Ref
	triggers map[string]sc.Ref
}

// schemaDependencyCatalog resolves names reported by SQLite's authorizer to
// catalog identities. SQLite identifiers fold ASCII only, not Unicode.
func (s *Session) schemaDependencyCatalog(ctx context.Context, limits sc.Limits) (schemaProgramCatalog, error) {
	rows, _, err := s.query(ctx, `SELECT type,name,tbl_name FROM main.sqlite_schema WHERE type IN ('table','view','trigger') ORDER BY type,name`)
	if err != nil {
		return schemaProgramCatalog{}, err
	}
	if len(rows) > limits.Members {
		return schemaProgramCatalog{}, sc.ErrLimit
	}
	out := schemaProgramCatalog{objects: make(map[string]sc.Ref, len(rows)), triggers: make(map[string]sc.Ref)}
	for _, row := range rows {
		if err = ctx.Err(); err != nil {
			return schemaProgramCatalog{}, err
		}
		name := cellText(row[1])
		table := cellText(row[2])
		if len(name) > limits.Scalar || len(table) > limits.Scalar {
			return schemaProgramCatalog{}, sc.ErrLimit
		}
		ref := sc.Ref{Kind: cellText(row[0]), Schema: "main", Name: name}
		if ref.Kind == "trigger" {
			ref.Table = table
			out.triggers[ddlFold(name)] = ref
		} else {
			out.objects[ddlFold(name)] = ref
		}
	}
	return out, nil
}

// schemaProgramDependencies asks SQLite to compile all three table write paths.
// Only EXPLAIN statements are prepared, never stepped. SQLite resolves trigger,
// index, default and generated/check expression programs, including nested views
// and available builtin functions, without running user programs or changing
// rows/counters. An ordered SELECT also resolves declared column collations.
// The regular readonly authorizer is restored on every exit.
func (s *Session) schemaProgramDependencies(ctx context.Context, ref sc.Ref, columns []columnInfo, triggers []string, catalog schemaProgramCatalog, limits sc.Limits) (dependencies sc.Collection[sc.Dependency], err error) {
	dependencies = sc.Complete[sc.Dependency](nil)
	if err = ctx.Err(); err != nil {
		return dependencies, err
	}
	var update, selection strings.Builder
	target := quote(ref.Schema) + "." + quote(ref.Name)
	update.WriteString("EXPLAIN UPDATE " + target + " SET ")
	selection.WriteString("EXPLAIN SELECT * FROM " + target + " ORDER BY ")
	first := true
	selectFirst := true
	for _, column := range columns {
		if err = ctx.Err(); err != nil {
			return dependencies, err
		}
		name := quote(column.Name)
		if column.Hidden != 1 {
			addition := len(name)
			if !selectFirst {
				addition++
			}
			if selection.Len() > limits.Scalar-addition {
				return dependencies, sc.ErrLimit
			}
			if !selectFirst {
				selection.WriteByte(',')
			}
			selectFirst = false
			selection.WriteString(name)
		}
		if column.Hidden != 0 {
			continue
		}
		addition := len(name)*2 + 1
		if !first {
			addition++
		}
		if update.Len() > limits.Scalar-addition {
			return dependencies, sc.ErrLimit
		}
		if !first {
			update.WriteByte(',')
		}
		first = false
		update.WriteString(name + "=" + name)
	}
	if first {
		return sc.Collection[sc.Dependency]{Items: []sc.Dependency{}, State: "unsupported", Code: "sqliteProgramDependenciesUnproven"}, nil
	}
	probes := []string{"EXPLAIN INSERT INTO " + target + " DEFAULT VALUES", update.String(), "EXPLAIN DELETE FROM " + target, selection.String()}
	for _, probe := range probes {
		if len(probe) > limits.Scalar {
			return dependencies, sc.ErrLimit
		}
	}
	edges := map[sc.Ref]sc.Dependency{}
	seenTriggers := map[string]bool{}
	expectedTriggers := map[string]bool{}
	for _, name := range triggers {
		expectedTriggers[ddlFold(name)] = true
	}
	observations, observedBytes := 0, 0
	limited := false
	unknown := false
	viewAccessors := map[string]sc.Ref{}
	ephemeral := map[string]bool{}
	add := func(to sc.Ref) {
		if to == ref || strings.HasPrefix(ddlFold(to.Name), "SQLITE_") {
			return
		}
		edges[to] = sc.Dependency{From: ref, To: to, Kind: "sqliteProgramReference", State: "observed"}
	}
	authorizer := lib.AuthorizeFunc(func(action lib.Action) lib.AuthResult {
		observations++
		observedBytes += len(action.Table()) + len(action.Accessor()) + len(action.Database())
		if observedBytes > limits.Bytes {
			limited = true
			return lib.AuthResultDeny
		}
		if len(action.Table()) > limits.Scalar || len(action.Accessor()) > limits.Scalar || len(action.Database()) > limits.Scalar {
			limited = true
			return lib.AuthResultDeny
		}
		if observations > limits.Members {
			limited = true
			return lib.AuthResultDeny
		}
		if ctx.Err() != nil {
			return lib.AuthResultDeny
		}
		if accessor := action.Accessor(); accessor != "" {
			key := ddlFold(accessor)
			if expectedTriggers[key] {
				seenTriggers[key] = true
			}
			_, isTrigger := catalog.triggers[key]
			if source, ok := catalog.objects[key]; ok && source.Kind == "view" {
				// Authorizer accessors expose only a name. A nested trigger
				// shares that namespace with views, so every captured trigger
				// identity participates, not just this table's own triggers.
				if isTrigger {
					unknown = true
				} else {
					viewAccessors[key] = source
				}
			}
		}
		switch action.Type() {
		case lib.OpRead, lib.OpInsert, lib.OpUpdate, lib.OpDelete:
			name := action.Table()
			if name != "" {
				if action.Database() == "" && action.Type() == lib.OpRead {
					ephemeral[ddlFold(name)] = true
				} else if action.Database() != "main" {
					unknown = true
				} else if target, ok := catalog.objects[ddlFold(name)]; ok {
					add(target)
				} else if !strings.HasPrefix(ddlFold(name), "SQLITE_") {
					unknown = true
				}
			}
		case lib.OpSelect, lib.OpFunction, lib.OpRecursive:
			// No external functions or collations are registered by this adapter.
			// Missing/unsafe functions fail preparation and retain unknown coverage.
		default:
			unknown = true
			return lib.AuthResultDeny
		}
		return lib.AuthResultOK
	})
	if err = s.conn.SetAuthorizer(authorizer); err != nil {
		return dependencies, err
	}
	defer func() {
		if restoreErr := s.conn.SetAuthorizer(lib.AuthorizeFunc(s.authorize)); restoreErr != nil && err == nil {
			err = restoreErr
		}
	}()
	previous := s.conn.SetInterrupt(ctx.Done())
	defer s.conn.SetInterrupt(previous)
	for _, probe := range probes {
		viewAccessors = map[string]sc.Ref{}
		ephemeral = map[string]bool{}
		if err = ctx.Err(); err != nil {
			return dependencies, err
		}
		statement, tail, prepareErr := s.conn.PrepareTransient(probe)
		if statement != nil {
			// Intentionally no Step: even an EXPLAIN must not execute here.
			if finalizeErr := statement.Finalize(); finalizeErr != nil && prepareErr == nil {
				prepareErr = finalizeErr
			}
		}
		if limited {
			return dependencies, sc.ErrLimit
		}
		if err = ctx.Err(); err != nil {
			return dependencies, err
		}
		if prepareErr != nil || tail != 0 {
			unknown = true
		}
		for name, view := range viewAccessors {
			if ephemeral[name] {
				unknown = true
			} else {
				add(view)
			}
		}
	}
	for name := range expectedTriggers {
		if !seenTriggers[name] {
			unknown = true
		}
	}
	refs := make([]sc.Ref, 0, len(edges))
	for target := range edges {
		refs = append(refs, target)
	}
	sort.Slice(refs, func(i, j int) bool {
		if refs[i].Kind != refs[j].Kind {
			return refs[i].Kind < refs[j].Kind
		}
		if refs[i].Schema != refs[j].Schema {
			return refs[i].Schema < refs[j].Schema
		}
		return refs[i].Name < refs[j].Name
	})
	for _, target := range refs {
		dependencies.Items = append(dependencies.Items, edges[target])
	}
	if unknown {
		dependencies.Complete = false
		dependencies.State = "unsupported"
		dependencies.Code = "sqliteProgramDependenciesUnproven"
	}
	return dependencies, nil
}
