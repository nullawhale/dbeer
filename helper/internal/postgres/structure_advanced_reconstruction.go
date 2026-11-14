package postgres

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"time"

	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"github.com/jackc/pgx/v5"
)

const pgAdvancedDataMaxRows = 100000
const pgAdvancedDataMaxBytes = 32 << 20

// These proofs live only for one Apply transaction, never in a portable draft.
// Exact framed binary rows retain NULL, duplicate multiplicity and native bits.
type pgAdvancedDataProof struct {
	Relations []pgAdvancedDataRelation
	Sequences map[tableedit.Target]pgAdvancedSequenceValue
	Types     []uint32
	TypeProof string
}
type pgAdvancedDataRelation struct {
	OID     string
	Target  tableedit.Target
	Columns []string
	Rows    [][]byte
}
type pgAdvancedSequenceValue struct {
	Value      string
	Called     bool
	Definition map[string]any
	Identity   *tableedit.Identity
	Session    pgAdvancedSequenceSession
}

// Sequence configuration uses int8. Decimal strings avoid JSON float64 losing
// adjacent limits/counters above 2^53 in private native catalog evidence.
const pgAdvancedExactSequenceJSON = "pg_catalog.to_jsonb(s) || pg_catalog.jsonb_build_object('seqstart',s.seqstart::pg_catalog.text,'seqincrement',s.seqincrement::pg_catalog.text,'seqmin',s.seqmin::pg_catalog.text,'seqmax',s.seqmax::pg_catalog.text,'seqcache',s.seqcache::pg_catalog.text)"

func pgAdvancedReadSequence(ctx context.Context, q structureReader, target tableedit.Target) (pgAdvancedSequenceValue, error) {
	q = pgCatalogReader(q)
	var value pgAdvancedSequenceValue
	session, err := pgAdvancedSessionSequenceState(ctx, q, target)
	if err != nil {
		return value, err
	}
	value.Session = session
	if !target.Valid() || q.QueryRow(ctx, "SELECT last_value::pg_catalog.text,is_called FROM "+pgx.Identifier{target.Schema, target.Table}.Sanitize()).Scan(&value.Value, &value.Called) != nil {
		return value, tableedit.ErrUnsupported
	}
	var raw string
	err = q.QueryRow(ctx, `SELECT pg_catalog.jsonb_build_object('class',pg_catalog.to_jsonb(c),'sequence',`+pgAdvancedExactSequenceJSON+`,'dependencies',COALESCE((SELECT pg_catalog.jsonb_agg(d ORDER BY d.classid,d.objid,d.objsubid,d.refclassid,d.refobjid,d.refobjsubid) FROM pg_catalog.pg_depend d WHERE (d.classid='pg_catalog.pg_class'::pg_catalog.regclass AND d.objid=c.oid) OR (d.refclassid='pg_catalog.pg_class'::pg_catalog.regclass AND d.refobjid=c.oid)),'[]'),'comments',COALESCE((SELECT pg_catalog.jsonb_agg(d ORDER BY d.objsubid) FROM pg_catalog.pg_description d WHERE d.classoid='pg_catalog.pg_class'::pg_catalog.regclass AND d.objoid=c.oid),'[]'),'labels',COALESCE((SELECT pg_catalog.jsonb_agg(d ORDER BY d.objsubid,d.provider) FROM pg_catalog.pg_seclabel d WHERE d.classoid='pg_catalog.pg_class'::pg_catalog.regclass AND d.objoid=c.oid),'[]'))::pg_catalog.text FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace JOIN pg_catalog.pg_sequence s ON s.seqrelid=c.oid WHERE n.nspname=$1 AND c.relname=$2 AND c.relkind='S'`, target.Schema, target.Table).Scan(&raw)
	if err != nil || len(raw) > 1<<20 || json.Unmarshal([]byte(raw), &value.Definition) != nil {
		return value, tableedit.ErrUnsupported
	}
	if !pgAdvancedSequenceSessionBound(value.Session, value.Definition) {
		return value, tableedit.ErrUnsupported
	}
	return value, nil
}

func pgAdvancedSequencePreserved(before, after pgAdvancedSequenceValue) bool {
	if before.Value != after.Value || before.Called != after.Called || before.Session != after.Session {
		return false
	}
	if before.Identity != nil {
		clone := func(value map[string]any) map[string]any {
			raw, _ := json.Marshal(value)
			var out map[string]any
			_ = json.Unmarshal(raw, &out)
			return out
		}
		before.Definition, after.Definition = clone(before.Definition), clone(after.Definition)
		left, lok := before.Definition["sequence"].(map[string]any)
		right, rok := after.Definition["sequence"].(map[string]any)
		if !lok || !rok {
			return false
		}
		changed := false
		for key, present := range map[string]bool{"seqstart": before.Identity.Start != nil, "seqincrement": before.Identity.Increment != nil, "seqmin": before.Identity.Minimum != nil, "seqmax": before.Identity.Maximum != nil, "seqcache": before.Identity.Cache != nil, "seqcycle": before.Identity.Cycle != nil} {
			if present {
				delete(left, key)
				delete(right, key)
				changed = true
			}
		}
		if changed {
			for _, def := range []map[string]any{before.Definition, after.Definition} {
				cl, ok := def["class"].(map[string]any)
				if !ok {
					return false
				}
				delete(cl, "relfilenode")
			}
		}
	}
	return reflect.DeepEqual(before.Definition, after.Definition)
}

func pgAdvancedDataOperation(op tableedit.Operation) bool {
	return op.Kind == "backfill" || op.Kind == "reorder" || op.Kind == "addColumn" && op.Column != nil && (op.Column.Generated != nil || op.Column.Identity != nil) || op.Kind == "changeColumn" && op.Change != nil && (op.Change.Generated != nil || op.Change.Identity != nil)
}

// row_security_active is catalog/role observation. It neither evaluates a
// policy nor changes the role, FORCE bit, row_security setting or policy list.
func pgAdvancedDataVisibility(ctx context.Context, q structureReader, b tableedit.Baseline) error {
	q = pgCatalogReader(q)
	if b.Advanced == nil {
		return nil
	}
	if b.AdvancedEvidence == nil || len(b.AdvancedEvidence.Targets) == 0 {
		return tableedit.ErrUnsupported
	}
	count := 0
	for key, rows := range b.AdvancedEvidence.Rows {
		if !strings.HasSuffix(key, "/class") || len(rows) != 1 {
			continue
		}
		id, e := strconv.ParseUint(strings.TrimSuffix(key, "/class"), 10, 32)
		if e != nil || id == 0 {
			return tableedit.ErrUnsupported
		}
		var visible bool
		if q.QueryRow(ctx, `SELECT NOT pg_catalog.row_security_active($1::pg_catalog.oid)`, uint32(id)).Scan(&visible) != nil || !visible {
			return errors.New("Data-moving authoring requires naturally complete row visibility on every connected table. The active role is subject to row security; policies, FORCE, roles and row_security are never changed implicitly.")
		}
		count++
	}
	if count != len(b.AdvancedEvidence.Targets) {
		return tableedit.ErrUnsupported
	}
	return nil
}

func pgAdvancedDataDraft(ctx context.Context, q structureReader, b tableedit.Baseline, d tableedit.Draft) error {
	if b.Advanced == nil {
		return nil
	}
	needed := d.NeedsAuthoringV5()
	for _, c := range d.Columns {
		needed = needed || c.Generated != nil || c.Identity != nil
	}
	for _, c := range d.Changes {
		needed = needed || c.Generated != nil || c.Identity != nil
	}
	if needed {
		if err := pgAdvancedDataVisibility(ctx, q, b); err != nil {
			return err
		}
		_, err := pgAdvancedBinaryTypes(ctx, q, pgAdvancedDataTypes(b))
		return err
	}
	return nil
}

func pgAdvancedDataTypes(b tableedit.Baseline) []uint32 {
	seen := map[uint32]bool{}
	for key, rows := range b.AdvancedEvidence.Rows {
		if !strings.HasSuffix(key, "/attributes") {
			continue
		}
		for _, attr := range rows {
			id, err := strconv.ParseUint(fmt.Sprint(attr["atttypid"]), 10, 32)
			if err == nil && id > 0 && attr["attisdropped"] != true {
				seen[uint32(id)] = true
			}
		}
	}
	out := []uint32{}
	for id := range seen {
		out = append(out, id)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

// Binary equality requires injective trusted support, not an arbitrary user
// typsend that could return a constant. Observation below reads catalogs only.
func pgAdvancedBinaryTypes(ctx context.Context, q structureReader, roots []uint32) (string, error) {
	q = pgCatalogReader(q)
	builtin := map[string]string{"int2": "int2send", "int4": "int4send", "int8": "int8send", "bool": "boolsend", "bytea": "byteasend", "text": "textsend", "varchar": "varcharsend", "bpchar": "bpcharsend", "numeric": "numeric_send", "float4": "float4send", "float8": "float8send", "date": "date_send", "time": "time_send", "timetz": "timetz_send", "timestamp": "timestamp_send", "timestamptz": "timestamptz_send", "interval": "interval_send", "uuid": "uuid_send", "json": "json_send", "jsonb": "jsonb_send", "xml": "xml_send", "inet": "inet_send", "cidr": "cidr_send", "macaddr": "macaddr_send", "macaddr8": "macaddr8_send", "bit": "bit_send", "varbit": "varbit_send", "money": "cash_send", "oid": "oidsend", "name": "namesend"}
	proof := map[uint32]map[string]any{}
	queue := append([]uint32(nil), roots...)
	for len(queue) > 0 {
		id := queue[0]
		queue = queue[1:]
		if proof[id] != nil {
			continue
		}
		if len(proof) >= 128 {
			return "", errors.New("Complete recursive native binary type support exceeds the 128-type proof bound.")
		}
		rows, err := pgAdvancedRows(ctx, q, `SELECT pg_catalog.jsonb_build_object('type',pg_catalog.to_jsonb(t),'send',pg_catalog.to_jsonb(p),'children',COALESCE((SELECT pg_catalog.jsonb_agg(x.oid ORDER BY x.oid) FROM (SELECT t.typelem AS oid WHERE t.typelem<>0 UNION SELECT t.typbasetype WHERE t.typbasetype<>0 UNION SELECT a.atttypid FROM pg_catalog.pg_attribute a WHERE t.typtype='c' AND a.attrelid=t.typrelid AND a.attnum>0 AND NOT a.attisdropped UNION SELECT r.rngsubtype FROM pg_catalog.pg_range r WHERE r.rngtypid=t.oid OR r.rngmultitypid=t.oid) x),'[]'),'enum',COALESCE((SELECT pg_catalog.jsonb_agg(e ORDER BY e.enumsortorder,e.oid) FROM pg_catalog.pg_enum e WHERE e.enumtypid=t.oid),'[]'),'attributes',COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('name',a.attname,'number',a.attnum,'type',a.atttypid,'typmod',a.atttypmod,'collation',a.attcollation,'dropped',a.attisdropped) ORDER BY a.attnum) FROM pg_catalog.pg_attribute a WHERE t.typtype='c' AND a.attrelid=t.typrelid AND a.attnum>0),'[]'))::pg_catalog.text FROM pg_catalog.pg_type t LEFT JOIN pg_catalog.pg_proc p ON p.oid=t.typsend WHERE t.oid=$1`, id)
		if err != nil || len(rows) != 1 {
			return "", tableedit.ErrUnsupported
		}
		row := rows[0]
		typ, tok := row["type"].(map[string]any)
		send, sok := row["send"].(map[string]any)
		children, cok := row["children"].([]any)
		if !tok || !sok || !cok || typ["typisdefined"] != true {
			return "", errors.New("A retained native type has no complete trusted binary support proof.")
		}
		expected := ""
		switch typ["typtype"] {
		case "e":
			expected = "enum_send"
		case "c":
			expected = "record_send"
		case "r":
			expected = "range_send"
		case "m":
			expected = "multirange_send"
		case "d":
			// A domain must use its verified underlying type's send identity.
			expected, _ = send["proname"].(string)
		default:
			if typ["typcategory"] == "A" && fmt.Sprint(typ["typelem"]) != "0" {
				expected = "array_send"
			} else if id < 16384 && fmt.Sprint(typ["typnamespace"]) == "11" {
				expected = builtin[fmt.Sprint(typ["typname"])]
			}
		}
		fn, parseErr := strconv.ParseUint(fmt.Sprint(send["oid"]), 10, 32)
		if expected == "" || parseErr != nil || fn == 0 || fn >= 16384 || fmt.Sprint(send["pronamespace"]) != "11" || fmt.Sprint(send["prolang"]) != "12" || send["proname"] != expected || send["prosrc"] != expected || send["prosecdef"] != false || send["prokind"] != "f" || fmt.Sprint(send["prorettype"]) != "17" {
			return "", errors.New("Exact native-value preservation requires verified built-in internal binary support. An opaque or custom typsend is rejected before it is invoked; safe structured types require complete recursively trusted components.")
		}
		proof[id] = row
		for _, child := range children {
			n, err := strconv.ParseUint(fmt.Sprint(child), 10, 32)
			if err != nil || n == 0 {
				return "", tableedit.ErrUnsupported
			}
			queue = append(queue, uint32(n))
		}
	}
	for _, row := range proof {
		typ := row["type"].(map[string]any)
		if typ["typtype"] == "d" {
			id, _ := strconv.ParseUint(fmt.Sprint(typ["typbasetype"]), 10, 32)
			base := proof[uint32(id)]
			if base == nil || !reflect.DeepEqual(typ["typsend"], base["type"].(map[string]any)["typsend"]) {
				return "", errors.New("A domain's binary send support differs from its recursively trusted base type.")
			}
		}
	}
	return tableedit.Fingerprint(proof), nil
}

func pgAdvancedFrame(values [][]byte) []byte {
	var out []byte
	for _, value := range values {
		if value == nil {
			out = append(out, 0)
			continue
		}
		out = append(out, 1)
		out = binary.BigEndian.AppendUint64(out, uint64(len(value)))
		out = append(out, value...)
	}
	return out
}

func pgAdvancedReadData(ctx context.Context, q structureReader, target tableedit.Target, columns []string, remaining *int) ([][]byte, error) {
	projection := []string{}
	for _, name := range columns {
		projection = append(projection, pgx.Identifier{name}.Sanitize())
	}
	if len(projection) == 0 {
		projection = []string{"1::pg_catalog.int4"}
	}
	rows, err := q.Query(ctx, "SELECT "+strings.Join(projection, ",")+" FROM ONLY "+pgx.Identifier{target.Schema, target.Table}.Sanitize()+" LIMIT 100001", pgx.QueryResultFormats{1})
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := [][]byte{}
	for rows.Next() {
		if len(out) >= pgAdvancedDataMaxRows {
			return nil, errors.New("The complete native-value proof exceeds 100000 rows per table; no data-moving statement was authorized by a partial snapshot.")
		}
		row := pgAdvancedFrame(rows.RawValues())
		if len(row) > *remaining {
			return nil, errors.New("The complete native-value proof exceeds its 32 MiB bound; no partial comparison is accepted.")
		}
		*remaining -= len(row)
		out = append(out, row)
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	sort.Slice(out, func(i, j int) bool { return bytes.Compare(out[i], out[j]) < 0 })
	return out, nil
}

// Call after the complete graph locks and stale-proof check, before dispatch.
// Exclude only an explicitly changed generated value; all other old values,
// including retained generated values, are compared in each physical member.
func pgAdvancedDataCapture(ctx context.Context, q structureReader, b tableedit.Baseline, c tableedit.Condition) (*pgAdvancedDataProof, error) {
	q = pgCatalogReader(q)
	if b.Advanced == nil || !pgAdvancedDataOperation(c.Operation) {
		return nil, nil
	}
	if err := pgAdvancedDataVisibility(ctx, q, b); err != nil {
		return nil, err
	}
	out := &pgAdvancedDataProof{Relations: []pgAdvancedDataRelation{}, Sequences: map[tableedit.Target]pgAdvancedSequenceValue{}}
	out.Types = pgAdvancedDataTypes(b)
	var err error
	out.TypeProof, err = pgAdvancedBinaryTypes(ctx, q, out.Types)
	if err != nil {
		return nil, err
	}
	remaining := pgAdvancedDataMaxBytes
	affected := map[string]bool{b.Identity: true}
	recursive := pgAdvancedRecursiveCondition(b, c)
	if c.Operation.Kind == "backfill" {
		// Backfill follows the explicitly recursive appended-column scope.
		recursive = pgAdvancedRecursiveOperation(b, tableedit.Operation{Kind: "addColumn"})
	}
	for changed := recursive; changed; {
		changed = false
		for key, links := range b.AdvancedEvidence.Rows {
			if !strings.HasSuffix(key, "/inherits") {
				continue
			}
			for _, link := range links {
				parent, child := fmt.Sprint(link["inhparent"]), fmt.Sprint(link["inhrelid"])
				if affected[parent] && !affected[child] && len(b.AdvancedEvidence.Rows[child+"/class"]) == 1 {
					affected[child] = true
					changed = true
				}
			}
		}
	}
	ids := []string{}
	for key := range b.AdvancedEvidence.Rows {
		if strings.HasSuffix(key, "/class") {
			ids = append(ids, strings.TrimSuffix(key, "/class"))
		}
	}
	sort.Strings(ids)
	for _, id := range ids {
		classes := b.AdvancedEvidence.Rows[id+"/class"]
		if len(classes) != 1 {
			return nil, tableedit.ErrUnsupported
		}
		cl := classes[0]
		var target tableedit.Target
		for _, candidate := range b.AdvancedEvidence.Targets {
			if candidate.Table == cl["relname"] {
				var oid string
				if q.QueryRow(ctx, `SELECT c.oid::pg_catalog.text FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname=$2`, candidate.Schema, candidate.Table).Scan(&oid) == nil && oid == id {
					target = candidate
					break
				}
			}
		}
		if !target.Valid() || target.Create {
			return nil, tableedit.ErrUnsupported
		}
		columns := []string{}
		for _, a := range b.AdvancedEvidence.Rows[id+"/attributes"] {
			if a["attisdropped"] == true {
				continue
			}
			name, ok := a["attname"].(string)
			if !ok || !tableedit.Identifier(name) {
				return nil, tableedit.ErrUnsupported
			}
			// Connected members outside the reviewed write scope stay fully proved.
			if affected[id] && (c.Operation.Kind == "backfill" && c.Operation.Name != nil && name == *c.Operation.Name || c.Operation.Change != nil && c.Operation.Change.Generated != nil && c.Operation.Change.Generated.Storage != "none" && name == c.Operation.Change.Name) {
				continue
			}
			columns = append(columns, name)
		}
		rows, err := pgAdvancedReadData(ctx, q, target, columns, &remaining)
		if err != nil {
			return nil, err
		}
		out.Relations = append(out.Relations, pgAdvancedDataRelation{OID: id, Target: target, Columns: columns, Rows: rows})
		sequences, err := pgAdvancedRows(ctx, q, `SELECT pg_catalog.json_build_object('schema',n.nspname,'name',s.relname,'column',a.attname)::pg_catalog.text FROM pg_catalog.pg_depend d JOIN pg_catalog.pg_class s ON s.oid=d.objid AND s.relkind='S' JOIN pg_catalog.pg_namespace n ON n.oid=s.relnamespace JOIN pg_catalog.pg_attribute a ON a.attrelid=d.refobjid AND a.attnum=d.refobjsubid WHERE d.classid='pg_catalog.pg_class'::pg_catalog.regclass AND d.refclassid='pg_catalog.pg_class'::pg_catalog.regclass AND d.refobjid=$1::pg_catalog.oid AND d.deptype IN ('a','i') ORDER BY s.oid LIMIT 129`, id)
		if err != nil || len(sequences) > 128 {
			return nil, tableedit.ErrUnsupported
		}
		for _, seq := range sequences {
			if id == b.Identity && c.Operation.Change != nil && c.Operation.Change.Identity != nil && c.Operation.Change.Identity.Kind == "none" && seq["column"] == c.Operation.Change.Name {
				continue
			}
			ref := tableedit.Target{Schema: fmt.Sprint(seq["schema"]), Table: fmt.Sprint(seq["name"])}
			value, err := pgAdvancedReadSequence(ctx, q, ref)
			if err != nil {
				return nil, errors.New("The exact owned-sequence counter is unavailable; data-moving authoring requires complete counter visibility.")
			}
			if id == b.Identity && c.Operation.Change != nil && c.Operation.Change.Identity != nil && seq["column"] == c.Operation.Change.Name {
				value.Identity = c.Operation.Change.Identity
			}
			out.Sequences[ref] = value
		}
	}
	return out, nil
}

// Catalog-only owned-sequence definitions complement the runtime counter proof.
// This is safe during Preview; it never reads a sequence relation or calls it.
func pgAdvancedGenerationCatalog(ctx context.Context, q structureReader, oid uint32) ([]map[string]any, error) {
	q = pgCatalogReader(q)
	rows, err := pgAdvancedRows(ctx, q, `SELECT pg_catalog.jsonb_build_object('column',a.attname,'class',pg_catalog.to_jsonb(c),'sequence',`+pgAdvancedExactSequenceJSON+`,'dependencies',COALESCE((SELECT pg_catalog.jsonb_agg(x ORDER BY x.classid,x.objid,x.objsubid,x.refclassid,x.refobjid,x.refobjsubid) FROM pg_catalog.pg_depend x WHERE (x.classid='pg_catalog.pg_class'::pg_catalog.regclass AND x.objid=c.oid) OR (x.refclassid='pg_catalog.pg_class'::pg_catalog.regclass AND x.refobjid=c.oid)),'[]'),'comments',COALESCE((SELECT pg_catalog.jsonb_agg(x ORDER BY x.objsubid) FROM pg_catalog.pg_description x WHERE x.classoid='pg_catalog.pg_class'::pg_catalog.regclass AND x.objoid=c.oid),'[]'),'labels',COALESCE((SELECT pg_catalog.jsonb_agg(x ORDER BY x.objsubid,x.provider) FROM pg_catalog.pg_seclabel x WHERE x.classoid='pg_catalog.pg_class'::pg_catalog.regclass AND x.objoid=c.oid),'[]'))::pg_catalog.text FROM pg_catalog.pg_depend d JOIN pg_catalog.pg_class c ON c.oid=d.objid AND c.relkind='S' JOIN pg_catalog.pg_sequence s ON s.seqrelid=c.oid JOIN pg_catalog.pg_attribute a ON a.attrelid=d.refobjid AND a.attnum=d.refobjsubid WHERE d.classid='pg_catalog.pg_class'::pg_catalog.regclass AND d.refclassid='pg_catalog.pg_class'::pg_catalog.regclass AND d.refobjid=$1 AND d.deptype IN ('a','i') ORDER BY c.oid LIMIT 129`, oid)
	if err != nil || len(rows) > 128 {
		return nil, tableedit.ErrUnsupported
	}
	raw, _ := json.Marshal(rows)
	if len(raw) > 1<<20 {
		return nil, tableedit.ErrUnsupported
	}
	return rows, nil
}

func pgAdvancedGenerationNormalize(before, after tableedit.Baseline, condition tableedit.Condition, a, b *tableedit.AdvancedEvidence) error {
	op := condition.Operation
	var name string
	var generation *tableedit.Generation
	var identity *tableedit.Identity
	if op.Kind == "addColumn" && op.Column != nil {
		name, generation, identity = op.Column.Name, op.Column.Generated, op.Column.Identity
	} else if op.Kind == "changeColumn" && op.Change != nil {
		name, generation, identity = op.Change.Name, op.Change.Generated, op.Change.Identity
	}
	if generation == nil && identity == nil {
		return nil
	}
	if a == nil || b == nil || name == "" {
		return tableedit.ErrUnsupported
	}
	prefix := before.Identity + "/"
	selected := func(proof *tableedit.AdvancedEvidence) (any, bool) {
		for _, attr := range proof.Rows[prefix+"attributes"] {
			if attr["attname"] == name && attr["attisdropped"] == false {
				return attr["attnum"], true
			}
		}
		return nil, false
	}
	num, exists := selected(b)
	if !exists {
		return tableedit.ErrUnsupported
	}
	removed := map[string]bool{}
	for _, proof := range []*tableedit.AdvancedEvidence{a, b} {
		if generation != nil {
			kept := []map[string]any{}
			for _, def := range proof.Rows[prefix+"defaults"] {
				if def["adnum"] == num {
					if fmt.Sprint(def["adrelid"]) != before.Identity {
						return tableedit.ErrUnsupported
					}
					removed[fmt.Sprint(def["oid"])] = true
				} else {
					kept = append(kept, def)
				}
			}
			proof.Rows[prefix+"defaults"] = kept
		}
		for _, attr := range proof.Rows[prefix+"attributes"] {
			if attr["attname"] != name {
				continue
			}
			if generation != nil {
				delete(attr, "attgenerated")
				delete(attr, "atthasdef")
			}
			if identity != nil {
				delete(attr, "attidentity")
			}
		}
	}
	sequenceIDs := map[string]bool{}
	if identity != nil {
		left, leftKnown := a.Rows[prefix+"sequences"]
		right, rightKnown := b.Rows[prefix+"sequences"]
		if !leftKnown || !rightKnown {
			return errors.New("Complete native owned-sequence definitions are required for advanced identity authoring.")
		}
		find := func(rows []map[string]any) []map[string]any {
			out := []map[string]any{}
			for _, row := range rows {
				if row["column"] == name {
					out = append(out, row)
				}
			}
			return out
		}
		x, y := find(left), find(right)
		if len(x) > 1 || len(y) > 1 || identity.Kind == "none" && (len(x) != 1 || len(y) != 0) || identity.Kind != "none" && len(y) != 1 {
			return errors.New("The selected identity sequence ownership transition did not match.")
		}
		if len(x) == 1 && len(y) == 1 {
			if !pgAdvancedSequencePreserved(pgAdvancedSequenceValue{Definition: x[0], Identity: identity}, pgAdvancedSequenceValue{Definition: y[0]}) {
				return errors.New("An unaffected native identity sequence property changed.")
			}
		}
		for _, proof := range []*tableedit.AdvancedEvidence{a, b} {
			kept := []map[string]any{}
			for _, row := range proof.Rows[prefix+"sequences"] {
				if row["column"] == name {
					class, ok := row["class"].(map[string]any)
					if !ok {
						return tableedit.ErrUnsupported
					}
					sequenceIDs[fmt.Sprint(class["oid"])] = true
				} else {
					kept = append(kept, row)
				}
			}
			proof.Rows[prefix+"sequences"] = kept
		}
	}
	for _, proof := range []*tableedit.AdvancedEvidence{a, b} {
		kept := []map[string]any{}
		for _, row := range proof.Rows[prefix+"dependencies"] {
			if generation != nil && pgAdvancedGeneratedSelfDependency(row, before.Identity, num) || fmt.Sprint(row["classid"]) == "2604" && removed[fmt.Sprint(row["objid"])] || fmt.Sprint(row["classid"]) == "1259" && sequenceIDs[fmt.Sprint(row["objid"])] || fmt.Sprint(row["refclassid"]) == "1259" && sequenceIDs[fmt.Sprint(row["refobjid"])] {
				continue
			}
			kept = append(kept, row)
		}
		proof.Rows[prefix+"dependencies"] = kept
	}
	if generation != nil && generation.Storage == "stored" {
		if !pgAdvancedToastPreserved(a, b, prefix) {
			return errors.New("Native generated-column rewrite did not preserve complete TOAST properties.")
		}
		left, right := a.Rows[prefix+"class"], b.Rows[prefix+"class"]
		if len(left) != 1 || len(right) != 1 {
			return tableedit.ErrUnsupported
		}
		left[0]["relfilenode"] = right[0]["relfilenode"]
		indexes := map[string]map[string]any{}
		for _, row := range b.Rows[prefix+"indexes"] {
			cl, ok := row["class"].(map[string]any)
			if !ok {
				return tableedit.ErrUnsupported
			}
			indexes[fmt.Sprint(cl["oid"])] = cl
		}
		for _, row := range a.Rows[prefix+"indexes"] {
			cl, ok := row["class"].(map[string]any)
			if !ok || indexes[fmt.Sprint(cl["oid"])] == nil {
				return errors.New("Generated-column rewrite changed an existing index identity.")
			}
			cl["relfilenode"] = indexes[fmt.Sprint(cl["oid"])]["relfilenode"]
		}
	}
	return nil
}

func pgAdvancedGeneratedSelfDependency(row map[string]any, id string, num any) bool {
	n, ok := pgPhysicalNumber(row["refobjsubid"])
	return ok && n > 0 && fmt.Sprint(row["classid"]) == "1259" && fmt.Sprint(row["objid"]) == id && row["objsubid"] == num && fmt.Sprint(row["refclassid"]) == "1259" && fmt.Sprint(row["refobjid"]) == id && row["deptype"] == "a"
}

// PostgreSQL14 stores generated-column/base-column dependencies as self AUTO
// edges. Normalize only the exact corresponding derived label multiplicities;
// the complete raw proof separately checks every catalog edge and selected AST.
func pgAdvancedGenerationTransition(before, after tableedit.Baseline, condition tableedit.Condition, matches func(sc.Column, tableedit.Default) bool) bool {
	var name string
	var generated *tableedit.Generation
	if condition.Operation.Column != nil && condition.Operation.Kind == "addColumn" {
		name, generated = condition.Operation.Column.Name, condition.Operation.Column.Generated
	} else if condition.Operation.Change != nil && condition.Operation.Kind == "changeColumn" {
		name, generated = condition.Operation.Change.Name, condition.Operation.Change.Generated
	}
	if generated == nil || before.Advanced == nil || before.Facts == nil || after.Facts == nil || reflect.DeepEqual(before.Facts.Dependents, after.Facts.Dependents) {
		return tableedit.VerifyTransition(before, after, condition, matches)
	}
	if before.AdvancedEvidence == nil || after.AdvancedEvidence == nil {
		return false
	}
	counts := func(b tableedit.Baseline) (map[string]int, bool) {
		out := map[string]int{}
		attrs := b.AdvancedEvidence.Rows[b.Identity+"/attributes"]
		var num any
		names := map[string]string{}
		for _, attr := range attrs {
			names[fmt.Sprint(attr["attnum"])] = fmt.Sprint(attr["attname"])
			if attr["attname"] == name {
				num = attr["attnum"]
			}
		}
		for _, edge := range b.AdvancedEvidence.Rows[b.Identity+"/dependencies"] {
			if pgAdvancedGeneratedSelfDependency(edge, b.Identity, num) {
				column := names[fmt.Sprint(edge["refobjsubid"])]
				if column == "" {
					return nil, false
				}
				out[column]++
			}
		}
		return out, true
	}
	left, ok := counts(before)
	right, valid := counts(after)
	if !ok || !valid {
		return false
	}
	keys := map[string]bool{}
	for key := range before.Facts.Dependents {
		keys[key] = true
	}
	for key := range after.Facts.Dependents {
		keys[key] = true
	}
	for key := range keys {
		diff := map[string]int{}
		for _, label := range before.Facts.Dependents[key] {
			diff[label]++
		}
		for _, label := range after.Facts.Dependents[key] {
			diff[label]--
		}
		removed, added := 0, 0
		for _, n := range diff {
			if n > 0 {
				removed += n
			} else {
				added -= n
			}
		}
		expected := left[key] - right[key]
		if expected >= 0 && (removed != expected || added != 0) || expected < 0 && (added != -expected || removed != 0) {
			return false
		}
	}
	raw, _ := json.Marshal(before.Facts)
	var facts tableedit.Facts
	if json.Unmarshal(raw, &facts) != nil {
		return false
	}
	facts.Dependents = after.Facts.Dependents
	before.Facts = &facts
	return tableedit.VerifyTransition(before, after, condition, matches)
}

// Call before COMMIT. A mismatch rolls back table changes; user-function or
// sequence side effects remain disclosed and must never be reported undone.
func (p *pgAdvancedDataProof) Verify(ctx context.Context, q structureReader) error {
	if p == nil {
		return nil
	}
	typeProof, err := pgAdvancedBinaryTypes(ctx, q, p.Types)
	if err != nil || typeProof != p.TypeProof {
		return errors.New("The complete trusted binary type/function metadata changed; no retained-value equality proof is accepted.")
	}
	remaining := pgAdvancedDataMaxBytes
	for _, relation := range p.Relations {
		var visible bool
		if q.QueryRow(ctx, `SELECT NOT pg_catalog.row_security_active($1::pg_catalog.oid)`, relation.OID).Scan(&visible) != nil || !visible {
			return errors.New("Complete natural row visibility changed during Apply; a policy-filtered result is never accepted as preservation proof.")
		}
		rows, err := pgAdvancedReadData(ctx, q, relation.Target, relation.Columns, &remaining)
		if err != nil || !reflect.DeepEqual(rows, relation.Rows) {
			return errors.New("An unaffected native value, physical member row count or duplicate multiplicity changed. The transaction must roll back; function/sequence side effects may survive rollback.")
		}
	}
	for target, before := range p.Sequences {
		after, err := pgAdvancedReadSequence(ctx, q, target)
		if err != nil || !pgAdvancedSequencePreserved(before, after) {
			return errors.New("An unaffected owned-sequence counter changed. The transaction must roll back; a sequence advance itself may survive rollback and requires explicit reconciliation.")
		}
	}
	return nil
}

func pgAdvancedDataDescendants(b tableedit.Baseline) map[string]bool {
	out := map[string]bool{b.Identity: true}
	for changed := true; changed; {
		changed = false
		for key, links := range b.AdvancedEvidence.Rows {
			if !strings.HasSuffix(key, "/inherits") {
				continue
			}
			for _, link := range links {
				parent, child := fmt.Sprint(link["inhparent"]), fmt.Sprint(link["inhrelid"])
				if out[parent] && !out[child] && len(b.AdvancedEvidence.Rows[child+"/class"]) == 1 {
					out[child], changed = true, true
				}
			}
		}
	}
	return out
}

// A native heap rewrite preserves relation identity and all external bindings.
// A constant built-in index supplies CLUSTER's ordering without changing values.
func preparePGAdvancedReconstruction(b tableedit.Baseline, d tableedit.Draft, order []string, nameSeed ...string) (tableedit.Prepared, error) {
	p := tableedit.Prepared{}
	if b.Advanced == nil || b.AdvancedEvidence == nil || !d.Reconstruct || len(d.Backfills)+len(d.Columns) != 0 || len(order) != len(b.Columns) {
		return p, tableedit.ErrInvalid
	}
	for i, name := range order {
		if b.Columns[i].Name != name {
			return p, errors.New("Changing PostgreSQL physical column order requires recreating the relation and repairing its complete external/hierarchy/type bindings. Native reconstruction preserves relation identity and the current order; graph recreation is a separate client operation that is not yet implemented.")
		}
	}
	// The bound private name seed survives explicit earlier migration repairs;
	// observed fingerprints and metadata still use the actual current relation.
	if len(b.Fingerprint) < 12 || len(nameSeed) > 1 {
		return p, tableedit.ErrUnsupported
	}
	seed := "__dbeer_rewrite_" + b.Fingerprint[:12]
	if len(nameSeed) == 1 {
		seed = nameSeed[0]
	}
	digest := strings.TrimPrefix(seed, "__dbeer_rewrite_")
	if len(digest) != 12 || seed != "__dbeer_rewrite_"+digest {
		return p, tableedit.ErrUnsupported
	}
	if _, err := hex.DecodeString(digest); err != nil {
		return p, tableedit.ErrUnsupported
	}
	affected := pgAdvancedDataDescendants(b)
	ids := []string{}
	for id := range affected {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		classes := b.AdvancedEvidence.Rows[id+"/class"]
		if len(classes) != 1 {
			return p, tableedit.ErrUnsupported
		}
		cl := classes[0]
		if cl["relkind"] == "p" {
			continue
		}
		if cl["relkind"] != "r" || cl["relpersistence"] != "p" && cl["relpersistence"] != "u" || fmt.Sprint(cl["relam"]) != "2" {
			return p, errors.New("Native reconstruction requires permanent or unlogged heap storage on every affected physical member; no persistence or engine is substituted.")
		}
		facts := b.AdvancedEvidence.Facts[id]
		if facts == nil {
			return p, tableedit.ErrUnsupported
		}
		target := tableedit.Target{Schema: facts.Table.Ref.Schema, Table: facts.Table.Ref.Name}
		if target.Table != cl["relname"] {
			return p, tableedit.ErrUnsupported
		}
		if !target.Valid() || target.Create {
			return p, tableedit.ErrUnsupported
		}
		temp := seed + "_" + id
		originalCluster := ""
		for _, index := range b.AdvancedEvidence.Rows[id+"/indexes"] {
			ic, ok := index["class"].(map[string]any)
			ix, valid := index["index"].(map[string]any)
			if !ok || !valid || ic["relname"] == temp {
				return p, errors.New("The exact native rewrite index name must be absent.")
			}
			if ix["indisclustered"] == true {
				if originalCluster != "" {
					return p, tableedit.ErrUnsupported
				}
				originalCluster = fmt.Sprint(ic["relname"])
			}
		}
		qualified := pgx.Identifier{target.Schema, target.Table}.Sanitize()
		p.SQL = append(p.SQL, "CREATE INDEX "+pgx.Identifier{temp}.Sanitize()+" ON "+qualified+" USING btree ((true));", "CLUSTER "+qualified+" USING "+pgx.Identifier{temp}.Sanitize()+";", "DROP INDEX "+pgx.Identifier{target.Schema, temp}.Sanitize()+" RESTRICT;")
		if originalCluster != "" {
			p.SQL = append(p.SQL, "ALTER TABLE ONLY "+qualified+" CLUSTER ON "+pgx.Identifier{originalCluster}.Sanitize()+";")
		}
		restore, err := pgAdvancedRestoreUnitSQL(b, id, target, "")
		if err != nil {
			return p, err
		}
		if restore != "" {
			p.SQL = append(p.SQL, restore)
		}
		p.Consequences = append(p.Consequences, tableedit.Consequence{Kind: "nativeHierarchy", Object: target.Schema + "." + target.Table, Message: "This physical heap member is rebuilt with the displayed constant-true temporary index and CLUSTER, then that index is removed and its previous CLUSTER ON selection restored. Relation/row-type identities, hierarchy links, partition bounds, RLS/FORCE, policies, ownership, ACLs, labels, native definitions, sequences, triggers and dependencies remain. Physical row locations and internal storage files change; current column order stays exact."})
		if cl["relpersistence"] == "u" {
			p.Consequences = append(p.Consequences, tableedit.Consequence{Kind: "capabilityLoss", Object: target.Schema + "." + target.Table, Message: "This member remains unlogged. PostgreSQL can truncate its data after a crash or unclean shutdown, and it does not provide ordinary WAL-based replication/durability for its contents. Reconstruction does not silently convert persistence."})
		}
	}
	if len(p.SQL) == 0 {
		return p, errors.New("The selected partition hierarchy has no physical heap member to reconstruct.")
	}
	p.Reconstruction = &tableedit.Reconstruction{Method: "postgresql-native-cluster", TemporaryTable: seed, ColumnOrder: append([]string(nil), order...)}
	p.Risks = []string{"All displayed index/rewrite/drop/cluster-selection statements run in one transaction after sorted ONLY ACCESS EXCLUSIVE locks on the complete connected graph and a five-second lock wait. Natural complete row visibility is required on every member; the helper never changes row security, policies, FORCE or roles. Each affected physical member and retained duplicate/value is proved before COMMIT.", "CLUSTER needs extra disk space and rewrites every affected heap and its indexes. Physical row locations change. Native binary observation may invoke type send support during Apply, and native index rebuilding can execute expression/operator support; Preview never scans rows or evaluates expressions. Lost COMMIT acknowledgement remains unknown and never authorizes replay."}
	return p, nil
}

func pgAdvancedReconstructionPreserved(before, after tableedit.Baseline, order []string) bool {
	if before.Advanced == nil || after.Advanced == nil || before.AdvancedEvidence == nil || after.AdvancedEvidence == nil || !tableedit.VerifyColumnOrder(before, after, order, false) {
		return false
	}
	a, b := tableedit.CloneAdvancedEvidence(before.AdvancedEvidence), tableedit.CloneAdvancedEvidence(after.AdvancedEvidence)
	if !reflect.DeepEqual(a.Targets, b.Targets) || len(a.Rows) != len(b.Rows) {
		return false
	}
	for id := range pgAdvancedDataDescendants(before) {
		prefix := id + "/"
		left, right := a.Rows[prefix+"class"], b.Rows[prefix+"class"]
		if len(left) != 1 || len(right) != 1 {
			return false
		}
		if left[0]["relkind"] == "p" {
			continue
		}
		if left[0]["relfilenode"] == right[0]["relfilenode"] || !pgAdvancedToastPreserved(a, b, prefix) {
			return false
		}
		left[0]["relfilenode"] = right[0]["relfilenode"]
		indexes := map[string]map[string]any{}
		for _, row := range b.Rows[prefix+"indexes"] {
			cl, ok := row["class"].(map[string]any)
			if !ok {
				return false
			}
			indexes[fmt.Sprint(cl["oid"])] = cl
		}
		for _, row := range a.Rows[prefix+"indexes"] {
			cl, ok := row["class"].(map[string]any)
			if !ok || indexes[fmt.Sprint(cl["oid"])] == nil {
				return false
			}
			cl["relfilenode"] = indexes[fmt.Sprint(cl["oid"])]["relfilenode"]
		}
		for _, attr := range a.Rows[prefix+"attributes"] {
			for _, next := range b.Rows[prefix+"attributes"] {
				datum, validDatum := attr["attmissingval"].([]any)
				if attr["attname"] == next["attname"] && attr["atthasmissing"] == true && validDatum && len(datum) == 1 && next["atthasmissing"] == false && next["attmissingval"] == nil {
					// The independent exact row proof must confirm materialization.
					attr["atthasmissing"], attr["attmissingval"] = false, nil
				}
			}
		}
		for _, proof := range []*tableedit.AdvancedEvidence{a, b} {
			for _, attr := range proof.Rows[prefix+"attributes"] {
				attr["attoptions"] = tableedit.SemanticPostgresAttributeOptions(attr["attoptions"])
			}
		}
	}
	for key, left := range a.Rows {
		right := b.Rows[key]
		if len(left) != len(right) {
			return false
		}
		sort.Slice(left, func(i, j int) bool { return tableedit.Fingerprint(left[i]) < tableedit.Fingerprint(left[j]) })
		sort.Slice(right, func(i, j int) bool { return tableedit.Fingerprint(right[i]) < tableedit.Fingerprint(right[j]) })
		if !reflect.DeepEqual(left, right) {
			return false
		}
	}
	return true
}

func (s *Session) applyPGAdvancedReconstruction(ctx context.Context, b tableedit.Baseline, p tableedit.Plan) []tableedit.Execution {
	out := make([]tableedit.Execution, len(p.SQL))
	for i := range out {
		out[i].State = "notStarted"
	}
	fill := func(state, message string) []tableedit.Execution {
		for i := range out {
			out[i] = tableedit.Execution{State: state, Message: message}
		}
		return out
	}
	if ctx.Err() != nil || s.TransactionStatus() != "idle" || p.Reconstruction == nil || p.Reconstruction.Method != "postgresql-native-cluster" || b.Advanced == nil {
		return fill("notStarted", "The retained advanced reconstruction plan is not applicable.")
	}
	expected, err := preparePGAdvancedReconstruction(b, tableedit.Draft{Reconstruct: true}, p.Reconstruction.ColumnOrder, p.Reconstruction.TemporaryTable)
	if err != nil || !reflect.DeepEqual(expected.SQL, p.SQL) {
		return fill("notStarted", "The retained native reconstruction statements do not match their exact private evidence.")
	}
	tx, err := s.conn.Begin(ctx)
	if err != nil {
		return fill("notStarted", "Cannot begin the native reconstruction transaction.")
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if e := tx.Rollback(cleanup); e != nil && !errors.Is(e, pgx.ErrTxClosed) {
			closeConnection(s.conn)
		}
	}()
	if _, err = tx.Exec(ctx, "SET LOCAL lock_timeout='5s'"); err != nil {
		return fill("notStarted", "Cannot set the reviewed lock wait.")
	}
	for _, target := range b.AdvancedEvidence.Targets {
		if _, err = tx.Exec(ctx, "LOCK TABLE ONLY "+pgx.Identifier{target.Schema, target.Table}.Sanitize()+" IN ACCESS EXCLUSIVE MODE"); err != nil {
			return fill("notStarted", "Cannot acquire every captured hierarchy lock; no rewrite statement was sent.")
		}
	}
	current, err := readStructure(ctx, tx, b.Target)
	if err != nil || current.Fingerprint != b.Fingerprint {
		return fill("notStarted", "The complete native graph changed; prepare a new preview.")
	}
	proof, err := pgAdvancedBoundDataCapture(ctx, tx, b, tableedit.Condition{Operation: tableedit.Operation{Kind: "reorder"}, AdvancedDataTypes: p.Reconstruction.AdvancedDataTypes, AdvancedDataProof: p.Reconstruction.AdvancedDataProof})
	if err != nil {
		return fill("notStarted", "Complete natural row visibility/native-value/counter proof is unavailable; no rewrite statement was sent.")
	}
	rollback := func(message string) []tableedit.Execution {
		cleanup, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if err := tx.Rollback(cleanup); err != nil {
			closeConnection(s.conn)
			return fill("unknown", "Native reconstruction rollback could not be confirmed. Reconcile explicitly; no replay is authorized.")
		}
		for i := range out {
			if out[i].State == "applied" {
				out[i] = tableedit.Execution{State: "rolledBack", Message: message}
			}
		}
		return out
	}
	for i, sql := range p.SQL {
		if ctx.Err() != nil {
			return rollback("Native reconstruction was cancelled and table changes rolled back.")
		}
		if _, err = tx.Exec(ctx, sql); err != nil {
			out[i] = tableedit.Execution{State: "rolledBack", Message: "The native reconstruction statement failed."}
			return rollback("Native reconstruction failed; table changes rolled back. User support-function side effects may survive rollback.")
		}
		out[i].State = "applied"
		if s.afterStructureStep != nil {
			s.afterStructureStep(i)
		}
	}
	fresh, err := readStructure(ctx, tx, b.Target)
	if err != nil || !pgAdvancedReconstructionPreserved(b, fresh, p.Reconstruction.ColumnOrder) || proof.Verify(ctx, tx) != nil {
		return rollback("Complete native properties, rows, duplicate counts or sequence counters did not match; table changes rolled back. Support-function/sequence side effects may survive rollback.")
	}
	commit := func() error { return tx.Commit(ctx) }
	if s.structureCommitOverride != nil {
		err = s.structureCommitOverride(commit)
	} else {
		err = commit()
	}
	if err != nil {
		closeConnection(s.conn)
		return fill("unknown", "Native reconstruction COMMIT acknowledgement was lost. Reconcile explicitly; no replay is authorized.")
	}
	return out
}
