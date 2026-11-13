package mysql

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"

	"fmt"
	wire "github.com/go-mysql-org/go-mysql/mysql"
	"regexp"
	"strconv"
	"strings"
)

func (s *Session) StructureLoad(ctx context.Context, t tableedit.Target) (tableedit.Baseline, error) {
	var b tableedit.Baseline
	var loadErr error
	response := s.executeWith(ctx, protocol.Command{}, func(_ *collector, _ *wire.Result) error {
		b, loadErr = s.readStructure(t)
		if loadErr != nil {
			return &adapter.ConnectionError{Category: "validation", Message: loadErr.Error()}
		}
		return nil
	})
	if loadErr != nil {
		return b, loadErr
	}
	if response.Type == "error" {
		return b, tableedit.ErrUnsupported
	}
	return b, nil
}
func (s *Session) readStructure(t tableedit.Target) (tableedit.Baseline, error) {
	observe := t.Reconcile
	t.Reconcile = false
	b := tableedit.Baseline{Target: t, Engine: "mysql", Columns: []tableedit.ObservedColumn{}, Keys: []tableedit.Key{}, Indexes: []tableedit.Index{}, Limitations: []string{"Only ordinary nonpartitioned InnoDB tables are supported. Appended columns are nullable; required-column backfills and physical reconstruction require a separate reviewed plan.", "MySQL DDL implicitly commits. Metadata rechecks are best effort and cannot close a concurrent DDL race or prove drop/recreate identity. Stop and Discard do not undo applied DDL.", "Text literal defaults containing backslashes/control characters and literal TEXT defaults are unsupported; expression defaults use an explicit bounded SQL expression."}}
	if !t.Valid() || s.TransactionStatus() != "idle" {
		return b, tableedit.ErrUnsupported
	}
	if err := s.requireNativeMetadataEncoding(); err != nil {
		return b, err
	}

	meta, e := s.work.client.Execute(`SELECT VERSION(), @@version_comment, @@sql_mode, @@lower_case_table_names, @@character_set_connection, @@collation_connection, DATABASE(), CURRENT_USER(), @@server_uuid`)
	if e != nil {
		return b, e
	}
	defer meta.Close()
	if meta.RowNumber() != 1 {
		return b, tableedit.ErrUnsupported
	}
	context := []string{}
	for i := 0; i < 9; i++ {
		v, e := ownedStructureString(meta, 0, i)
		if e != nil {
			return b, tableedit.ErrUnsupported
		}
		context = append(context, v)
	}
	version := strings.Split(strings.Split(context[0], "-")[0], ".")
	if len(version) < 3 || (!strings.Contains(strings.ToLower(context[1]), "mysql") || strings.Contains(strings.ToLower(strings.Join(context[:2], " ")), "mariadb") || strings.Contains(strings.ToLower(context[1]), "percona")) {
		return b, tableedit.ErrUnsupported
	}
	major, _ := strconv.Atoi(version[0])
	minor, _ := strconv.Atoi(version[1])
	patch, _ := strconv.Atoi(version[2])
	if major < 8 || major == 8 && minor == 0 && patch < 30 {
		return b, tableedit.ErrUnsupported
	}
	// utf8mb4 is needed to preserve exact text in generated definitions.
	if context[4] != "utf8mb4" {
		return b, tableedit.ErrUnsupported
	}
	schema, e := s.work.client.Execute(`SELECT SCHEMA_NAME, DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE BINARY SCHEMA_NAME=BINARY ?`, t.Schema)
	if e != nil {
		return b, e
	}
	defer schema.Close()
	if schema.RowNumber() != 1 {
		return b, tableedit.ErrUnsupported
	}
	for i := 0; i < 3; i++ {
		v, _ := ownedStructureString(schema, 0, i)
		context = append(context, v)
	}
	if context[9] != t.Schema {
		return b, tableedit.ErrUnsupported
	}
	mode, err := strconv.ParseInt(context[3], 10, 64)
	if err != nil {
		return b, tableedit.ErrUnsupported
	}
	identitySQL, err := nativeBrowseTargetSQL(mode)
	if err != nil {
		return b, tableedit.ErrUnsupported
	}
	identities, err := s.work.client.Execute(identitySQL, t.Schema, t.Table)
	if err != nil {
		return b, err
	}
	count := identities.RowNumber()
	if count > 1 {
		identities.Close()
		return b, tableedit.ErrUnsupported
	}
	if count == 1 {
		schema, _ := ownedStructureString(identities, 0, 0)
		table, _ := ownedStructureString(identities, 0, 1)
		if schema != t.Schema || table != t.Table {
			identities.Close()
			return b, tableedit.ErrUnsupported
		}
	}
	identities.Close()
	b.Scope = tableedit.Fingerprint(context)
	tables, e := s.work.client.Execute(`SELECT TABLE_TYPE, ENGINE, CREATE_OPTIONS, TABLE_COLLATION, TABLE_COMMENT FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ?`, t.Schema, t.Table)
	if e != nil {
		return b, e
	}
	defer tables.Close()
	if tables.RowNumber() == 0 {
		if !t.Create {
			return b, tableedit.ErrUnsupported
		}
		charset, _ := ownedStructureString(schema, 0, 1)
		collation, _ := ownedStructureString(schema, 0, 2)
		b.Facts = newStructureFacts(charset, collation)
		b.Facts.ServerVersion = major*10000 + minor*100 + patch
		b.Facts.EngineContext = []sc.Option{{Name: "sqlMode", Value: context[2]}}
		tableedit.Summarize(&b)
		b.Fingerprint = tableedit.Fingerprint([]any{context, t})
		return b, nil
	}
	if t.Create && observe {
		t.Create = false
		b.Target.Create = false
	}
	if t.Create || tables.RowNumber() != 1 {
		return b, tableedit.ErrUnsupported
	}
	kind, _ := ownedStructureString(tables, 0, 0)
	engine, _ := ownedStructureString(tables, 0, 1)
	options, _ := ownedStructureString(tables, 0, 2)
	collation, _ := ownedStructureString(tables, 0, 3)
	comment, _ := ownedStructureString(tables, 0, 4)
	if kind != "BASE TABLE" || engine != "InnoDB" || strings.Contains(strings.ToLower(options), "partition") {
		return b, tableedit.ErrUnsupported
	}
	ddl, e := s.work.client.Execute("SHOW CREATE TABLE " + QuoteIdentifier(t.Schema) + "." + QuoteIdentifier(t.Table))
	if e != nil {
		return b, e
	}
	defer ddl.Close()
	if ddl.RowNumber() != 1 {
		return b, tableedit.ErrUnsupported
	}
	definition, _ := ownedStructureString(ddl, 0, 1)
	if len(definition) > tableedit.MaxSQLBytes {
		return b, tableedit.ErrUnsupported
	}
	cols, e := s.work.client.Execute(`SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT FROM information_schema.COLUMNS WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? ORDER BY ORDINAL_POSITION LIMIT 129`, t.Schema, t.Table)
	if e != nil {
		return b, e
	}
	defer cols.Close()
	if cols.RowNumber() > tableedit.MaxColumns {
		return b, tableedit.ErrUnsupported
	}
	for i := 0; i < cols.RowNumber(); i++ {
		name, _ := ownedStructureString(cols, i, 0)
		typ, _ := ownedStructureString(cols, i, 1)
		nullable, _ := ownedStructureString(cols, i, 2)
		value, _ := cols.GetValue(i, 3)
		var d *string
		if value != nil {
			v, _ := ownedStructureString(cols, i, 3)
			d = &v
		}
		b.Columns = append(b.Columns, tableedit.ObservedColumn{Name: name, NativeType: typ, Nullable: nullable == "YES", DefaultExpression: d})
	}
	b.Guard = tableedit.Fingerprint([]string{kind, engine, options, collation})
	b.Facts, e = s.readStructureFacts(t, engine, collation, options, comment)
	if e != nil {
		return b, e
	}
	b.Facts.ServerVersion = major*10000 + minor*100 + patch
	tableedit.Summarize(&b)
	b.Fingerprint = tableedit.Fingerprint([]any{context, kind, engine, options, collation, definition, b.Columns, b.Facts})
	return b, nil
}

var structureNumeric = regexp.MustCompile(`^[+-]?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$`)

func structureColumn(c tableedit.Column) (string, error) {
	if c.Type.Reference != nil {
		return "", tableedit.ErrUnsupported
	}
	if !c.Valid() {
		return "", tableedit.ErrInvalid
	}
	var typ string
	switch c.Type.Kind {
	case "integer":
		typ = "INT"
	case "bigint":
		typ = "BIGINT"
	case "varchar":
		typ = fmt.Sprintf("VARCHAR(%d)", c.Type.Length)
	case "numeric":
		typ = fmt.Sprintf("DECIMAL(%d,%d)", c.Type.Precision, c.Type.Scale)
	case "text":
		typ = "TEXT"
	default:
		return "", tableedit.ErrUnsupported
	}
	out := QuoteIdentifier(c.Name) + " " + typ
	if c.Generated != nil && c.Generated.Storage != "none" {
		expr, err := tableedit.ExpressionSlot("mysql", c.Generated.Expression)
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
		if c.Type.Kind == "text" {
			return "", tableedit.ErrUnsupported
		}
		out += " DEFAULT NULL"
	case "text":
		if c.Type.Kind != "varchar" {
			return "", tableedit.ErrUnsupported
		}
		for _, v := range *c.Default.Value {
			if v == '\\' || v < 32 || v == 127 {
				return "", tableedit.ErrUnsupported
			}
		}
		out += " DEFAULT '" + strings.ReplaceAll(*c.Default.Value, "'", "''") + "'"
	case "numeric":
		if c.Type.Kind != "integer" && c.Type.Kind != "bigint" && c.Type.Kind != "numeric" || !structureNumeric.MatchString(*c.Default.Value) {
			return "", tableedit.ErrInvalid
		}
		out += " DEFAULT " + *c.Default.Value
	case "expression":
		expr, err := tableedit.ExpressionSlot("mysql", *c.Default.Value)
		if err != nil {
			return "", err
		}
		out += " DEFAULT " + expr
	default:
		return "", tableedit.ErrInvalid
	}
	if c.Identity != nil && c.Identity.Kind != "none" {
		if c.Identity.Kind != "autoIncrement" {
			return "", tableedit.ErrUnsupported
		}
		out += " AUTO_INCREMENT"
	}
	return out, nil
}
func (s *Session) StructureRender(b tableedit.Baseline, d tableedit.Draft) ([]string, []string, error) {
	if !d.Valid() || !b.Target.Valid() {
		return nil, nil, tableedit.ErrInvalid
	}
	parts := []string{}
	seen := map[string]bool{}
	for _, c := range d.Columns {
		key := strings.ToLower(c.Name)
		if seen[key] {
			return nil, nil, tableedit.ErrInvalid
		}
		seen[key] = true
		for _, old := range b.Columns {
			if strings.EqualFold(old.Name, c.Name) {
				return nil, nil, tableedit.ErrInvalid
			}
		}
		x, e := structureColumn(c)
		if e != nil {
			return nil, nil, e
		}
		parts = append(parts, x)
	}
	target := QuoteIdentifier(b.Target.Schema) + "." + QuoteIdentifier(b.Target.Table)
	sql := "CREATE TABLE " + target + " (" + strings.Join(parts, ", ") + ") ENGINE=InnoDB;"
	if !b.Target.Create {
		if len(parts) != 1 || !d.Columns[0].Nullable {
			return nil, nil, tableedit.ErrInvalid
		}
		sql = "ALTER TABLE " + target + " ADD COLUMN " + parts[0] + ";"
	}
	return []string{sql}, []string{"MySQL DDL implicitly commits and may lock, rebuild or scan a table. Apply uses a dedicated session with a 5-second lock_wait_timeout. Metadata rechecks are best effort; concurrent DDL can race. Stop and Discard cannot undo acknowledged DDL. No automatic replay."}, nil
}
func (s *Session) StructureApply(ctx context.Context, b tableedit.Baseline, sql []string) tableedit.Execution {
	return s.applyStructureStep(ctx, b, sql, nil)
}
func (s *Session) applyStructureStep(ctx context.Context, b tableedit.Baseline, sql []string, refs []tableedit.Baseline) tableedit.Execution {
	dispatched := false
	applied := false
	response := s.executeWith(ctx, protocol.Command{Type: "structure.apply"}, func(_ *collector, _ *wire.Result) error {
		if len(sql) != 1 {
			return &adapter.ConnectionError{Category: "validation", Message: tableedit.ErrInvalid.Error()}
		}
		if r, e := s.work.client.Execute("SET SESSION lock_wait_timeout = 5"); e != nil {
			return e
		} else {
			r.Close()
		}
		for _, ref := range refs {
			observed, err := s.readStructure(ref.Target)
			if err != nil {
				return err
			}
			if observed.Fingerprint != ref.Fingerprint {
				return &adapter.ConnectionError{Category: "conflict", Message: tableedit.ErrStale.Error()}
			}
		}
		fresh, e := s.readStructure(b.Target)
		if e != nil {
			return e
		}
		if fresh.Fingerprint != b.Fingerprint {
			return &adapter.ConnectionError{Category: "conflict", Message: tableedit.ErrStale.Error()}
		}
		if ctx.Err() != nil {
			return &adapter.ConnectionError{Category: "cancelled", Message: "Cancelled before DDL dispatch."}
		}
		dispatched = true
		execute := func() error {
			r, e := s.work.client.Execute(sql[0])
			if r != nil {
				r.Close()
			}
			return e
		}
		var execErr error
		if s.structureExecuteOverride != nil {
			execErr = s.structureExecuteOverride(execute)
		} else {
			execErr = execute()
		}
		if execErr != nil {
			return execErr
		}
		applied = true
		return nil
	})
	if applied {
		return tableedit.Execution{State: "applied"}
	}
	if !dispatched {
		return tableedit.Execution{State: "notStarted", Message: "No DDL was sent. Reconcile the table and prepare a new preview."}
	}
	if response.OutcomeUnknown || !response.Connected {
		return tableedit.Execution{State: "unknown", Message: "DDL acknowledgement was lost. The change may have been applied."}
	}
	return tableedit.Execution{State: "failed", Message: "MySQL rejected the DDL. No automatic retry was attempted."}
}

// Driver strings borrow pooled result buffers. Snapshot every retained scalar
// before Close returns that result to the pool for the next metadata read.
func ownedStructureString(result *wire.Result, row, column int) (string, error) {
	value, err := result.GetString(row, column)
	return strings.Clone(value), err
}
