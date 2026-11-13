package sqlite

import (
	"context"
	"errors"
	"regexp"
	"strings"

	"dbeer/helper/internal/tableedit"
)

func (s *Session) StructureLoad(ctx context.Context, t tableedit.Target) (tableedit.Baseline, error) {
	b := tableedit.Baseline{Target: t, Engine: "sqlite", Columns: []tableedit.ObservedColumn{}, Keys: []tableedit.Key{}, Indexes: []tableedit.Index{}, Limitations: []string{"Changes run in one dedicated transaction. Unsupported definitions or dependencies block reconstruction."}, Attributes: map[string]map[string]any{}}
	if !t.Valid() || t.Schema != "main" {
		return b, tableedit.ErrUnsupported
	}
	rows, _, err := s.query(ctx, `SELECT type,name,tbl_name,sql FROM main.sqlite_schema ORDER BY type,name`)
	if err != nil {
		return b, err
	}
	raw := ""
	found := false
	for _, r := range rows {
		if cellText(r[1]) == t.Table && cellText(r[0]) == "table" {
			found = true
			raw = cellText(r[3])
		}
	}
	if found && t.Create && t.Reconcile {
		b.Target.Create = false
		b.Target.Reconcile = false
		t = b.Target
	}
	if found == t.Create {
		return b, tableedit.ErrUnsupported
	}
	if strings.HasPrefix(strings.ToUpper(raw), "CREATE VIRTUAL") {
		return b, tableedit.ErrUnsupported
	}
	b.Target.Reconcile = false
	b.Scope = tableedit.Fingerprint(s.path)
	b.Fingerprint = tableedit.Fingerprint([]any{s.path, t.Table, rows})
	b.Identity = tableedit.Fingerprint([]any{s.path, raw})
	b.Attributes["sqlite"] = map[string]any{"sql": raw}
	if !found {
		return b, nil
	}
	cols, err := s.tableInfo(ctx, "main", t.Table)
	if err != nil || len(cols) > tableedit.MaxColumns {
		return b, tableedit.ErrUnsupported
	}
	primary := map[int]string{}
	for _, c := range cols {
		typ, ok := sqliteEditableType(c.NativeType)
		var editable *tableedit.DataType
		if ok && c.Hidden == 0 {
			editable = &typ
		}
		b.Columns = append(b.Columns, tableedit.ObservedColumn{Name: c.Name, NativeType: c.NativeType, Nullable: !c.NotNull, DefaultExpression: c.Default, EditableType: editable, CanModify: c.Hidden == 0})
		if c.PrimaryKey > 0 {
			primary[c.PrimaryKey] = c.Name
		}
	}
	if len(primary) > 0 {
		names := []string{}
		for i := 1; i <= len(primary); i++ {
			names = append(names, primary[i])
		}
		b.Keys = append(b.Keys, tableedit.Key{Kind: "primary", Name: "primary_key", Columns: names, Supported: true})
	}
	indexes, _, err := s.query(ctx, `PRAGMA main.index_list(`+quote(t.Table)+`)`)
	if err != nil {
		return b, err
	}
	for _, r := range indexes {
		name := cellText(r[1])
		parts, _, err := s.query(ctx, `PRAGMA main.index_info(`+quote(name)+`)`)
		if err != nil {
			return b, err
		}
		names := []string{}
		supported := cellInt(r[4]) == 0
		for _, p := range parts {
			if p[2].Type == "null" {
				supported = false
			} else {
				names = append(names, cellText(p[2]))
			}
		}
		if !strings.HasPrefix(name, "sqlite_autoindex_") {
			b.Indexes = append(b.Indexes, tableedit.Index{Name: name, Columns: names, Unique: cellInt(r[2]) != 0, Supported: supported})
		}
	}
	return b, nil
}
func sqliteEditableType(typ string) (tableedit.DataType, bool) {
	k := map[string]string{"INTEGER": "integer", "REAL": "real", "TEXT": "text", "BLOB": "blob", "ANY": "any", "NUMERIC": "sqliteNumeric"}[strings.ToUpper(typ)]
	return tableedit.DataType{Kind: k}, k != ""
}

var sqliteNumericLiteral = regexp.MustCompile(`^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$`)

func structureColumn(c tableedit.Column) (string, error) {
	if c.Type.Reference != nil {
		return "", tableedit.ErrUnsupported
	}
	typ := map[string]string{"integer": "INTEGER", "bigint": "INTEGER", "boolean": "INTEGER", "real": "REAL", "text": "TEXT", "blob": "BLOB", "any": "ANY", "sqliteNumeric": "NUMERIC"}[c.Type.Kind]
	if !c.Valid() || typ == "" {
		return "", tableedit.ErrUnsupported
	}
	out := quote(c.Name) + " " + typ
	if c.Generated != nil && c.Generated.Storage != "none" {
		expr, err := tableedit.ExpressionSlot("sqlite", c.Generated.Expression)
		if err != nil {
			return "", err
		}
		out += " GENERATED ALWAYS AS " + expr + " " + strings.ToUpper(c.Generated.Storage)
	}
	if !c.Nullable {
		out += " NOT NULL"
	}
	switch c.Default.Kind {
	case "none":
	case "null":
		out += " DEFAULT NULL"
	case "text":
		out += " DEFAULT '" + strings.ReplaceAll(*c.Default.Value, "'", "''") + "'"
	case "numeric":
		if !sqliteNumericLiteral.MatchString(*c.Default.Value) {
			return "", tableedit.ErrInvalid
		}
		out += " DEFAULT " + *c.Default.Value
	case "boolean":
		if *c.Default.Value == "true" {
			out += " DEFAULT 1"
		} else if *c.Default.Value == "false" {
			out += " DEFAULT 0"
		} else {
			return "", tableedit.ErrInvalid
		}
	case "expression":
		expr, err := tableedit.ExpressionSlot("sqlite", *c.Default.Value)
		if err != nil {
			return "", err
		}
		out += " DEFAULT " + expr
	default:
		return "", tableedit.ErrUnsupported
	}
	if c.Identity != nil && c.Identity.Kind != "none" {
		if c.Identity.Kind != "autoIncrement" || c.PrimaryKeyName == "" || (c.Type.Kind != "integer" && c.Type.Kind != "bigint") {
			return "", tableedit.ErrUnsupported
		}
		out += " CONSTRAINT " + quote(c.PrimaryKeyName) + " PRIMARY KEY AUTOINCREMENT"
	}
	return out, nil
}
func keySQL(k tableedit.KeyEdit) (string, error) {
	names := make([]string, len(k.Columns))
	for i, n := range k.Columns {
		names[i] = quote(n)
	}
	out := "CONSTRAINT " + quote(k.Name) + " "
	switch k.Kind {
	case "primary":
		out += "PRIMARY KEY"
	case "unique":
		out += "UNIQUE"
	case "foreign":
		out += "FOREIGN KEY"
	default:
		return "", tableedit.ErrUnsupported
	}
	out += " (" + strings.Join(names, ",") + ")"
	if k.Kind == "foreign" {
		if k.Reference == nil || k.Reference.Schema != "main" {
			return "", tableedit.ErrUnsupported
		}
		ref := make([]string, len(k.ReferenceColumns))
		for i, n := range k.ReferenceColumns {
			ref[i] = quote(n)
		}
		out += " REFERENCES " + quote(k.Reference.Table) + " (" + strings.Join(ref, ",") + ") ON UPDATE " + k.OnUpdate + " ON DELETE " + k.OnDelete
	}
	return out, nil
}
func (s *Session) StructureRender(b tableedit.Baseline, d tableedit.Draft) ([]string, []string, error) {
	p, e := s.StructurePrepare(context.Background(), b, d)
	return p.SQL, p.Risks, e
}
func (s *Session) StructurePrepare(ctx context.Context, b tableedit.Baseline, d tableedit.Draft) (tableedit.Prepared, error) {
	if d.NeedsAuthoringV3() {
		return tableedit.Prepared{}, errors.New("Advanced index definitions are currently available for PostgreSQL/MySQL only; SQLite index intent is never ignored. Use an explicit reviewed SQLite migration for expressions or partial indexes.")
	}
	p := tableedit.Prepared{Risks: []string{"Apply uses BEGIN IMMEDIATE and rechecks the captured schema. Table reconstruction copies all rows and validates foreign keys before COMMIT."}}
	if !d.Valid() || b.Engine != "sqlite" || b.Target.Schema != "main" {
		return p, tableedit.ErrInvalid
	}
	if d.HasAuthoredExpressions() {
		p.Risks = append(p.Risks, "Authored expressions and generated values run only during Apply or later writes. Preview validates expression boundaries without evaluating authored code. SQLite may reject expressions at Apply; semantic validity is not proven by Preview.")
	}
	renaming := d.RenameTable != nil
	for _, c := range d.Changes {
		renaming = renaming || c.RenameTo != nil
	}
	if renaming {
		return s.prepareStructureRenames(ctx, b, d, p)
	}
	for _, c := range d.Changes {
		if c.Generated != nil || c.Identity != nil || c.Type != nil && c.Type.Reference != nil {
			return p, errors.New("Changing generated or identity columns requires a separately reviewed SQLite reconstruction.")
		}
	}
	target := "main." + quote(b.Target.Table)
	indexEdits := func() error {
		for _, x := range d.Indexes {
			if x.Action != "add" {
				found := false
				for _, old := range b.Indexes {
					if old.Name == x.Name && old.Supported {
						found = true
					}
				}
				if !found {
					return tableedit.ErrUnsupported
				}
				p.SQL = append(p.SQL, "DROP INDEX main."+quote(x.Name)+";")
			}
			if x.Action != "drop" {
				names := []string{}
				for _, n := range x.Columns {
					found := false
					for _, c := range b.Columns {
						if c.Name == n {
							found = true
						}
					}
					for _, c := range d.Columns {
						if c.Name == n {
							found = true
						}
					}
					if !found {
						return tableedit.ErrInvalid
					}
					names = append(names, quote(n))
				}
				unique := ""
				if x.Unique {
					unique = "UNIQUE "
				}
				p.SQL = append(p.SQL, "CREATE "+unique+"INDEX main."+quote(x.Name)+" ON "+quote(b.Target.Table)+" ("+strings.Join(names, ",")+");")
			}
		}
		return nil
	}
	if b.Target.Create {
		if len(d.Columns) == 0 || len(d.Changes) > 0 {
			return p, tableedit.ErrInvalid
		}
		parts := []string{}
		inlinePrimary := ""
		for _, c := range d.Columns {
			if c.Identity != nil && c.Identity.Kind != "none" {
				if inlinePrimary != "" {
					return p, tableedit.ErrInvalid
				}
				for _, k := range d.Keys {
					if k.Action == "add" && k.Kind == "primary" && len(k.Columns) == 1 && k.Columns[0] == c.Name {
						c.PrimaryKeyName = k.Name
						inlinePrimary = k.Name
					}
				}
				if c.PrimaryKeyName == "" {
					return p, errors.New("SQLite AUTOINCREMENT requires an explicit single-column INTEGER primary key.")
				}
			}
			x, e := structureColumn(c)
			if e != nil {
				return p, e
			}
			parts = append(parts, x)
		}
		for _, k := range d.Keys {
			if k.Kind == "primary" && k.Name == inlinePrimary {
				continue
			}
			if k.Action != "add" {
				return p, tableedit.ErrInvalid
			}
			x, e := keySQL(k)
			if e != nil {
				return p, e
			}
			parts = append(parts, x)
		}
		p.SQL = []string{"CREATE TABLE " + target + " (" + strings.Join(parts, ",") + ");"}
		return p, indexEdits()
	}
	if len(d.Changes) == 0 && len(d.Keys) == 0 {
		for _, c := range d.Columns {
			if c.Default.Kind == "expression" {
				return p, errors.New("SQLite cannot ADD a column with an expression default; use an explicit reviewed reconstruction.")
			}
			if c.Generated != nil && c.Generated.Storage == "stored" {
				return p, errors.New("SQLite cannot ADD a stored generated column; use an explicit reviewed reconstruction.")
			}
			if c.Identity != nil && c.Identity.Kind != "none" {
				return p, errors.New("Adding SQLite AUTOINCREMENT to an existing table requires explicit reconstruction.")
			}
			x, e := structureColumn(c)
			if e != nil {
				return p, e
			}
			p.SQL = append(p.SQL, "ALTER TABLE "+target+" ADD COLUMN "+x+";")
		}
		return p, indexEdits()
	}
	if len(d.Keys) == 0 {
		return s.preparePreservedRebuild(ctx, b, d, p)
	}
	raw, _ := b.Attributes["sqlite"]["sql"].(string)
	// Reconstruction only models uncomplicated ordinary columns and an optional
	// primary key. Definitions needing expression-aware rewriting remain explicit.
	upper := strings.ToUpper(raw)
	for _, word := range []string{"CHECK", "COLLATE", "GENERATED", "UNIQUE", "FOREIGN", "REFERENCES", "CONSTRAINT", "DESC", "CONFLICT"} {
		if strings.Contains(upper, word) {
			return p, errors.New("This table definition needs manual reconstruction; no SQL was prepared.")
		}
	}
	views, _, err := s.query(ctx, `SELECT name FROM main.sqlite_schema WHERE type='view'`)
	if err != nil {
		return p, err
	}
	if len(views) > 0 {
		return p, errors.New("Views prevent proving reconstruction dependencies; use manual SQL.")
	}
	columns := make([]tableedit.Column, len(b.Columns))
	primary := []string{}
	autoincrement := strings.Contains(upper, "AUTOINCREMENT")
	for i, c := range b.Columns {
		if !c.CanModify {
			return p, tableedit.ErrUnsupported
		}
		typ, ok := sqliteEditableType(c.NativeType)
		if !ok {
			return p, tableedit.ErrUnsupported
		}
		def := tableedit.Default{Kind: "none"}
		if c.DefaultExpression != nil {
			def, err = parseLiteralDefault(*c.DefaultExpression)
			if err != nil {
				return p, err
			}
		}
		columns[i] = tableedit.Column{Name: c.Name, Type: typ, Nullable: c.Nullable, Default: def}
	}
	for _, k := range b.Keys {
		if k.Kind == "primary" {
			primary = append(primary, k.Columns...)
		}
	}
	for _, change := range d.Changes {
		found := false
		for i := range columns {
			if columns[i].Name != change.Name {
				continue
			}
			found = true
			if change.Type != nil {
				columns[i].Type = *change.Type
			}
			if change.Nullable != nil {
				columns[i].Nullable = *change.Nullable
			}
			if change.Default != nil {
				columns[i].Default = *change.Default
			}
		}
		if !found {
			return p, tableedit.ErrInvalid
		}
	}
	columns = append(columns, d.Columns...)
	if autoincrement {
		if len(primary) != 1 || len(d.Keys) > 0 {
			return p, tableedit.ErrUnsupported
		}
		for _, c := range columns {
			if c.Name == primary[0] && c.Type.Kind != "integer" {
				return p, tableedit.ErrUnsupported
			}
		}
	}
	parts := []string{}
	for _, c := range columns {
		x, e := structureColumn(c)
		if e != nil {
			return p, e
		}
		if autoincrement && c.Name == primary[0] {
			x += " PRIMARY KEY AUTOINCREMENT"
		}
		parts = append(parts, x)
	}
	for _, k := range d.Keys {
		if k.Action != "add" {
			if k.Kind != "primary" || k.Name != "primary_key" || len(primary) == 0 {
				return p, tableedit.ErrUnsupported
			}
			primary = nil
		}
	}
	if len(primary) > 0 && !autoincrement {
		names := []string{}
		for _, n := range primary {
			names = append(names, quote(n))
		}
		parts = append(parts, "PRIMARY KEY ("+strings.Join(names, ",")+")")
	}
	for _, k := range d.Keys {
		if k.Action != "drop" {
			x, e := keySQL(k)
			if e != nil {
				return p, e
			}
			parts = append(parts, x)
		}
	}
	suffix := ""
	close := strings.LastIndex(raw, ")")
	if close < 0 {
		return p, tableedit.ErrUnsupported
	}
	suffix = strings.TrimSpace(raw[close+1:])
	suffix = strings.TrimSuffix(suffix, ";")
	if suffix != "" && !strings.EqualFold(suffix, "STRICT") && !strings.EqualFold(suffix, "WITHOUT ROWID") && !strings.EqualFold(suffix, "WITHOUT ROWID, STRICT") && !strings.EqualFold(suffix, "STRICT, WITHOUT ROWID") {
		return p, tableedit.ErrUnsupported
	}
	if strings.Contains(strings.ToUpper(suffix), "STRICT") {
		for _, c := range columns {
			if c.Type.Kind == "sqliteNumeric" {
				return p, tableedit.ErrUnsupported
			}
		}
	}
	temp := "__dbeer_rebuild_" + b.Fingerprint[:12]
	names := []string{}
	for _, c := range b.Columns {
		names = append(names, quote(c.Name))
	}
	// Preserve hidden rowids unless an INTEGER PRIMARY KEY aliases that rowid.
	rowidAlias := ""
	if !strings.Contains(strings.ToUpper(suffix), "WITHOUT ROWID") {
		used := map[string]bool{}
		for _, next := range columns {
			used[strings.ToLower(next.Name)] = true
		}
		aliasPK := false
		for _, c := range b.Columns {
			used[strings.ToLower(c.Name)] = true
			for _, next := range columns {
				if len(primary) == 1 && primary[0] == c.Name && next.Name == c.Name && next.Type.Kind == "integer" {
					aliasPK = true
				}
			}
		}
		if !aliasPK {
			for _, alias := range []string{"rowid", "_rowid_", "oid"} {
				if !used[alias] {
					rowidAlias = alias
					break
				}
			}
			if rowidAlias == "" {
				return p, tableedit.ErrUnsupported
			}
			names = append([]string{rowidAlias}, names...)
		}
	}
	p.SQL = []string{"CREATE TABLE main." + quote(temp) + " (" + strings.Join(parts, ",") + ") " + suffix + ";", "INSERT INTO main." + quote(temp) + " (" + strings.Join(names, ",") + ") SELECT " + strings.Join(names, ",") + " FROM " + target + ";", "DROP TABLE " + target + ";", "ALTER TABLE main." + quote(temp) + " RENAME TO " + quote(b.Target.Table) + ";"}
	if autoincrement {
		oldLiteral := "'" + strings.ReplaceAll(b.Target.Table, "'", "''") + "'"
		tempLiteral := "'" + temp + "'"
		sequenceSteps := []string{
			"INSERT INTO main.sqlite_sequence(name,seq) SELECT " + tempLiteral + ",COALESCE((SELECT seq FROM main.sqlite_sequence WHERE name=" + oldLiteral + "),0) WHERE NOT EXISTS(SELECT 1 FROM main.sqlite_sequence WHERE name=" + tempLiteral + ");",
			"UPDATE main.sqlite_sequence SET seq=max(seq,COALESCE((SELECT seq FROM main.sqlite_sequence WHERE name=" + oldLiteral + "),0)) WHERE name=" + tempLiteral + ";",
		}
		p.SQL = append(append(append([]string{}, p.SQL[:2]...), sequenceSteps...), p.SQL[2:]...)
	}
	retained, _, err := s.query(ctx, `SELECT type,name,sql FROM main.sqlite_schema WHERE tbl_name=? AND type IN ('index','trigger') AND sql IS NOT NULL ORDER BY type,name`, b.Target.Table)
	if err != nil {
		return p, err
	}
	for _, row := range retained {
		skip := false
		for _, edit := range d.Indexes {
			if cellText(row[0]) == "index" && cellText(row[1]) == edit.Name && edit.Action != "add" {
				skip = true
			}
		}
		if !skip {
			p.SQL = append(p.SQL, cellText(row[2])+";")
		}
	}
	// During rebuild the old indexes are already removed with the table.
	for _, x := range d.Indexes {
		if x.Action != "drop" {
			names := []string{}
			for _, n := range x.Columns {
				names = append(names, quote(n))
			}
			u := ""
			if x.Unique {
				u = "UNIQUE "
			}
			p.SQL = append(p.SQL, "CREATE "+u+"INDEX main."+quote(x.Name)+" ON "+quote(b.Target.Table)+" ("+strings.Join(names, ",")+");")
		}
	}
	_ = rowidAlias
	return p, nil
}
func parseLiteralDefault(raw string) (tableedit.Default, error) {
	t := strings.TrimSpace(raw)
	if strings.EqualFold(t, "NULL") {
		return tableedit.Default{Kind: "null"}, nil
	}
	if len(t) >= 2 && t[0] == '\'' && t[len(t)-1] == '\'' {
		v := strings.ReplaceAll(t[1:len(t)-1], "''", "'")
		return tableedit.Default{Kind: "text", Value: &v}, nil
	}
	if sqliteNumericLiteral.MatchString(t) {
		return tableedit.Default{Kind: "numeric", Value: &t}, nil
	}
	return tableedit.Default{}, tableedit.ErrUnsupported
}
func (s *Session) StructureApply(ctx context.Context, b tableedit.Baseline, sql []string) tableedit.Execution {
	xs := s.StructureApplySteps(ctx, b, tableedit.Plan{SQL: sql})
	if len(xs) > 0 {
		return xs[0]
	}
	return tableedit.Execution{State: "notStarted"}
}
func (s *Session) StructureApplySteps(ctx context.Context, b tableedit.Baseline, p tableedit.Plan) []tableedit.Execution {
	out := make([]tableedit.Execution, len(p.SQL))
	for i := range out {
		out[i].State = "notStarted"
	}
	fail := func(state, msg string) []tableedit.Execution {
		for i := range out {
			out[i] = tableedit.Execution{State: state, Message: msg}
		}
		return out
	}
	if s.readOnly || s.TransactionStatus() != "idle" || len(p.SQL) == 0 {
		return fail("notStarted", "The structure session is not writable and idle.")
	}
	if err := s.checkIdentity(); err != nil {
		return fail("notStarted", "The database file changed.")
	}
	if err := s.exec(ctx, "PRAGMA foreign_keys=OFF"); err != nil {
		return fail("notStarted", "Cannot prepare foreign-key verification.")
	}
	defer func() { _ = s.exec(context.Background(), "PRAGMA foreign_keys=ON") }()
	if err := s.exec(ctx, "BEGIN IMMEDIATE"); err != nil {
		return fail("notStarted", "Cannot acquire the database write lock.")
	}
	defer func() { _ = s.exec(context.Background(), "ROLLBACK") }()
	current, err := s.StructureLoad(ctx, b.Target)
	if err != nil || current.Fingerprint != b.Fingerprint {
		return fail("notStarted", "The captured schema changed; prepare a new preview.")
	}
	// Compare sorted typed row hashes without retaining the source rows in memory.
	var original string
	var originalCount int64
	if !b.Target.Create {
		original, originalCount, err = s.structureValueDigest(ctx, b.Target.Table, b.Columns)
		if err != nil {
			if errors.Is(err, ErrStructureDigestQuota) {
				return fail("notStarted", "Exact-value verification exceeds the temporary storage limit; no changes were started.")
			}
			return fail("notStarted", "Cannot capture exact original values.")
		}
	}
	for _, sql := range p.SQL {
		if err = s.exec(ctx, sql); err != nil {
			return fail("rolledBack", "The structure transaction failed and was rolled back.")
		}
	}
	if !b.Target.Create {
		observedTable := b.Target.Table
		if p.ResultTarget != nil {
			observedTable = p.ResultTarget.Table
		}
		copiedColumns := append([]tableedit.ObservedColumn(nil), b.Columns...)
		for i := range copiedColumns {
			if name, ok := p.RenamedColumns[copiedColumns[i].Name]; ok {
				copiedColumns[i].Name = name
			}
		}
		after, afterCount, e := s.structureValueDigest(ctx, observedTable, copiedColumns)
		if e != nil || original != after || originalCount != afterCount {
			return fail("rolledBack", "The change would alter stored values or storage classes; no changes were committed.")
		}
	}
	violations, _, err := s.query(ctx, "PRAGMA main.foreign_key_check")
	if err != nil || len(violations) > 0 {
		return fail("rolledBack", "Foreign-key validation failed; no changes were committed.")
	}
	if err = s.exec(ctx, "COMMIT"); err != nil {
		return fail("unknown", "The structure COMMIT outcome is unknown. Inspect the schema before preparing another change.")
	}
	return fail("applied", "")
}
