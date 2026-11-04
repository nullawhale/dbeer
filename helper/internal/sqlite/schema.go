package sqlite

import (
	"context"
	"fmt"
	"strings"
	"time"

	sc "dbeer/helper/internal/schemacompare"
)

func (s *Session) ReadSchema(ctx context.Context, spec sc.CaptureSpec, sink sc.Sink) error {
	if len(spec.Schemas) != 1 || spec.Schemas[0] != "main" || s.TransactionStatus() != "idle" {
		return sc.ErrInvalid
	}
	if err := s.exec(ctx, "BEGIN"); err != nil {
		return err
	}
	defer func() { _ = s.exec(context.Background(), "ROLLBACK") }()
	stamp := time.Now().UTC().Format(time.RFC3339Nano)
	rows, _, err := s.query(ctx, `SELECT name,sql FROM main.sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name`)
	if err != nil {
		return err
	}
	inv := sc.Inventory{Schema: "main", Existence: "present", Tables: sc.Complete[sc.Ref](nil), Types: sc.Complete[sc.Ref](nil)}
	for _, row := range rows {
		inv.Tables.Items = append(inv.Tables.Items, sc.Ref{Kind: "table", Schema: "main", Name: cellText(row[0])})
	}
	if err = sink.Inventory(inv); err != nil {
		return err
	}
	for i, row := range rows {
		if len(rows) > spec.Limits.Nodes {
			return sc.ErrLimit
		}
		t, err := s.schemaTable(ctx, inv.Tables.Items[i], cellText(row[1]))
		if err != nil {
			return err
		}
		if err = sink.Table(t); err != nil {
			return err
		}
	}
	version, _, err := s.query(ctx, "SELECT sqlite_version()")
	if err != nil {
		return err
	}
	capture := sc.CaptureContext{Engine: "sqlite", Version: cellText(version[0][0]), Database: "main", StartedAt: stamp, FinishedAt: time.Now().UTC().Format(time.RFC3339Nano), Consistency: "repeatableRead", Visibility: "complete", EngineContext: sc.Known([]sc.Option{})}
	if err = s.exec(ctx, "COMMIT"); err != nil {
		return err
	}
	return sink.Context(capture)
}
func (s *Session) schemaTable(ctx context.Context, ref sc.Ref, raw string) (sc.Table, error) {
	t := sc.Table{Ref: ref, Kind: sc.Known("table"), Storage: sc.Known("permanent"), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Options: sc.Complete[sc.Option](nil), Columns: sc.Complete[sc.Column](nil), Constraints: sc.Complete[sc.Constraint](nil), Indexes: sc.Complete[sc.Index](nil), Dependencies: sc.Complete[sc.Dependency](nil)}
	if strings.HasPrefix(strings.ToUpper(raw), "CREATE VIRTUAL") {
		t.Kind = sc.Known("virtual")
		t.Dependencies = sc.Collection[sc.Dependency]{Items: []sc.Dependency{}, State: "unsupported", Code: "virtualTable"}
	}
	// The exact definition is retained as a semantic option so an unmodelled
	// constraint/expression cannot disappear from an equality report.
	t.Options.Items = append(t.Options.Items, sc.Option{Name: "definition", Value: raw})
	columns, err := s.tableInfo(ctx, "main", ref.Name)
	if err != nil {
		return t, err
	}
	primary := map[int]sc.Ref{}
	for i, c := range columns {
		r := sc.Ref{Kind: "column", Schema: ref.Schema, Table: ref.Name, Name: c.Name}
		typ := sc.TypeUse{Ref: sc.Ref{Kind: "type", Schema: "sqlite", Name: c.NativeType}, Kind: "builtin", Modifiers: sc.Known(sc.TypeModifiers{}), Labels: sc.Complete[string](nil)}
		def := sc.Default{Kind: "none"}
		if c.Default != nil {
			def = sc.Default{Kind: "expression", Expression: &sc.Expression{Text: *c.Default, Dependencies: sc.Complete[sc.Ref](nil)}}
		}
		generated := sc.Generated{Kind: "none"}
		if c.Hidden > 1 {
			generated = sc.Generated{Kind: "sqlite", Expression: &sc.Expression{Text: "See captured table definition", Dependencies: sc.Complete[sc.Ref](nil)}}
		}
		t.Columns.Items = append(t.Columns.Items, sc.Column{Ref: r, Ordinal: sc.Known(i), Type: sc.Known(typ), Nullable: sc.Known(!c.NotNull), Default: sc.Known(def), Generated: sc.Known(generated), Identity: sc.Known(sc.Identity{Kind: "none"}), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Visible: sc.Known(c.Hidden != 1), Comment: sc.Absent[string](), OnUpdate: sc.Absent[sc.Expression]()})
		if c.PrimaryKey > 0 {
			primary[c.PrimaryKey] = r
		}
	}
	if len(primary) > 0 {
		k := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: ref.Schema, Table: ref.Name, Name: "primary_key"}, "p")
		for i := 1; i <= len(primary); i++ {
			k.Columns.Items = append(k.Columns.Items, primary[i])
		}
		t.Constraints.Items = append(t.Constraints.Items, k)
	}
	fk, _, err := s.query(ctx, `SELECT id,seq,"table","from","to",on_update,on_delete,match FROM pragma_foreign_key_list(?) ORDER BY id,seq`, ref.Name)
	if err != nil {
		return t, err
	}
	groups := map[int]int{}
	implicitSizes := map[int]int{}
	for _, row := range fk {
		id := cellInt(row[0])
		i, ok := groups[id]
		if !ok {
			r := sc.Ref{Kind: "constraint", Schema: ref.Schema, Table: ref.Name, Name: fmt.Sprintf("foreign_key_%d", id)}
			k := sc.NewConstraint(r, "f")
			k.Target = sc.Known(sc.Ref{Kind: "table", Schema: "main", Name: cellText(row[2])})
			k.Update = sc.Known(cellText(row[5]))
			k.Delete = sc.Known(cellText(row[6]))
			k.Match = sc.Known(cellText(row[7]))
			// PRAGMA does not expose deferrability or associate definition
			// clauses with a specific FK. Preserve uncertainty rather than
			// asserting the non-deferrable default when a clause is present.
			if strings.Contains(strings.ToUpper(raw), "DEFERRABLE") || strings.Contains(strings.ToUpper(raw), "INITIALLY") {
				k.Deferrable = sc.Unknown[bool]("sqliteDeferrabilityNotReported")
				k.InitiallyDeferred = sc.Unknown[bool]("sqliteDeferrabilityNotReported")
			}
			i = len(t.Constraints.Items)
			groups[id] = i
			t.Constraints.Items = append(t.Constraints.Items, k)
		}
		src := sc.Ref{Kind: "column", Schema: "main", Table: ref.Name, Name: cellText(row[3])}
		targetName := cellText(row[4])
		if row[4].Type == "null" {
			targetColumns, e := s.tableInfo(ctx, "main", cellText(row[2]))
			if e != nil && ctx.Err() != nil {
				return t, ctx.Err()
			}
			// A missing or unreadable parent leaves the relationship unknown;
			// it must not become a complete key with an empty column name.
			implicitSizes[id] = 0
			for _, column := range targetColumns {
				if column.PrimaryKey > 0 {
					implicitSizes[id]++
				}
				if column.PrimaryKey == cellInt(row[1])+1 {
					targetName = column.Name
				}
			}
		}
		dst := sc.Ref{Kind: "column", Schema: "main", Table: cellText(row[2]), Name: targetName}
		t.Constraints.Items[i].Columns.Items = append(t.Constraints.Items[i].Columns.Items, src)
		if targetName == "" {
			t.Constraints.Items[i].ForeignKeys.Complete = false
			t.Constraints.Items[i].ForeignKeys.State = "unsupported"
			t.Constraints.Items[i].ForeignKeys.Code = "sqliteForeignKeyTargetUnavailable"
		} else {
			t.Constraints.Items[i].ForeignKeys.Items = append(t.Constraints.Items[i].ForeignKeys.Items, sc.ColumnPair{Source: src, Target: dst})
		}
	}
	for id, size := range implicitSizes {
		index := groups[id]
		if size != len(t.Constraints.Items[index].Columns.Items) {
			t.Constraints.Items[index].ForeignKeys.Complete = false
			t.Constraints.Items[index].ForeignKeys.State = "unsupported"
			t.Constraints.Items[index].ForeignKeys.Code = "sqliteForeignKeyTargetUnavailable"
		}
	}
	indexes, _, err := s.query(ctx, `SELECT name,sql FROM main.sqlite_schema WHERE type='index' AND tbl_name=? ORDER BY name`, ref.Name)
	if err != nil {
		return t, err
	}
	for _, row := range indexes {
		t.Options.Items = append(t.Options.Items, sc.Option{Name: "index:" + cellText(row[0]), Value: cellText(row[1])})
	}
	triggers, _, err := s.query(ctx, `SELECT name,sql FROM main.sqlite_schema WHERE type='trigger' AND tbl_name=? ORDER BY name`, ref.Name)
	if err != nil {
		return t, err
	}
	for _, row := range triggers {
		t.Options.Items = append(t.Options.Items, sc.Option{Name: "trigger:" + cellText(row[0]), Value: cellText(row[1])})
	}
	return t, nil
}
func RenderSchemaDefinition(ctx context.Context, capture sc.Capture, ref sc.Ref) (sc.Definition, error) {
	if err := ctx.Err(); err != nil {
		return sc.Definition{}, err
	}
	w := &sc.DefinitionWriter{Context: ctx}
	for _, t := range capture.Tables {
		if t.Ref.Schema == ref.Schema && t.Ref.Name == ref.Name {
			for _, option := range t.Options.Items {
				if option.Name == "definition" {
					w.Write(option.Value + ";\n")
				}
			}
			for _, option := range t.Options.Items {
				if (strings.HasPrefix(option.Name, "index:") || strings.HasPrefix(option.Name, "trigger:")) && option.Value != "" {
					w.Write(option.Value + ";\n")
				}
			}
			return w.Finish()
		}
	}
	w.Note("The selected definition was not captured.")
	return w.Finish()
}
