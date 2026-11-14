package mysql

import (
	"dbeer/helper/internal/tableedit"
	"errors"
	"reflect"
	"sort"
	"strings"
)

func (s *Session) myAdvancedCapture(b *tableedit.Baseline) error {
	if strings.HasPrefix(strings.ToUpper(strings.TrimSpace(b.NativeDefinition)), "CREATE TEMPORARY TABLE") {
		return errors.New("Temporary tables belong to their original owning physical SQL-tab session. This dedicated structure operation does not attach to or edit another tab's temporary relation.")
	}
	if b.Target.Create || b.Facts == nil || b.Facts.Table.Storage.Value == nil {
		return nil
	}
	engine := *b.Facts.Table.Storage.Value
	partitioned := false
	for _, option := range b.Facts.Table.Options.Items {
		partitioned = partitioned || option.Name == "createOptions" && strings.Contains(strings.ToLower(option.Value), "partition")
	}
	if engine == "InnoDB" && !partitioned {
		return nil
	}
	if engine != "InnoDB" && engine != "MyISAM" {
		return errors.New("Only InnoDB and MyISAM have proven native authoring properties; other storage-engine capabilities are not inferred.")
	}
	v := b.Facts.ServerVersion
	if !(v >= 80030 && v < 80100 || v >= 80400 && v < 80500) {
		return errors.New("Advanced MySQL authoring is proven for Oracle MySQL 8.0.30+ in the 8.0 series and 8.4 LTS.")
	}
	if !b.Facts.Proof {
		return errors.New("Advanced MySQL authoring requires complete SELECT/TRIGGER metadata visibility without active roles or partial revokes.")
	}
	if partitioned && engine != "InnoDB" {
		return errors.New("Oracle MySQL native partitioning requires InnoDB; MyISAM partition authoring is not supported by these servers.")
	}
	if _, _, _, ok := mysqlReconstructionDefinition(b.NativeDefinition, b.Facts); !ok {
		return errors.New("Complete native column, constraint/index and table-suffix properties are required.")
	}
	proof := &tableedit.AdvancedEvidence{Targets: []tableedit.Target{b.Target}, Rows: map[string][]map[string]any{}}
	capture := func(key, sql string, args ...any) error {
		rows, e := s.myPhysicalRows(sql, args...)
		if e != nil {
			return e
		}
		out := []map[string]any{}
		for _, row := range rows {
			m := map[string]any{}
			for i, v := range row {
				if v == nil {
					m[string(rune('A'+i))] = nil
				} else {
					m[string(rune('A'+i))] = *v
				}
			}
			out = append(out, m)
		}
		proof.Rows[key] = out
		return nil
	}
	if e := capture("partitions", `SELECT PARTITION_NAME,PARTITION_ORDINAL_POSITION,PARTITION_METHOD,PARTITION_EXPRESSION,PARTITION_DESCRIPTION,SUBPARTITION_NAME,SUBPARTITION_ORDINAL_POSITION,SUBPARTITION_METHOD,SUBPARTITION_EXPRESSION,TABLESPACE_NAME,PARTITION_COMMENT,NODEGROUP FROM information_schema.PARTITIONS WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? ORDER BY PARTITION_ORDINAL_POSITION,SUBPARTITION_ORDINAL_POSITION LIMIT 130`, b.Target.Schema, b.Target.Table); e != nil {
		return e
	}
	if len(proof.Rows["partitions"]) > 128 {
		return errors.New("Complete partition/subpartition proof is bounded to 128 entries.")
	}
	if e := capture("engines", `SELECT ENGINE,SUPPORT,TRANSACTIONS,XA,SAVEPOINTS FROM information_schema.ENGINES WHERE ENGINE IN ('InnoDB','MyISAM') ORDER BY ENGINE`); e != nil {
		return e
	}
	if e := capture("triggers", `SELECT TRIGGER_SCHEMA,TRIGGER_NAME,EVENT_MANIPULATION,ACTION_ORDER,ACTION_CONDITION,ACTION_STATEMENT,ACTION_ORIENTATION,ACTION_TIMING,SQL_MODE,DEFINER,CHARACTER_SET_CLIENT,COLLATION_CONNECTION,DATABASE_COLLATION FROM information_schema.TRIGGERS WHERE BINARY EVENT_OBJECT_SCHEMA=BINARY ? AND BINARY EVENT_OBJECT_TABLE=BINARY ? ORDER BY BINARY TRIGGER_SCHEMA,BINARY TRIGGER_NAME`, b.Target.Schema, b.Target.Table); e != nil {
		return e
	}
	kinds := []string{}
	if partitioned {
		kinds = append(kinds, "mySQLPartitions")
	}
	if engine == "MyISAM" {
		kinds = append(kinds, "myISAM")
	}
	reasons := map[string]string{"foreignKey": "Oracle MySQL partitioned InnoDB and MyISAM tables do not support foreign keys; no constraint is silently omitted.", "hierarchy": "Partition/storage/strict online operations use the separate physical Preview/Apply workflow; no ordinary edit implicitly repartitions or converts an engine."}
	b.Advanced = tableedit.NewAdvancedSupport(kinds, "table", 1, engine == "MyISAM", reasons)
	publicKind := "table"
	if partitioned {
		publicKind = "partitionedTable"
	}
	b.Advanced.Relations = []tableedit.AdvancedRelationFact{{Target: b.Target, Kind: publicKind, Persistence: "permanent", StorageEngine: engine, Parents: []tableedit.Target{}, Policies: []tableedit.AdvancedPolicyFact{}}}
	b.AdvancedEvidence = proof
	b.Limitations[0] = "Advanced authoring retains the complete native partition/table suffix, unaffected columns/indexes/constraints, engine facts and dependencies. Every concrete edit needs Preview. MySQL DDL implicitly commits; MyISAM writes are nontransactional."
	b.Fingerprint = tableedit.Fingerprint([]any{b.Fingerprint, proof})
	return nil
}
func myAdvancedPrepare(b tableedit.Baseline, d tableedit.Draft) error {
	if b.Advanced == nil {
		return nil
	}
	if e := tableedit.CheckAdvancedDraft(b, d); e != nil {
		return e
	}
	if !myPhysicalMode(b, "STRICT_ALL_TABLES") && !myPhysicalMode(b, "STRICT_TRANS_TABLES") {
		return errors.New("Advanced MySQL authoring requires an already strict SQL mode; the helper never changes SQL mode implicitly.")
	}
	for _, k := range d.Keys {
		if k.Kind == "foreign" {
			return errors.New("Oracle MySQL partitioned InnoDB and MyISAM tables do not support foreign keys; no constraint is silently omitted.")
		}
	}
	hasIdentity := false
	for _, c := range b.Facts.Table.Columns.Items {
		hasIdentity = hasIdentity || c.Identity.Value != nil && c.Identity.Value.Kind == "autoIncrement"
	}
	rebuild := len(d.Columns)+len(d.Indexes)+len(d.Keys) > 0
	for _, c := range d.Changes {
		old, ok := tableedit.FindColumn(b, c.Name)
		if !ok {
			return tableedit.ErrInvalid
		}
		if old.Generated.Value == nil || old.Identity.Value == nil || (old.Generated.Value.Kind != "none" || old.Identity.Value.Kind != "none") && c.Generated == nil && c.Identity == nil {
			return errors.New("The selected advanced column has generation/AUTO_INCREMENT semantics; review its native row effects separately.")
		}
		if c.Type != nil && !tableedit.CanWiden(old, *c.Type) || c.UsingExpression != nil || c.Unsigned != nil || c.Charset != nil || c.Collation != nil {
			return errors.New("Advanced type authoring supports lossless integer-to-bigint and varchar widening, preserving signedness/encoding; value-changing conversion proof is not implemented.")
		}
		if c.Identity != nil && c.Identity.Kind == "autoIncrement" && !myPhysicalMode(b, "NO_AUTO_VALUE_ON_ZERO") {
			return errors.New("Enabling advanced AUTO_INCREMENT requires already-present NO_AUTO_VALUE_ON_ZERO to preserve existing zero values; SQL mode is never changed implicitly.")
		}
		rebuild = rebuild || c.Type != nil || c.Nullable != nil || c.Drop || c.Generated != nil || c.Identity != nil
		if c.RenameTo != nil {
			for _, p := range b.AdvancedEvidence.Rows["partitions"] {
				for _, key := range []string{"D", "I"} {
					expr, _ := p[key].(string)
					if expr != "" && !tableedit.MySQLExpressionExcludesColumn(expr, c.Name, b.Facts) {
						return errors.New("Partition/subpartition-key rename needs explicit expression rewriting; this authoring path preserves the native partition suffix unchanged.")
					}
				}
			}
		}
	}
	if hasIdentity && rebuild && !myPhysicalMode(b, "NO_AUTO_VALUE_ON_ZERO") {
		return errors.New("An advanced ALTER may rebuild AUTO_INCREMENT rows. Already-present NO_AUTO_VALUE_ON_ZERO is required to preserve stored zero values; SQL mode is never changed implicitly.")
	}
	for _, x := range d.Indexes {
		if x.Action != "drop" && x.Unique {
			names := x.Columns
			if x.Definition != nil {
				names = []string{}
				for _, key := range x.Definition.Terms {
					if key.Column == nil {
						return errors.New("Partitioned UNIQUE indexes require proven direct partition-key coverage.")
					}
					names = append(names, *key.Column)
				}
			}
			if e := myAdvancedUnique(b, names); e != nil {
				return e
			}
		}
	}
	for _, k := range d.Keys {
		if k.Action != "drop" && (k.Kind == "primary" || k.Kind == "unique") {
			if e := myAdvancedUnique(b, k.Columns); e != nil {
				return e
			}
		}
	}
	return nil
}
func myAdvancedUnique(b tableedit.Baseline, names []string) error {
	for _, p := range b.AdvancedEvidence.Rows["partitions"] {
		for _, key := range []string{"D", "I"} {
			expr, _ := p[key].(string)
			tokens, ok := mysqlIndexMetadataTokens(expr, "", 0)
			if !ok {
				return tableedit.ErrUnsupported
			}
			for _, t := range tokens {
				if t.kind != "identifier" && t.kind != "word" {
					continue
				}
				for _, c := range b.Columns {
					if strings.EqualFold(c.Name, t.value) {
						found := false
						for _, n := range names {
							found = found || strings.EqualFold(n, c.Name)
						}
						if !found {
							return errors.New("Every MySQL UNIQUE/PRIMARY index must include every partition and subpartition key column.")
						}
					}
				}
			}
		}
	}
	return nil
}
func myAdvancedPreserved(a, b tableedit.Baseline, c tableedit.Condition) bool {
	if a.Advanced == nil {
		return b.Advanced == nil
	}
	if b.Advanced == nil || a.AdvancedEvidence == nil || b.AdvancedEvidence == nil {
		return false
	}
	pa, pb := tableedit.CloneAdvancedEvidence(a.AdvancedEvidence), tableedit.CloneAdvancedEvidence(b.AdvancedEvidence)
	if c.Operation.Kind == "renameTable" {
		pa.Targets = append([]tableedit.Target(nil), pb.Targets...)
	}
	if !reflect.DeepEqual(pa, pb) {
		return false
	}
	if c.Operation.Change != nil && (c.Operation.Change.Generated != nil || c.Operation.Change.Identity != nil) {
		return myAdvancedGenerationPreserved(a, b, c)
	}
	ca, oa, sa, ok := mysqlReconstructionDefinition(a.NativeDefinition, a.Facts)
	if !ok {
		return false
	}
	cb, ob, sb, ok := mysqlReconstructionDefinition(b.NativeDefinition, b.Facts)
	if !ok || sa != sb {
		return false
	}
	op := c.Operation
	switch op.Kind {
	case "renameTable", "backfill", "reorder":
	case "renameColumn":
		if op.Change == nil || op.Change.RenameTo == nil {
			return false
		}
		from, to := op.Change.Name, *op.Change.RenameTo
		replace := func(raw string) (string, bool) {
			tokens, ok := mysqlIndexMetadataTokens(raw, "", 0)
			if !ok {
				return "", false
			}
			for i := len(tokens) - 1; i >= 0; i-- {
				t := tokens[i]
				if t.kind == "identifier" && t.value == from {
					raw = raw[:t.start] + QuoteIdentifier(to) + raw[t.end:]
				}
			}
			return raw, true
		}
		next := map[string]string{}
		for n, raw := range ca {
			changed, ok := replace(raw)
			if !ok {
				return false
			}
			if n == from {
				n = to
			}
			next[n] = changed
		}
		ca = next
		for i, raw := range oa {
			changed, ok := replace(raw)
			if !ok {
				return false
			}
			oa[i] = changed
		}
	case "addColumn":
		if op.Column == nil {
			return false
		}
		delete(cb, op.Column.Name)
	case "dropColumn":
		if op.Change == nil {
			return false
		}
		delete(ca, op.Change.Name)
	case "changeColumn":
		if op.Change == nil {
			return false
		}
		change := *op.Change
		reviewedBackfill := op.Name != nil && *op.Name == change.Name && change.Nullable != nil && !*change.Nullable
		na, ok := myAdvancedColumn(ca[change.Name], change, a, reviewedBackfill)
		if !ok {
			return false
		}
		nb, ok := myAdvancedColumn(cb[change.Name], change, b, reviewedBackfill)
		if !ok || !reflect.DeepEqual(na, nb) {
			return false
		}
		delete(ca, change.Name)
		delete(cb, change.Name)
	case "addIndex", "dropIndex", "addKey", "dropKey":
		name := ""
		primary := false
		if op.Index != nil {
			name = op.Index.Name
		}
		if op.Key != nil {
			name = op.Key.Name
			primary = op.Key.Kind == "primary"
		}
		filter := func(rows []string) []string {
			out := []string{}
			for _, raw := range rows {
				tokens, ok := mysqlIndexMetadataTokens(raw, "", 0)
				if !ok {
					return nil
				}
				skip := primary && len(tokens) > 0 && strings.EqualFold(tokens[0].value, "PRIMARY")
				for _, t := range tokens {
					if t.kind == "identifier" {
						skip = skip || t.value == name
						break
					}
				}
				if !skip {
					out = append(out, raw)
				}
			}
			return out
		}
		oa, ob = filter(oa), filter(ob)
		if primary {
			for _, name := range op.Key.Columns {
				change := tableedit.ColumnChange{Name: name, Nullable: new(bool)}
				na, ok := myAdvancedColumn(ca[name], change, a)
				if !ok {
					return false
				}
				nb, ok := myAdvancedColumn(cb[name], change, b)
				if !ok || !reflect.DeepEqual(na, nb) {
					return false
				}
				delete(ca, name)
				delete(cb, name)
			}
		}
	default:
		return false
	}
	sort.Strings(oa)
	sort.Strings(ob)
	return reflect.DeepEqual(ca, cb) && reflect.DeepEqual(oa, ob)
}
func myAdvancedColumn(raw string, change tableedit.ColumnChange, b tableedit.Baseline, backfillDefault ...bool) ([]string, bool) {
	mode := ""
	for _, o := range b.Facts.EngineContext {
		if o.Name == "sqlMode" {
			mode = o.Value
		}
	}
	tokens, ok := mysqlIndexMetadataTokens(raw, mode, 0)
	if !ok || len(tokens) < 2 {
		return nil, false
	}
	out := []string{}
	column, _ := tableedit.FindColumn(b, change.Name)
	for i := 0; i < len(tokens); i++ {
		t := tokens[i]
		if strings.EqualFold(t.value, "CHARACTER") && i+2 < len(tokens) && strings.EqualFold(tokens[i+1].value, "SET") {
			if column.Charset.Value == nil || !strings.EqualFold(*column.Charset.Value, tokens[i+2].value) {
				return nil, false
			}
			i += 2
			continue
		}
		if strings.EqualFold(t.value, "COLLATE") && i+1 < len(tokens) {
			if column.Collation.Value == nil || !strings.EqualFold(column.Collation.Value.Name, tokens[i+1].value) {
				return nil, false
			}
			i++
			continue
		}
		if change.Type != nil && i == 1 {
			if t.kind != "word" {
				return nil, false
			}
			if i+1 < len(tokens) && tokens[i+1].value == "(" {
				depth := 0
				for i+1 < len(tokens) {
					i++
					if tokens[i].value == "(" {
						depth++
					}
					if tokens[i].value == ")" {
						depth--
						if depth == 0 {
							break
						}
					}
				}
				if depth != 0 {
					return nil, false
				}
			}
			continue
		}
		// A nullable ADD in this exact reviewed backfill has no authored default;
		// MySQL prints DEFAULT NULL and removes it when NOT NULL is enforced.
		if len(backfillDefault) == 1 && backfillDefault[0] && change.Nullable != nil && !*change.Nullable && column.Default.Value != nil && (column.Default.Value.Kind == "none" || column.Default.Value.Kind == "sqlNull") && t.kind == "word" && strings.EqualFold(t.value, "DEFAULT") && i+1 < len(tokens) && tokens[i+1].kind == "word" && strings.EqualFold(tokens[i+1].value, "NULL") {
			i++
			continue
		}
		if change.Default != nil && t.kind == "word" && strings.EqualFold(t.value, "DEFAULT") {
			i++
			if i >= len(tokens) {
				return nil, false
			}
			if tokens[i].value == "-" || tokens[i].value == "+" {
				i++
				if i >= len(tokens) {
					return nil, false
				}
			}
			if tokens[i].kind == "word" && strings.HasPrefix(tokens[i].value, "_") && i+1 < len(tokens) && tokens[i+1].kind == "string" {
				i++
			}
			if tokens[i].value == "(" {
				depth := 1
				for depth > 0 && i+1 < len(tokens) {
					i++
					if tokens[i].value == "(" {
						depth++
					}
					if tokens[i].value == ")" {
						depth--
					}
				}
				if depth != 0 {
					return nil, false
				}
			}
			continue
		}
		if change.Nullable != nil && t.kind == "word" {
			if strings.EqualFold(t.value, "NOT") && i+1 < len(tokens) && strings.EqualFold(tokens[i+1].value, "NULL") {
				i++
				continue
			}
			if strings.EqualFold(t.value, "NULL") {
				continue
			}
		}
		out = append(out, t.kind+":"+t.value)
	}
	return out, true
}
func (*Session) SupportsAdvancedKinds() bool { return true }
