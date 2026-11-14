package mysql

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"math"
	"reflect"
	"sort"
	"strconv"
	"strings"

	"dbeer/helper/internal/tableedit"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

const myAdvancedDataMaxRows = 100000
const myAdvancedDataMaxBytes = 32 << 20

type myAdvancedDataProof struct {
	SQL     string
	Rows    [][]byte
	Counter [][]*string
}

func myAdvancedDataOperation(op tableedit.Operation) bool {
	return op.Kind == "backfill" || op.Kind == "reorder" || op.Kind == "addColumn" && op.Column != nil && (op.Column.Generated != nil || op.Column.Identity != nil) || op.Kind == "changeColumn" && op.Change != nil && (op.Change.Generated != nil || op.Change.Identity != nil)
}

func myAdvancedDataFrame(values []wire.FieldValue) ([]byte, error) {
	var out []byte
	for _, value := range values {
		out = append(out, byte(value.Type))
		switch value.Type {
		case wire.FieldValueTypeNull:
		case wire.FieldValueTypeSigned:
			out = binary.BigEndian.AppendUint64(out, uint64(value.AsInt64()))
		case wire.FieldValueTypeUnsigned:
			out = binary.BigEndian.AppendUint64(out, value.AsUint64())
		case wire.FieldValueTypeFloat:
			out = binary.BigEndian.AppendUint64(out, math.Float64bits(value.AsFloat64()))
		case wire.FieldValueTypeString:
			v := value.AsString()
			out = binary.BigEndian.AppendUint64(out, uint64(len(v)))
			out = append(out, v...)
		default:
			return nil, tableedit.ErrUnsupported
		}
	}
	return out, nil
}

// A prepared binary result retains FLOAT/DOUBLE bits instead of round-tripping
// them through the text driver's decimal parser. ENUM/SET need ordinal/mask
// plus exact label bytes to distinguish empty labels from invalid zero values.
func myAdvancedDataSQL(b tableedit.Baseline, condition tableedit.Condition) (string, error) {
	if b.Facts == nil || !b.Facts.Proof || !b.Facts.Table.Columns.Complete {
		return "", tableedit.ErrUnsupported
	}
	parts := []string{}
	for _, c := range b.Facts.Table.Columns.Items {
		if c.Type.Value == nil || c.Generated.Value == nil || c.Identity.Value == nil {
			return "", tableedit.ErrUnsupported
		}
		if condition.Operation.Kind == "backfill" && condition.Operation.Name != nil && c.Ref.Name == *condition.Operation.Name || condition.Operation.Change != nil && condition.Operation.Change.Generated != nil && condition.Operation.Change.Generated.Storage != "none" && c.Ref.Name == condition.Operation.Change.Name {
			continue
		}
		name := QuoteIdentifier(c.Ref.Name)
		kind := c.Type.Value.Ref.Name
		if kind == "enum" || kind == "set" {
			parts = append(parts, "CAST("+name+" AS UNSIGNED)", "HEX("+name+")")
		} else if kind == "timestamp" {
			// Binary TIMESTAMP calendar fields can collide in a DST fold. For a
			// native column, UNIX_TIMESTAMP returns its internal instant directly.
			parts = append(parts, name, "UNIX_TIMESTAMP("+name+")")
		} else {
			parts = append(parts, name)
		}
	}
	if len(parts) == 0 {
		parts = []string{"1"}
	}
	return "SELECT " + strings.Join(parts, ",") + " FROM " + QuoteIdentifier(b.Target.Schema) + "." + QuoteIdentifier(b.Target.Table) + " LIMIT 100001", nil
}

// Used inside the existing executeWith owner, never by Inspect or Preview.
func (s *Session) myAdvancedReadData(sql string) ([][]byte, error) {
	statement, err := s.work.client.Prepare(sql)
	if err != nil {
		return nil, err
	}
	defer statement.Close()
	result := &wire.Result{}
	defer result.Close()
	rows := [][]byte{}
	size, seen := 0, 0
	var quota error
	err = statement.ExecuteSelectStreaming(result, func(values []wire.FieldValue) error {
		seen++
		if quota != nil {
			return nil // Drain the bounded result before returning a quota failure.
		}
		row, e := myAdvancedDataFrame(values)
		if e != nil {
			quota = e
			return nil
		}
		size += len(row)
		if seen > myAdvancedDataMaxRows || size > myAdvancedDataMaxBytes {
			quota = errors.New("Complete native-value proof exceeds 100000 rows or 32 MiB; a partial comparison is never accepted.")
			return nil
		}
		rows = append(rows, row)
		return nil
	}, nil)
	if err != nil {
		return nil, err
	}
	if quota != nil {
		return nil, quota
	}
	if result.Warnings != 0 || result.Status&wire.SERVER_MORE_RESULTS_EXISTS != 0 {
		return nil, tableedit.ErrUnsupported
	}
	sort.Slice(rows, func(i, j int) bool { return bytes.Compare(rows[i], rows[j]) < 0 })
	return rows, nil
}

func (s *Session) myAdvancedDataCapture(b tableedit.Baseline, condition tableedit.Condition) (*myAdvancedDataProof, error) {
	if b.Advanced == nil || !myAdvancedDataOperation(condition.Operation) {
		return nil, nil
	}
	sql, err := myAdvancedDataSQL(b, condition)
	if err != nil {
		return nil, err
	}
	rows, err := s.myAdvancedReadData(sql)
	if err != nil {
		return nil, err
	}
	counter, err := s.myPhysicalRows(`SELECT AUTO_INCREMENT FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ?`, b.Target.Schema, b.Target.Table)
	if err != nil || len(counter) != 1 {
		return nil, tableedit.ErrUnsupported
	}
	// Removing identity intentionally removes its counter. Enabling identity
	// gives a previously absent counter an explicit server-defined initial value.
	if condition.Operation.Change != nil && condition.Operation.Change.Identity != nil {
		counter = nil
	}
	return &myAdvancedDataProof{SQL: sql, Rows: rows, Counter: counter}, nil
}

func (s *Session) myAdvancedDataVerify(p *myAdvancedDataProof, target tableedit.Target) error {
	if p == nil {
		return nil
	}
	rows, err := s.myAdvancedReadData(p.SQL)
	if err != nil || !reflect.DeepEqual(rows, p.Rows) {
		return errors.New("The statement was acknowledged but unaffected native values, row count or duplicate multiplicity could not be verified. MySQL DDL and MyISAM writes are not rolled back; reconcile explicitly and never replay.")
	}
	if p.Counter != nil {
		counter, err := s.myPhysicalRows(`SELECT AUTO_INCREMENT FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ?`, target.Schema, target.Table)
		if err != nil || !reflect.DeepEqual(counter, p.Counter) {
			return errors.New("The statement was acknowledged but the unaffected AUTO_INCREMENT counter changed or could not be observed. Reconcile explicitly; no rollback, counter reset or replay is attempted.")
		}
	}
	return nil
}

func myAdvancedReconstructionPrepare(b tableedit.Baseline, d tableedit.Draft) (tableedit.Prepared, error) {
	p := tableedit.Prepared{}
	order, err := tableedit.ReconstructionOrder(b, d)
	if err != nil {
		return p, err
	}
	if len(d.Backfills) > 0 {
		return p, errors.New("Review advanced backfill separately from physical reconstruction.")
	}
	if b.Advanced == nil || b.AdvancedEvidence == nil || b.Facts == nil || !b.Facts.Proof || !b.Facts.Table.Columns.Complete || !b.Facts.Table.Constraints.Complete || !b.Facts.Table.Indexes.Complete {
		return p, tableedit.ErrUnsupported
	}
	if !myPhysicalMode(b, "STRICT_ALL_TABLES") && !myPhysicalMode(b, "STRICT_TRANS_TABLES") {
		return p, errors.New("Advanced reconstruction requires an already strict SQL mode; no mode is changed implicitly.")
	}
	for _, c := range b.Facts.Table.Columns.Items {
		if c.Identity.Value != nil && c.Identity.Value.Kind == "autoIncrement" && !myPhysicalMode(b, "NO_AUTO_VALUE_ON_ZERO") {
			return p, errors.New("Native COPY requires already-present NO_AUTO_VALUE_ON_ZERO to preserve AUTO_INCREMENT zeros. The helper never changes SQL mode or restores counters implicitly.")
		}
	}
	definitions, _, _, ok := mysqlReconstructionDefinition(b.NativeDefinition, b.Facts)
	if !ok || len(definitions) != len(b.Columns) {
		return p, errors.New("Every complete native column, constraint/index and partition/table suffix is required for reconstruction.")
	}
	parts := []string{}
	if len(d.ColumnOrder) > 0 {
		for i, n := range order {
			definition, ok := definitions[n]
			if !ok {
				return p, tableedit.ErrInvalid
			}
			position := " FIRST"
			if i > 0 {
				position = " AFTER " + QuoteIdentifier(order[i-1])
			}
			parts = append(parts, "MODIFY COLUMN "+definition+position)
		}
	}
	if d.Reconstruct {
		parts = append(parts, "FORCE")
	}
	if len(parts) == 0 {
		return p, tableedit.ErrInvalid
	}
	p.SQL = []string{"ALTER TABLE " + QuoteIdentifier(b.Target.Schema) + "." + QuoteIdentifier(b.Target.Table) + " " + strings.Join(parts, ", ") + ", ALGORITHM=COPY, LOCK=EXCLUSIVE;"}
	p.Conditions = []tableedit.Condition{{Operation: tableedit.Operation{Kind: "reorder"}, ColumnOrder: order}}
	p.Consequences, p.ValidationChecks = tableedit.ReconstructionReview(b, d)
	p.Risks = []string{"The exact native column definitions and complete partition/table suffix are retained by one explicit ALGORITHM=COPY, LOCK=EXCLUSIVE ALTER TABLE. COPY may recompute generated values; unchanged native values, duplicates, counters and complete native metadata are compared after acknowledgement. A failed comparison stops the plan and requires reconciliation.", "MySQL DDL implicitly commits and MyISAM row writes are nontransactional. No rollback, SQL-mode change, constraint disabling, algorithm fallback, counter reset or retry is generated. Metadata and value rechecks cannot eliminate concurrent DDL or writes between observations; lost acknowledgement remains unknown."}
	return p, nil
}

// Preview remains catalog-only. This hook is deliberately separate from the
// actual row scan, which belongs inside the active Apply transport owner.
func myAdvancedDataDraft(_ context.Context, b tableedit.Baseline, d tableedit.Draft) error {
	if b.Advanced == nil {
		return nil
	}
	needsCopy := d.Reconstruct || len(d.ColumnOrder) > 0
	for _, c := range d.Changes {
		needsCopy = needsCopy || c.Generated != nil || c.Identity != nil
	}
	if needsCopy {
		for _, c := range b.Facts.Table.Columns.Items {
			if c.Identity.Value != nil && c.Identity.Value.Kind == "autoIncrement" && !myPhysicalMode(b, "NO_AUTO_VALUE_ON_ZERO") {
				return errors.New("A data-moving advanced ALTER requires already-present NO_AUTO_VALUE_ON_ZERO for an existing AUTO_INCREMENT column; SQL mode is never changed implicitly.")
			}
		}
	}
	return nil
}

// Strip only the selected native generation/identity grammar. The common typed
// transition still verifies the exact authored generation/identity semantics.
func myAdvancedGenerationColumn(raw string, change tableedit.ColumnChange, b tableedit.Baseline) ([]string, bool) {
	tokens, ok := mysqlIndexMetadataTokens(raw, physicalMySQLMode(b), 0)
	if !ok {
		return nil, false
	}
	out := []string{}
	for i := 0; i < len(tokens); i++ {
		t := tokens[i]
		if change.Identity != nil && t.kind == "word" && strings.EqualFold(t.value, "AUTO_INCREMENT") {
			continue
		}
		if change.Generated != nil && t.kind == "word" && strings.EqualFold(t.value, "DEFAULT") {
			if i+1 >= len(tokens) || !strings.EqualFold(tokens[i+1].value, "NULL") {
				return nil, false
			}
			i++
			continue
		}
		if change.Generated != nil && t.kind == "word" && strings.EqualFold(t.value, "GENERATED") {
			i++
			if i < len(tokens) && strings.EqualFold(tokens[i].value, "ALWAYS") {
				i++
			}
			if i+1 >= len(tokens) || !strings.EqualFold(tokens[i].value, "AS") || tokens[i+1].value != "(" {
				return nil, false
			}
			i += 2
			depth := 1
			for i < len(tokens) && depth > 0 {
				if tokens[i].value == "(" {
					depth++
				} else if tokens[i].value == ")" {
					depth--
				}
				i++
			}
			if depth != 0 || i >= len(tokens) || (!strings.EqualFold(tokens[i].value, "STORED") && !strings.EqualFold(tokens[i].value, "VIRTUAL")) {
				return nil, false
			}
			continue
		}
		out = append(out, t.kind+":"+t.value)
	}
	return out, true
}

func myAdvancedGenerationSuffix(raw string, b tableedit.Baseline) ([]string, bool) {
	tokens, ok := mysqlIndexMetadataTokens(raw, physicalMySQLMode(b), 0)
	if !ok {
		return nil, false
	}
	out := []string{}
	for i := 0; i < len(tokens); i++ {
		if tokens[i].kind == "word" && strings.EqualFold(tokens[i].value, "AUTO_INCREMENT") {
			if i+2 >= len(tokens) || tokens[i+1].value != "=" {
				return nil, false
			}
			if _, err := strconv.ParseUint(tokens[i+2].value, 10, 64); err != nil {
				return nil, false
			}
			i += 2
			continue
		}
		out = append(out, tokens[i].kind+":"+tokens[i].value)
	}
	return out, true
}

func myAdvancedGenerationPreserved(a, b tableedit.Baseline, condition tableedit.Condition) bool {
	change := condition.Operation.Change
	if change == nil || change.Generated == nil && change.Identity == nil || a.AdvancedEvidence == nil || b.AdvancedEvidence == nil || !reflect.DeepEqual(a.AdvancedEvidence, b.AdvancedEvidence) {
		return false
	}
	ca, oa, sa, ok := mysqlReconstructionDefinition(a.NativeDefinition, a.Facts)
	if !ok {
		return false
	}
	cb, ob, sb, ok := mysqlReconstructionDefinition(b.NativeDefinition, b.Facts)
	if !ok || !reflect.DeepEqual(oa, ob) {
		return false
	}
	if change.Identity != nil {
		left, valid := myAdvancedGenerationSuffix(sa, a)
		right, good := myAdvancedGenerationSuffix(sb, b)
		if !valid || !good || !reflect.DeepEqual(left, right) {
			return false
		}
	} else if sa != sb {
		return false
	}
	left, valid := myAdvancedGenerationColumn(ca[change.Name], *change, a)
	right, good := myAdvancedGenerationColumn(cb[change.Name], *change, b)
	if !valid || !good || !reflect.DeepEqual(left, right) {
		return false
	}
	delete(ca, change.Name)
	delete(cb, change.Name)
	return reflect.DeepEqual(ca, cb)
}
