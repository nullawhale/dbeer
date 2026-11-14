package mysql

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"errors"
	"fmt"
	wire "github.com/go-mysql-org/go-mysql/mysql"
	"reflect"
	"sort"
	"strconv"
	"strings"
)

type myPhysicalEvidence struct {
	Baseline        tableedit.Baseline
	BaselineProof   string
	Partitions      [][]*string
	Engine          string
	Engines         [][]*string
	SQL             []string
	Child           *tableedit.Baseline
	ChildProof      string
	ChildPartitions [][]*string
}

func myPhysicalProof(b tableedit.Baseline) string {
	return tableedit.Fingerprint([]any{b, b.NativeDefinition, b.Scope, b.Guard, b.Facts, b.Attributes})
}
func (s *Session) myPhysicalRows(sql string, args ...any) ([][]*string, error) {
	r, e := s.work.client.Execute(sql, args...)
	if e != nil {
		return nil, tableedit.ErrUnsupported
	}
	defer r.Close()
	out := [][]*string{}
	size := 0
	if r.RowNumber() > 2048 {
		return nil, tableedit.ErrUnsupported
	}
	for i := 0; i < r.RowNumber(); i++ {
		row := []*string{}
		for j := 0; j < r.ColumnNumber(); j++ {
			v, e := r.GetValue(i, j)
			if e != nil {
				return nil, tableedit.ErrUnsupported
			}
			if v == nil {
				row = append(row, nil)
			} else {
				str, e := ownedStructureString(r, i, j)
				if e != nil {
					return nil, tableedit.ErrUnsupported
				}
				size += len(str)
				if size > 2<<20 {
					return nil, tableedit.ErrUnsupported
				}
				row = append(row, &str)
			}
		}
		out = append(out, row)
	}
	return out, nil
}
func (s *Session) myPhysicalPartitions(t tableedit.Target) ([][]*string, error) {
	return s.myPhysicalRows(`SELECT PARTITION_NAME,PARTITION_ORDINAL_POSITION,PARTITION_METHOD,PARTITION_EXPRESSION,PARTITION_DESCRIPTION,SUBPARTITION_NAME,SUBPARTITION_METHOD,SUBPARTITION_EXPRESSION,TABLESPACE_NAME,PARTITION_COMMENT,NODEGROUP FROM information_schema.PARTITIONS WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? ORDER BY PARTITION_ORDINAL_POSITION,SUBPARTITION_ORDINAL_POSITION LIMIT 130`, t.Schema, t.Table)
}
func (s *Session) myPhysicalInspect(d tableedit.PhysicalDraft) (myPhysicalEvidence, error) {
	e := myPhysicalEvidence{}
	b, err := s.readStructurePhysical(d.Target, true)
	if err != nil {
		return e, err
	}
	if b.Facts == nil || !b.Facts.Proof {
		return e, errors.New("Physical operations require complete SELECT/TRIGGER catalog visibility, an unambiguous current account without active roles or partial revokes, and full retained native definitions.")
	}
	v := b.Facts.ServerVersion
	if !(v >= 80030 && v < 80100 || v >= 80400 && v < 80500) {
		return e, errors.New("Guarded MySQL physical operations are proven for Oracle MySQL 8.0.30+ in the 8.0 series and 8.4 LTS; other versions and forks require a separately proven matrix.")
	}
	e.Baseline = b
	e.BaselineProof = myPhysicalProof(b)
	if b.Facts.Table.Storage.Value == nil {
		return e, tableedit.ErrUnsupported
	}
	e.Engine = *b.Facts.Table.Storage.Value
	e.Partitions, err = s.myPhysicalPartitions(d.Target)
	if err != nil || len(e.Partitions) > 128 {
		return e, tableedit.ErrUnsupported
	}
	for _, r := range e.Partitions {
		if myText(r, 5) != "" {
			return e, errors.New("This table has subpartitions. Select a separately authored subpartition-aware migration so no subordinate bounds or properties are omitted.")
		}
	}
	e.Engines, err = s.myPhysicalRows(`SELECT ENGINE,SUPPORT,TRANSACTIONS,XA,SAVEPOINTS FROM information_schema.ENGINES WHERE ENGINE IN ('InnoDB','MyISAM') ORDER BY ENGINE`)
	if err != nil {
		return e, err
	}
	if d.Intent.Child != nil {
		child, err := s.readStructurePhysical(*d.Intent.Child, true)
		if err != nil {
			return e, err
		}
		e.Child = &child
		e.ChildProof = myPhysicalProof(child)
		e.ChildPartitions, err = s.myPhysicalPartitions(*d.Intent.Child)
		if err != nil {
			return e, err
		}
	}
	return e, nil
}
func (e myPhysicalEvidence) object() tableedit.PhysicalObject {
	p := []tableedit.PhysicalPartition{}
	for _, r := range e.Partitions {
		if myText(r, 0) != "" {
			p = append(p, tableedit.PhysicalPartition{Name: myText(r, 0), Method: myText(r, 2), Description: myText(r, 4)})
		}
	}
	indexes := []tableedit.PhysicalIndexState{}
	for _, i := range e.Baseline.Indexes {
		indexes = append(indexes, tableedit.PhysicalIndexState{Name: i.Name, Valid: true, Ready: true, Live: true})
	}
	return tableedit.PhysicalObject{Columns: e.Baseline.Columns, PartitionMethod: func() string {
		if len(e.Partitions) > 0 {
			return myText(e.Partitions[0], 2)
		}
		return ""
	}(), Target: e.Baseline.Target, Identity: e.Baseline.Scope, Kind: "table", StorageEngine: e.Engine, Fingerprint: tableedit.Fingerprint([]any{e.BaselineProof, e.Partitions, e.Engines}), Definition: e.Baseline.NativeDefinition, Partitions: p, Indexes: indexes, Limitations: []string{"MySQL does not expose a durable table identity here. Metadata rechecks cannot close concurrent DDL races or prove drop/recreate identity.", "Partition descriptions are native observations; Preview never evaluates partition expressions or scans rows."}}
}
func myPhysicalMode(b tableedit.Baseline, name string) bool {
	if b.Facts != nil {
		for _, x := range b.Facts.EngineContext {
			if x.Name == "sqlMode" {
				for _, m := range strings.Split(x.Value, ",") {
					if m == name {
						return true
					}
				}
			}
		}
	}
	return false
}
func myPhysicalAlgorithm(x tableedit.PhysicalIntent, method string) error {
	if x.Algorithm == "INSTANT" {
		return errors.New("None of these physical operations has a proven INSTANT path; select the documented strict INPLACE or COPY path.")
	}
	if x.Algorithm == "COPY" && x.Lock == "NONE" {
		return errors.New("ALGORITHM=COPY requires LOCK=SHARED or LOCK=EXCLUSIVE. No server fallback is generated.")
	}
	switch x.Kind {
	case "storageEngine", "partitionTable", "removePartitioning":
		if x.Algorithm != "COPY" {
			return errors.New("This operation requires explicit ALGORITHM=COPY and LOCK=SHARED or EXCLUSIVE.")
		}
	case "reorganizePartition", "coalescePartitions":
		if x.Algorithm != "INPLACE" || x.Lock == "NONE" {
			return errors.New("This partition operation requires ALGORITHM=INPLACE and LOCK=SHARED or EXCLUSIVE.")
		}
	case "addHashPartitions":
		if x.Algorithm == "INPLACE" && x.Lock == "NONE" {
			return errors.New("HASH/KEY partition redistribution does not permit concurrent DML with INPLACE; choose SHARED or EXCLUSIVE.")
		}
	case "exchangePartition", "truncatePartition":
		if x.Algorithm != "INPLACE" {
			return errors.New("This operation requires the explicit INPLACE path; COPY changes its native semantics.")
		}
	}
	return nil
}
func myPhysicalValue(v tableedit.PhysicalValue) (string, error) {
	if !v.Valid() {
		return "", tableedit.ErrInvalid
	}
	switch v.Kind {
	case "integer":
		return *v.Value, nil
	case "max":
		return "MAXVALUE", nil
	case "null":
		return "NULL", nil
	case "text":
		return "_utf8mb4 X'" + fmt.Sprintf("%x", []byte(*v.Value)) + "'", nil
	}
	return "", errors.New("MySQL has no MINVALUE partition bound; use its native first-range semantics.")
}
func myPhysicalDefinitions(defs []tableedit.PhysicalPartitionDefinition, method string) (string, error) {
	out := []string{}
	for _, d := range defs {
		b := d.Bound
		list := func(v []tableedit.PhysicalValue) (string, error) {
			z := []string{}
			for _, a := range v {
				if a.Kind == "text" && !strings.Contains(method, "COLUMNS") {
					return "", errors.New("Text bounds require RANGE/LIST COLUMNS partitioning.")
				}
				x, e := myPhysicalValue(a)
				if e != nil {
					return "", e
				}
				z = append(z, x)
			}
			return strings.Join(z, ", "), nil
		}
		sql := "PARTITION " + QuoteIdentifier(d.Name)
		switch method {
		case "RANGE", "RANGE COLUMNS":
			if b.Kind != "range" || len(b.From) > 0 {
				return "", errors.New("MySQL RANGE definitions use only the exclusive upper bound; lower bounds derive from preceding partitions.")
			}
			v, e := list(b.To)
			if e != nil {
				return "", e
			}
			sql += " VALUES LESS THAN (" + v + ")"
		case "LIST", "LIST COLUMNS":
			if b.Kind != "list" {
				return "", tableedit.ErrInvalid
			}
			values := []string{}
			for _, tuple := range b.Values {
				v, e := list(tuple)
				if e != nil {
					return "", e
				}
				if method == "LIST" && len(tuple) != 1 {
					return "", tableedit.ErrInvalid
				}
				if method == "LIST COLUMNS" && len(tuple) > 1 {
					v = "(" + v + ")"
				}
				values = append(values, v)
			}
			sql += " VALUES IN (" + strings.Join(values, ", ") + ")"
		default:
			return "", errors.New("Named partition definitions require RANGE or LIST; HASH/KEY resizing uses an explicit count.")
		}
		out = append(out, sql)
	}
	return strings.Join(out, ", "), nil
}
func (s *Session) PhysicalPrepare(ctx context.Context, d tableedit.PhysicalDraft) (tableedit.PhysicalPlan, error) {
	p := tableedit.PhysicalPlan{}
	var err error
	response := s.executeWith(ctx, protocol.Command{}, func(_ *collector, _ *wire.Result) error {
		if !d.Valid() {
			err = tableedit.ErrInvalid
			return nil
		}
		var e myPhysicalEvidence
		e, err = s.myPhysicalInspect(d)
		if err != nil {
			return nil
		}
		p, err = s.myPhysicalPlan(ctx, d, e)
		return nil
	})
	if err != nil {
		return p, err
	}
	if response.Type == "error" {
		return p, tableedit.ErrUnsupported
	}
	return p, nil
}
func (s *Session) myPhysicalPlan(ctx context.Context, d tableedit.PhysicalDraft, e myPhysicalEvidence) (tableedit.PhysicalPlan, error) {
	b := e.Baseline
	x := d.Intent
	target := QuoteIdentifier(d.Target.Schema) + "." + QuoteIdentifier(d.Target.Table)
	p := tableedit.PhysicalPlan{Engine: "mysql", ServerVersion: b.Facts.ServerVersion, Draft: d, SQL: []string{}, Objects: []tableedit.PhysicalObject{e.object()}, Prerequisites: []string{"An idle dedicated session, strict SQL mode, complete current metadata, active target engine and confirmation of this exact plan are required."}, Risks: []string{"MySQL DDL implicitly commits; physical operations are not wrapped in a user transaction. A nontransactional destination loses rollback/crash/foreign-key capabilities. Stop and Discard cannot undo acknowledged changes.", "Preview reads metadata only and never scans rows or evaluates expressions. Apply may rebuild or redistribute all rows, evaluate defaults/generated expressions, require additional disk, block reads/writes or be rejected by the server. Exact ALGORITHM/LOCK clauses prevent implicit fallback.", "Metadata rechecks are best effort and cannot close concurrent DDL races or prove drop/recreate identity. Lost acknowledgement is unknown; no automatic retry, disabled constraints, data coercion, engine substitution or replay is generated."}, Consequences: []tableedit.Consequence{}, TransactionMode: "implicitCommit", Locking: "Metadata lock_wait_timeout=5s; explicit LOCK=" + x.Lock + ", ALGORITHM=" + x.Algorithm + ". Even LOCK=NONE needs brief exclusive metadata locks."}
	if !myPhysicalMode(b, "STRICT_ALL_TABLES") && !myPhysicalMode(b, "STRICT_TRANS_TABLES") {
		return p, errors.New("Physical operations require an already strict session SQL mode; the helper never changes SQL mode.")
	}
	method := ""
	names := map[string]bool{}
	for _, r := range e.Partitions {
		if myText(r, 0) != "" {
			names[myText(r, 0)] = true
			method = myText(r, 2)
		}
	}
	if err := myPhysicalAlgorithm(x, method); err != nil {
		return p, err
	}
	auto := false
	for _, c := range b.Facts.Table.Columns.Items {
		auto = auto || c.Identity.Value != nil && c.Identity.Value.Kind != "none"
	}
	if (x.Algorithm == "COPY" || x.Kind == "storageEngine") && auto && !myPhysicalMode(b, "NO_AUTO_VALUE_ON_ZERO") {
		return p, errors.New("COPY or engine conversion with AUTO_INCREMENT requires NO_AUTO_VALUE_ON_ZERO already present in this session, so stored zeros are never replaced by generated values. Review session settings explicitly first.")
	}
	suffix := ", ALGORITHM=" + x.Algorithm + ", LOCK=" + x.Lock + ";"
	partitionSQL := func(clause string) string {
		separator := ", "
		if clause == "REMOVE PARTITIONING" {
			separator = " "
		}
		return "ALTER TABLE " + target + " ALGORITHM=" + x.Algorithm + ", LOCK=" + x.Lock + separator + clause + ";"
	}
	partNames := func(v []string) string {
		out := []string{}
		for _, n := range v {
			out = append(out, QuoteIdentifier(n))
		}
		return strings.Join(out, ", ")
	}
	requireNames := func() error {
		for _, n := range x.Partitions {
			if !names[n] {
				return errors.New("A selected partition is absent or its exact name changed.")
			}
		}
		return nil
	}
	switch x.Kind {
	case "onlineIndex":
		if e.Engine != "InnoDB" {
			return p, errors.New("The strict online-index path requires InnoDB.")
		}
		prepared, err := s.StructurePrepare(ctx, b, tableedit.Draft{AuthoringVersion: 3, AllowDestructive: true, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{*x.Index}})
		if err != nil {
			return p, err
		}
		if len(prepared.SQL) != 1 {
			return p, tableedit.ErrInvalid
		}
		if x.Index.Definition != nil {
			m := tableedit.CanonicalIndexMethod("mysql", x.Index.Definition.Method)
			if method != "" && m == "fulltext" {
				return p, errors.New("MySQL does not support FULLTEXT indexes on partitioned InnoDB tables.")
			}
			if (m == "fulltext" || m == "spatial") && x.Lock == "NONE" {
				return p, errors.New("FULLTEXT/SPATIAL index creation does not permit LOCK=NONE; choose SHARED or EXCLUSIVE.")
			}
		}
		indexSuffix := " ALGORITHM=" + x.Algorithm + " LOCK=" + x.Lock + ";"
		if strings.HasPrefix(prepared.SQL[0], "ALTER TABLE ") {
			indexSuffix = suffix
		}
		p.SQL = []string{strings.TrimSuffix(prepared.SQL[0], ";") + indexSuffix}
		p.Risks = append(p.Risks, prepared.Risks...)
	case "storageEngine":
		if method != "" || e.Engine == x.Engine {
			return p, errors.New("Select a different engine for an ordinary nonpartitioned table. InnoDB is the only proven native partition engine.")
		}
		available := false
		for _, r := range e.Engines {
			available = available || myText(r, 0) == x.Engine && (myText(r, 1) == "YES" || myText(r, 1) == "DEFAULT")
		}
		if !available || !myPhysicalMode(b, "NO_ENGINE_SUBSTITUTION") {
			return p, errors.New("The exact destination engine must be active and SQL mode must include NO_ENGINE_SUBSTITUTION.")
		}
		if len(b.Facts.Incoming) > 0 {
			return p, errors.New("Engine conversion would lose incoming foreign-key enforcement. Review explicit dependency repairs first; no check is disabled or dropped implicitly.")
		}
		for _, k := range b.Facts.Table.Constraints.Items {
			if k.Kind.Value != nil && *k.Kind.Value == "f" {
				return p, errors.New("Engine conversion requires explicit removal/replacement of foreign keys through the migration workflow first.")
			}
		}
		if err := myPhysicalEngineProperties(b); err != nil {
			return p, err
		}
		p.SQL = []string{"ALTER TABLE " + target + " ENGINE=" + x.Engine + suffix}
		p.Consequences = append(p.Consequences, tableedit.Consequence{Kind: "capabilityLoss", Object: d.Target.Schema + "." + d.Target.Table, Message: "The exact destination engine is " + x.Engine + ". MyISAM has no transactions, foreign-key enforcement, MVCC or InnoDB crash recovery and uses table locks. Native column/index/trigger definitions are retained; incompatible engine-specific properties are rejected before Apply."})
	case "reorderColumns":
		if method != "" || e.Engine != "InnoDB" || len(x.ColumnOrder) != len(b.Columns) {
			return p, errors.New("Column reordering requires every existing column exactly once on an ordinary InnoDB table.")
		}
		defs, _, _, ok := mysqlReconstructionDefinition(b.NativeDefinition, b.Facts)
		if !ok {
			return p, tableedit.ErrUnsupported
		}
		parts := []string{}
		for i, n := range x.ColumnOrder {
			definition, ok := defs[n]
			if !ok {
				return p, tableedit.ErrInvalid
			}
			position := " FIRST"
			if i > 0 {
				position = " AFTER " + QuoteIdentifier(x.ColumnOrder[i-1])
			}
			parts = append(parts, "MODIFY COLUMN "+definition+position)
		}
		hasGenerated := false
		for _, c := range b.Facts.Table.Columns.Items {
			hasGenerated = hasGenerated || c.Generated.Value != nil && c.Generated.Value.Kind != "none"
		}
		if hasGenerated && x.Algorithm != "COPY" {
			return p, errors.New("Moving generated columns requires the explicit COPY path on the proven MySQL matrix; no INPLACE fallback is attempted.")
		}
		p.SQL = []string{"ALTER TABLE " + target + " " + strings.Join(parts, ", ") + suffix}
		p.Risks = append(p.Risks, "Every MODIFY uses the complete captured native column definition. COPY preserves AUTO_INCREMENT zeros only under the already captured NO_AUTO_VALUE_ON_ZERO mode and may recompute generated values.")
	case "partitionTable", "removePartitioning", "addPartition", "reorganizePartition", "dropPartition", "truncatePartition", "addHashPartitions", "coalescePartitions", "exchangePartition":
		if e.Engine != "InnoDB" {
			return p, errors.New("Native partition management requires InnoDB on the proven Oracle MySQL versions.")
		}
		if x.Kind != "partitionTable" && method == "" {
			return p, errors.New("The selected table is not partitioned.")
		}
		resultingPartitions := len(names)
		switch x.Kind {
		case "addPartition":
			resultingPartitions += len(x.Definitions)
		case "reorganizePartition":
			resultingPartitions += len(x.Definitions) - len(x.Partitions)
		}
		if resultingPartitions > 128 {
			return p, errors.New("The resulting partition count exceeds the bounded catalog proof limit of 128.")
		}
		if err := requireNames(); err != nil {
			return p, err
		}
		if !physicalMySQLReorganizeProperties(e, x) {
			return p, errors.New("Selected partition options require an explicit property-preserving migration before repartitioning; unknown native options are never discarded.")
		}
		clause := ""
		switch x.Kind {
		case "partitionTable":
			if x.Count > 128 {
				return p, errors.New("The resulting partition count exceeds the bounded catalog proof limit of 128.")
			}
			if method != "" {
				return p, errors.New("Initial partitioning requires a currently nonpartitioned table. Existing bounds are changed through explicit reorganization.")
			}
			for _, n := range x.Columns {
				if _, ok := tableedit.FindColumn(b, n); !ok {
					return p, tableedit.ErrInvalid
				}
			}
			m := map[string]string{"range": "RANGE", "list": "LIST", "rangeColumns": "RANGE COLUMNS", "listColumns": "LIST COLUMNS", "hash": "HASH", "key": "KEY"}[x.Method]
			if (m == "RANGE" || m == "LIST" || m == "HASH") && len(x.Columns) != 1 {
				return p, errors.New("Expression partitioning uses one direct column; multiple direct columns require COLUMNS or KEY.")
			}
			clause = "PARTITION BY " + m + " (" + partNames(x.Columns) + ")"
			if x.Count > 0 {
				clause += " PARTITIONS " + strconv.Itoa(x.Count)
			} else {
				defs, err := myPhysicalDefinitions(x.Definitions, m)
				if err != nil {
					return p, err
				}
				clause += " (" + defs + ")"
			}
			p.SQL = []string{"ALTER TABLE " + target + " ALGORITHM=" + x.Algorithm + ", LOCK=" + x.Lock + " " + clause + ";"}
		case "removePartitioning":
			p.SQL = []string{partitionSQL("REMOVE PARTITIONING")}
		case "addPartition", "reorganizePartition":
			if !strings.HasPrefix(method, "RANGE") && !strings.HasPrefix(method, "LIST") {
				return p, errors.New("Named ADD/REORGANIZE is defined for RANGE/LIST. HASH/KEY uses ADD PARTITION PARTITIONS or COALESCE PARTITION.")
			}
			for _, def := range x.Definitions {
				if names[def.Name] {
					selected := false
					for _, n := range x.Partitions {
						selected = selected || n == def.Name
					}
					if !selected {
						return p, errors.New("A replacement partition name collides with an unselected partition.")
					}
				}
			}
			defs, err := myPhysicalDefinitions(x.Definitions, method)
			if err != nil {
				return p, err
			}
			clause = "ADD PARTITION (" + defs + ")"
			if x.Kind == "reorganizePartition" {
				clause = "REORGANIZE PARTITION " + partNames(x.Partitions) + " INTO (" + defs + ")"
			}
			p.SQL = []string{partitionSQL(clause)}
		case "dropPartition":
			if !strings.HasPrefix(method, "RANGE") && !strings.HasPrefix(method, "LIST") {
				return p, errors.New("HASH/KEY does not support DROP PARTITION; COALESCE redistributes data instead.")
			}
			if len(x.Partitions) >= len(names) {
				return p, errors.New("At least one partition must remain.")
			}
			p.SQL = []string{partitionSQL("DROP PARTITION " + partNames(x.Partitions))}
			p.Consequences = append(p.Consequences, tableedit.Consequence{Kind: "dataLoss", Object: strings.Join(x.Partitions, ", "), Message: "INPLACE DROP deletes every row in the selected partitions. COPY DROP may relocate compatible rows and deletes rows that no longer fit. There is no rollback, automatic backup, or replay."})
		case "truncatePartition":
			p.SQL = []string{partitionSQL("TRUNCATE PARTITION " + partNames(x.Partitions))}
			p.Consequences = append(p.Consequences, tableedit.Consequence{Kind: "dataLoss", Object: strings.Join(x.Partitions, ", "), Message: "TRUNCATE permanently deletes every row in the selected partitions. Partition bounds and unselected definitions remain; no rollback is available."})
		case "addHashPartitions", "coalescePartitions":
			if !strings.Contains(method, "HASH") && !strings.Contains(method, "KEY") {
				return p, errors.New("Count-based resizing requires HASH, LINEAR HASH, KEY or LINEAR KEY partitioning.")
			}
			if x.Kind == "coalescePartitions" {
				if x.Count >= len(names) {
					return p, errors.New("COALESCE must leave at least one partition.")
				}
				clause = "COALESCE PARTITION " + strconv.Itoa(x.Count)
			} else {
				if len(names)+x.Count > 128 {
					return p, errors.New("The resulting partition count exceeds the bounded catalog proof limit of 128.")
				}
				clause = "ADD PARTITION PARTITIONS " + strconv.Itoa(x.Count)
			}
			p.SQL = []string{partitionSQL(clause)}
		case "exchangePartition":
			if e.Child == nil || len(e.ChildPartitions) != 1 || myText(e.ChildPartitions[0], 0) != "" || e.Child.Facts == nil || e.Child.Facts.Table.Storage.Value == nil || *e.Child.Facts.Table.Storage.Value != "InnoDB" {
				return p, errors.New("EXCHANGE requires one nonpartitioned InnoDB table with compatible native schema. The server validates exact compatibility and row bounds during Apply.")
			}
			ct := e.Child.Target
			p.Objects = append(p.Objects, myPhysicalEvidence{Baseline: *e.Child, BaselineProof: e.ChildProof, Partitions: e.ChildPartitions, Engine: "InnoDB", Engines: e.Engines}.object())
			p.SQL = []string{partitionSQL("EXCHANGE PARTITION " + QuoteIdentifier(x.Partitions[0]) + " WITH TABLE " + QuoteIdentifier(ct.Schema) + "." + QuoteIdentifier(ct.Table) + " WITH VALIDATION")}
			p.Consequences = append(p.Consequences, tableedit.Consequence{Kind: "dataMovement", Object: ct.Schema + "." + ct.Table, Message: "EXCHANGE swaps ownership of all rows between the selected partition and this standalone table. WITH VALIDATION scans candidate rows; constraints are never disabled. Existing instant-column history can make MySQL reject EXCHANGE."})
		}
		p.Risks = append(p.Risks, "Partition-key/unique-key/foreign-key compatibility, exact coverage and destination data acceptance are enforced by MySQL during Apply. Preview cannot prove them without scanning data. Reorganization may copy all selected rows; existing full native definitions and unselected partitions are retained by ALTER.")
	default:
		return p, errors.New("This operation is PostgreSQL-specific. MySQL uses native partition add/reorganize/drop/truncate/coalesce/exchange operations.")
	}
	if len(p.SQL) != 1 {
		return p, tableedit.ErrInvalid
	}
	e.SQL = append([]string(nil), p.SQL...)
	p.Evidence = e
	p.EvidenceDigest = tableedit.Fingerprint(e)
	return p, nil
}
func myPhysicalEngineProperties(b tableedit.Baseline) error {
	_, others, suffix, ok := mysqlReconstructionDefinition(b.NativeDefinition, b.Facts)
	if !ok {
		return tableedit.ErrUnsupported
	}
	mode := ""
	for _, x := range b.Facts.EngineContext {
		if x.Name == "sqlMode" {
			mode = x.Value
		}
	}
	tokens, ok := mysqlIndexMetadataTokens(suffix, mode, 0)
	if !ok {
		return tableedit.ErrUnsupported
	}
	for i := 0; i < len(tokens); {
		name := strings.ToUpper(tokens[i].value)
		i++
		if name == "DEFAULT" {
			if i >= len(tokens) {
				return tableedit.ErrUnsupported
			}
			name = strings.ToUpper(tokens[i].value)
			i++
		}
		if i < len(tokens) && tokens[i].value == "=" {
			i++
		}
		if i >= len(tokens) {
			return tableedit.ErrUnsupported
		}
		value := tokens[i]
		i++
		switch name {
		case "ENGINE":
			if value.value != "InnoDB" && value.value != "MyISAM" {
				return tableedit.ErrUnsupported
			}
		case "AUTO_INCREMENT", "CHARSET", "COLLATE", "COMMENT":
		case "ROW_FORMAT":
			if !strings.EqualFold(value.value, "DYNAMIC") {
				return errors.New("Only common DYNAMIC row format is proven across InnoDB/MyISAM. Review the engine-specific row format explicitly first.")
			}
		default:
			return errors.New("A retained native table option is engine-specific or unrecognized. Review its compatibility explicitly before engine conversion; no property is silently omitted.")
		}
	}
	for _, clause := range others {
		t, ok := mysqlIndexMetadataTokens(clause, mode, 0)
		if !ok || len(t) == 0 {
			return tableedit.ErrUnsupported
		}
		if strings.EqualFold(t[0].value, "FULLTEXT") || strings.EqualFold(t[0].value, "SPATIAL") {
			return errors.New("This engine conversion does not yet have complete cross-engine FULLTEXT/SPATIAL storage proof; review those physical indexes explicitly first.")
		}
	}
	return nil
}

func (s *Session) PhysicalExecute(ctx context.Context, p tableedit.PhysicalPlan, progress func(int, string)) []tableedit.Execution {
	e, ok := p.Evidence.(myPhysicalEvidence)
	fail := func(state, message string) []tableedit.Execution {
		return []tableedit.Execution{{State: state, Message: message}}
	}
	if !ok || len(p.SQL) != 1 || !reflect.DeepEqual(e.SQL, p.SQL) || tableedit.Fingerprint(e) != p.EvidenceDigest || ctx.Err() != nil {
		return fail("notStarted", "Invalid retained physical plan or cancelled before dispatch.")
	}
	dispatched, applied := false, false
	verificationMessage := ""
	response := s.executeWith(ctx, protocol.Command{Type: "structure.physical.apply"}, func(_ *collector, _ *wire.Result) error {
		progress(0, "metadataRecheck")
		if s.TransactionStatus() != "idle" {
			return &adapter.ConnectionError{Category: "policy", Message: "The physical session is not idle."}
		}
		r, err := s.work.client.Execute("SET SESSION lock_wait_timeout=5")
		if r != nil {
			r.Close()
		}
		if err != nil {
			return err
		}
		fresh, err := s.myPhysicalInspect(p.Draft)
		if err != nil {
			return err
		}
		if fresh.BaselineProof != e.BaselineProof || tableedit.Fingerprint(fresh.Partitions) != tableedit.Fingerprint(e.Partitions) || tableedit.Fingerprint(fresh.Engines) != tableedit.Fingerprint(e.Engines) || fresh.ChildProof != e.ChildProof || tableedit.Fingerprint(fresh.ChildPartitions) != tableedit.Fingerprint(e.ChildPartitions) {
			return &adapter.ConnectionError{Category: "conflict", Message: tableedit.ErrStale.Error()}
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		dispatched = true
		progress(0, "running")
		execute := func() error {
			r, e := s.work.client.Execute(p.SQL[0])
			if r != nil {
				r.Close()
			}
			return e
		}
		if s.structureExecuteOverride != nil {
			err = s.structureExecuteOverride(execute)
		} else {
			err = execute()
		}
		if err != nil {
			return err
		}
		applied = true
		progress(0, "acknowledged")
		observed, observeErr := s.myPhysicalInspect(p.Draft)
		if observeErr != nil || !myPhysicalExpected(e, observed, p.Draft.Intent) {
			verificationMessage = "The operation was acknowledged, but the requested effect and preservation of unselected schema properties could not be verified. Reconcile explicitly before another physical edit."
		}
		return nil
	})
	if applied {
		return fail("applied", verificationMessage)
	}
	if !dispatched {
		return fail("notStarted", "No physical DDL was sent. Prepare a fresh review after reconciliation.")
	}
	if response.OutcomeUnknown || !response.Connected {
		return fail("unknown", "MySQL acknowledgement was lost after dispatch. The physical operation may be complete or partially changed; never replay automatically.")
	}
	return fail("failed", "MySQL rejected or cancelled the strict physical operation (SQLSTATE "+response.SQLState+"). No fallback, retry or cleanup was attempted; reconcile observed state explicitly.")
}
func (s *Session) PhysicalObserve(ctx context.Context, p tableedit.PhysicalPlan) ([]tableedit.PhysicalObject, error) {
	var objects []tableedit.PhysicalObject
	var err error
	r := s.executeWith(ctx, protocol.Command{}, func(_ *collector, _ *wire.Result) error {
		e, x := s.myPhysicalInspect(p.Draft)
		err = x
		if err == nil {
			objects = append(objects, e.object())
			if e.Child != nil {
				objects = append(objects, myPhysicalEvidence{Baseline: *e.Child, BaselineProof: e.ChildProof, Partitions: e.ChildPartitions, Engine: "InnoDB", Engines: e.Engines}.object())
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if r.Type == "error" {
		return nil, tableedit.ErrUnsupported
	}
	return objects, nil
}

// myPhysicalPreserved compares complete native schema facts independently of acknowledgement.
func myPhysicalPreserved(a, b tableedit.Baseline, kind string, order []string) bool {
	if a.Facts == nil || b.Facts == nil {
		return false
	}
	var old, next tableedit.Facts
	raw, _ := json.Marshal(a.Facts)
	_ = json.Unmarshal(raw, &old)
	raw, _ = json.Marshal(b.Facts)
	_ = json.Unmarshal(raw, &next)
	if kind == "storageEngine" {
		old.Table.Storage = next.Table.Storage
		old.Table.Kind = next.Table.Kind

	}
	if kind == "reorderColumns" {
		if !tableedit.VerifyColumnOrder(a, b, order, false) {
			return false
		}
		sort.Slice(old.Table.Columns.Items, func(i, j int) bool { return old.Table.Columns.Items[i].Ref.Name < old.Table.Columns.Items[j].Ref.Name })
		sort.Slice(next.Table.Columns.Items, func(i, j int) bool {
			return next.Table.Columns.Items[i].Ref.Name < next.Table.Columns.Items[j].Ref.Name
		})
		for i := range old.Table.Columns.Items {
			old.Table.Columns.Items[i].Ordinal = next.Table.Columns.Items[i].Ordinal
		}
	}
	return reflect.DeepEqual(old, next)
}

func (s *Session) PhysicalInspect(ctx context.Context, t tableedit.Target) (tableedit.PhysicalInspection, error) {
	d := tableedit.PhysicalDraft{Version: 1, Target: t, Intent: tableedit.PhysicalIntent{Kind: "storageEngine", Engine: "MyISAM", Algorithm: "COPY", Lock: "EXCLUSIVE"}}
	var out tableedit.PhysicalInspection
	var err error
	r := s.executeWith(ctx, protocol.Command{}, func(_ *collector, _ *wire.Result) error {
		var e myPhysicalEvidence
		e, err = s.myPhysicalInspect(d)
		if err == nil {
			ops := []string{"storageEngine"}
			if e.Engine == "InnoDB" {
				if len(e.Partitions) > 0 && myText(e.Partitions[0], 0) != "" {
					ops = []string{"removePartitioning", "truncatePartition", "exchangePartition"}
					method := myText(e.Partitions[0], 2)
					if strings.Contains(method, "HASH") || strings.Contains(method, "KEY") {
						ops = append(ops, "addHashPartitions", "coalescePartitions")
					} else {
						ops = append(ops, "addPartition", "reorganizePartition", "dropPartition")
					}
				} else {
					ops = append(ops, "onlineIndex", "reorderColumns", "partitionTable")
				}
			}
			out = tableedit.PhysicalInspection{Version: 1, Engine: "mysql", ServerVersion: e.Baseline.Facts.ServerVersion, Objects: []tableedit.PhysicalObject{e.object()}, Operations: ops}
		}
		return nil
	})
	if err != nil {
		return out, err
	}
	if r.Type == "error" {
		return out, tableedit.ErrUnsupported
	}
	return out, nil
}

func myPhysicalExpected(before, after myPhysicalEvidence, x tableedit.PhysicalIntent) bool {
	a, b := before.Baseline, after.Baseline
	ca, oa, _, ok := mysqlReconstructionDefinition(a.NativeDefinition, a.Facts)
	if !ok {
		return false
	}
	cb, ob, _, ok := mysqlReconstructionDefinition(b.NativeDefinition, b.Facts)
	if !ok || !reflect.DeepEqual(ca, cb) {
		return false
	}
	if x.Kind == "onlineIndex" {
		if x.Index == nil {
			return false
		}
		condition := tableedit.Condition{Operation: tableedit.Operation{Kind: map[string]string{"add": "addIndex", "drop": "dropIndex"}[x.Index.Action], Index: x.Index}}
		return tableedit.VerifyTransition(a, b, condition, func(c sc.Column, w tableedit.Default) bool { return structureDefaultMatchesFacts(c, w, b.Facts) })
	}
	if !reflect.DeepEqual(oa, ob) {
		return false
	}
	if x.Kind == "storageEngine" {
		return after.Engine == x.Engine && myPhysicalPreserved(a, b, x.Kind, nil)
	}
	if x.Kind == "reorderColumns" {
		return myPhysicalPreserved(a, b, x.Kind, x.ColumnOrder) && mysqlReconstructionPreserved(a, b)
	}
	if !physicalMySQLPartitionProperties(before, after, x) {
		return false
	}
	old, next := map[string][]*string{}, map[string][]*string{}
	for _, r := range before.Partitions {
		if myText(r, 0) != "" {
			old[myText(r, 0)] = r
		}
	}
	for _, r := range after.Partitions {
		if myText(r, 0) != "" {
			next[myText(r, 0)] = r
		}
	}
	selected := map[string]bool{}
	for _, n := range x.Partitions {
		selected[n] = true
	}
	for _, d := range x.Definitions {
		selected[d.Name] = true
	}
	switch x.Kind {
	case "partitionTable":
		return len(old) == 0 && len(next) > 0
	case "removePartitioning":
		return len(old) > 0 && len(next) == 0
	case "addHashPartitions":
		return len(next) == len(old)+x.Count
	case "coalescePartitions":
		return len(next) == len(old)-x.Count
	case "truncatePartition":
		return reflect.DeepEqual(before.Partitions, after.Partitions)
	case "exchangePartition":
		return reflect.DeepEqual(before.Partitions, after.Partitions) && before.Child != nil && after.Child != nil && mysqlReconstructionPreserved(*before.Child, *after.Child)
	}
	for name, row := range old {
		if !selected[name] {
			z, found := next[name]
			if !found {
				return false
			}
			r1, r2 := append([]*string(nil), row...), append([]*string(nil), z...)
			r1[1], r2[1] = nil, nil
			if !reflect.DeepEqual(r1, r2) {
				return false
			}
		}
	}
	switch x.Kind {
	case "addPartition":
		return len(next) == len(old)+len(x.Definitions)
	case "dropPartition":
		for _, n := range x.Partitions {
			if _, ok := next[n]; ok {
				return false
			}
		}
		return len(next) == len(old)-len(x.Partitions)
	case "reorganizePartition":
		for _, d := range x.Definitions {
			if _, ok := next[d.Name]; !ok {
				return false
			}
		}
		return len(next) == len(old)-len(x.Partitions)+len(x.Definitions)
	}
	return false
}
