package mariadb

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"sort"
	"strconv"
	"strings"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/mysql"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

type mariaSchemaRead struct {
	sql       string
	args      []any
	digest    string
	show      bool
	indexOnly bool
}
type mariaSchemaCapture struct {
	periodReads       []mariaPeriodRead
	fieldReads        []mariaFieldRead
	wireError         error
	columnNames       []string
	s                 *Session
	ctx               context.Context
	spec              sc.CaptureSpec
	sink              sc.Sink
	reads             []mariaSchemaRead
	sqlMode           string
	explicitTimestamp bool
	members, bytes    int
	indexAttributes   map[string]map[string]string
	definitions       map[string]string
}

func (s *Session) ReadSchema(ctx context.Context, spec sc.CaptureSpec, sink sc.Sink) error {
	if _, ok := ctx.Deadline(); !ok {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, ExecuteTimeout)
		defer cancel()
	}
	if sink == nil || len(spec.Schemas) == 0 || spec.Limits.Nodes < 1 || spec.Limits.Members < 1 || spec.Limits.Bytes < 1 || spec.Limits.Scalar < 1 {
		return sc.ErrInvalid
	}
	maximum := sc.DefaultLimits()
	if spec.Limits.Nodes > maximum.Nodes || spec.Limits.Members > maximum.Members || spec.Limits.Bytes > maximum.Bytes || spec.Limits.Scalar > maximum.Scalar {
		return sc.ErrLimit
	}
	if len(spec.Schemas) > spec.Limits.Nodes {
		return sc.ErrLimit
	}
	seen := map[string]bool{}
	for _, schema := range spec.Schemas {
		if !sc.ValidName(schema) || seen[schema] {
			return sc.ErrInvalid
		}
		seen[schema] = true
	}
	var captured error
	var reader *mariaSchemaCapture
	response := s.executeWith(ctx, protocol.Command{}, func(_ *collector, _ *wire.Result) error {
		bounded := &mariaSchemaSink{budget: sc.NewCollector(ctx, spec.Limits), next: sink}
		r := &mariaSchemaCapture{s: s, ctx: ctx, spec: spec, sink: bounded, definitions: map[string]string{}}
		reader = r
		captured = r.capture()
		if r.wireError != nil {
			return r.wireError
		}
		if captured != nil {
			return &adapter.ConnectionError{Category: "unsupported", Message: "MariaDB schema metadata could not be captured completely."}
		}
		return nil
	})
	if captured != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if reader != nil && reader.wireError != nil {
			return sc.ErrInvalid
		}
		return captured
	}
	if response.Type != "query.result" {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return sc.ErrInvalid
	}
	return nil
}

// The caller's sink cannot bypass the capture's total object/member/byte budget.
type mariaSchemaSink struct {
	budget *sc.Collector
	next   sc.Sink
}

func (s *mariaSchemaSink) Context(v sc.CaptureContext) error {
	if e := s.budget.Context(v); e != nil {
		return e
	}
	return s.next.Context(v)
}
func (s *mariaSchemaSink) Inventory(v sc.Inventory) error {
	if e := s.budget.Inventory(v); e != nil {
		return e
	}
	return s.next.Inventory(v)
}
func (s *mariaSchemaSink) Table(v sc.Table) error {
	if e := s.budget.Table(v); e != nil {
		return e
	}
	return s.next.Table(v)
}
func (s *mariaSchemaSink) Type(v sc.TypeDefinition) error {
	if e := s.budget.Type(v); e != nil {
		return e
	}
	return s.next.Type(v)
}
func (s *mariaSchemaSink) Sequence(v sc.Sequence) error {
	if e := s.budget.Sequence(v); e != nil {
		return e
	}
	return s.next.Sequence(v)
}
func (s *mariaSchemaSink) Issue(v sc.Issue) error {
	if e := s.budget.Issue(v); e != nil {
		return e
	}
	return s.next.Issue(v)
}

func (r *mariaSchemaCapture) rows(sql string, args ...any) ([][]*string, error) {
	return r.read(sql, false, args...)
}
func (r *mariaSchemaCapture) read(sql string, show bool, args ...any) ([][]*string, error) {
	if e := r.ctx.Err(); e != nil {
		return nil, e
	}
	statement := sql
	if !show {
		statement += " LIMIT " + strconv.Itoa(r.spec.Limits.Members+1)
	}
	result, e := r.s.work.client.Execute(statement, args...)
	if e != nil {
		r.wireError = e
		if r.ctx.Err() != nil {
			return nil, r.ctx.Err()
		}
		return nil, sc.ErrInvalid
	}
	defer result.Close()
	r.columnNames = make([]string, len(result.Fields))
	for i, field := range result.Fields {
		r.columnNames[i] = strings.Clone(string(field.Name))
	}
	if result.RowNumber() > r.spec.Limits.Members || result.Warnings != 0 {
		return nil, sc.ErrLimit
	}
	out := make([][]*string, result.RowNumber())
	bytes := 0
	for i := range out {
		out[i] = make([]*string, result.ColumnNumber())
		for j := range out[i] {
			null, e := result.IsNull(i, j)
			if e != nil {
				return nil, sc.ErrInvalid
			}
			if null {
				continue
			}
			value, e := result.GetString(i, j)
			if e != nil {
				return nil, sc.ErrInvalid
			}
			if len(value) > r.spec.Limits.Scalar {
				return nil, sc.ErrLimit
			}
			bytes += len(value)
			if bytes > r.spec.Limits.Bytes {
				return nil, sc.ErrLimit
			}
			value = strings.Clone(value)
			out[i][j] = &value
		}
	}
	return out, nil
}
func (r *mariaSchemaCapture) tracked(sql string, args ...any) ([][]*string, error) {
	return r.track(sql, false, args...)
}
func (r *mariaSchemaCapture) track(sql string, show bool, args ...any) ([][]*string, error) {
	rows, e := r.read(sql, show, args...)
	if e != nil {
		return nil, e
	}
	raw, e := json.Marshal(mysql.CatalogRawRows(rows))
	if e != nil {
		return nil, sc.ErrInvalid
	}
	r.members += len(rows)
	r.bytes += len(raw)
	if r.members > r.spec.Limits.Members || r.bytes > r.spec.Limits.Bytes {
		return nil, sc.ErrLimit
	}
	digest := sha256.Sum256(raw)
	r.reads = append(r.reads, mariaSchemaRead{sql: sql, args: append([]any(nil), args...), digest: hex.EncodeToString(digest[:]), show: show})
	return rows, nil
}
func mariaText(row []*string, i int) string {
	if i >= len(row) || row[i] == nil {
		return ""
	}
	return *row[i]
}
func mariaNumber(value string) *int64 {
	n, e := strconv.ParseInt(value, 10, 64)
	if e != nil {
		return nil
	}
	return &n
}
func (r *mariaSchemaCapture) issue(ref *sc.Ref, property, code, message string) error {
	return r.sink.Issue(sc.Issue{Ref: ref, Property: property, Code: code, Message: message, BlocksEquality: true, Planning: "manual"})
}
func (r *mariaSchemaCapture) definition(ref sc.Ref) (string, error) {
	sql := "SHOW CREATE TABLE " + QuoteIdentifier(ref.Schema) + "." + QuoteIdentifier(ref.Name)
	rows, e := r.read(sql, true)
	if e != nil {
		return "", e
	}
	if len(rows) != 1 || len(rows[0]) < 2 || rows[0][1] == nil {
		return "", sc.ErrInvalid
	}
	raw := *rows[0][1]
	if strings.HasPrefix(strings.ToUpper(raw), "CREATE TEMPORARY TABLE") {
		return "", sc.ErrInvalid
	}
	r.bytes += len(raw)
	if r.bytes > r.spec.Limits.Bytes {
		return "", sc.ErrLimit
	}
	digest := mariaDefinitionIndexDigest(raw, r.sqlMode)
	r.reads = append(r.reads, mariaSchemaRead{sql: sql, digest: digest, show: true, indexOnly: true})
	r.definitions[ref.Schema+"\x00"+ref.Name] = raw
	return raw, nil
}
func (r *mariaSchemaCapture) visibility(principal string) (map[string]bool, error) {
	grants := map[string]bool{}
	if strings.Count(principal, "@") != 1 {
		return grants, nil
	}
	user, host, _ := strings.Cut(principal, "@")
	grantee := "'" + strings.ReplaceAll(user, "'", "''") + "'@'" + strings.ReplaceAll(host, "'", "''") + "'"
	rows, e := r.tracked("SELECT PRIVILEGE_TYPE FROM information_schema.USER_PRIVILEGES WHERE BINARY GRANTEE=BINARY ? ORDER BY BINARY PRIVILEGE_TYPE", grantee)
	if e != nil {
		return nil, e
	}
	for _, row := range rows {
		if len(row) != 1 || row[0] == nil {
			return nil, sc.ErrInvalid
		}
		grants[*row[0]] = true
	}
	return grants, nil
}
func (r *mariaSchemaCapture) capture() error {
	started := time.Now().UTC().Format(time.RFC3339Nano)
	rows, e := r.tracked("SELECT VERSION(),DATABASE(),@@sql_mode,@@explicit_defaults_for_timestamp,CURRENT_USER(),CURRENT_ROLE(),@@lower_case_table_names,@@character_set_connection,@@collation_connection,@@character_set_results,@@check_constraint_checks,@@character_set_client")
	if e != nil {
		return e
	}
	if len(rows) != 1 || len(rows[0]) != 12 {
		return sc.ErrInvalid
	}
	v := rows[0]
	if mariaText(v, 7) != "utf8mb4" || mariaText(v, 9) != "utf8mb4" || mariaText(v, 11) != "utf8mb4" {
		return sc.ErrInvalid
	}
	version, comment, identity := r.s.nativeServerObservation()
	if identity == "" || mariaText(v, 0) != version || !supportedNativeVersion(version, comment) {
		return sc.ErrInvalid
	}
	r.sqlMode = mariaText(v, 2)
	r.explicitTimestamp = mariaText(v, 3) == "1"
	options := []sc.Option{}
	for i, key := range map[int]string{2: "sqlMode", 3: "explicitDefaultsForTimestamp", 4: "principal", 5: "activeRole", 6: "lowerCaseTableNames", 7: "connectionCharset", 8: "connectionCollation", 9: "resultCharset", 10: "checkConstraintChecks", 11: "clientCharset"} {
		options = append(options, sc.Option{Name: key, Value: mariaText(v, i)})
	}
	sortMariaOptions(options)
	roles, e := r.tracked("SELECT ROLE_NAME FROM information_schema.ENABLED_ROLES ORDER BY BINARY ROLE_NAME")
	if e != nil {
		return e
	}
	roleJSON, e := json.Marshal(mysql.CatalogRawRows(roles))
	if e != nil {
		return sc.ErrInvalid
	}
	options = append(options, sc.Option{Name: "enabledRoles", Value: string(roleJSON)})
	context := sc.CaptureContext{Engine: "mariadb", Version: version, Database: mariaText(v, 1), StartedAt: started, Consistency: "bestEffort", Visibility: "complete", EngineContext: sc.Known(options)}
	grants, e := r.visibility(mariaText(v, 4))
	if e != nil {
		return e
	}
	for _, schema := range r.spec.Schemas {
		visible := grants["SELECT"]
		if !visible && strings.Count(mariaText(v, 4), "@") == 1 {
			user, host, _ := strings.Cut(mariaText(v, 4), "@")
			grantee := "'" + strings.ReplaceAll(user, "'", "''") + "'@'" + strings.ReplaceAll(host, "'", "''") + "'"
			rows, e := r.tracked("SELECT PRIVILEGE_TYPE FROM information_schema.SCHEMA_PRIVILEGES WHERE BINARY GRANTEE=BINARY ? AND BINARY TABLE_SCHEMA=BINARY ? AND PRIVILEGE_TYPE='SELECT'", grantee, schema)
			if e != nil {
				return e
			}
			visible = len(rows) == 1
		}
		inv := sc.Inventory{Schema: schema, Existence: "unknown", Tables: sc.Complete[sc.Ref](nil), Types: sc.Complete[sc.Ref](nil)}
		exists, e := r.tracked("SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE BINARY SCHEMA_NAME=BINARY ?", schema)
		if e != nil {
			return e
		}
		if len(exists) > 0 {
			inv.Existence = "present"
		} else if visible {
			inv.Existence = "absent"
		}
		if !visible {
			context.Visibility = "unknown"
			inv.Tables.Complete = false
			inv.Types.Complete = false
			if e = r.issue(nil, "inventory", "visibilityUnknown", "Schema-wide native metadata visibility was not proven from direct grants."); e != nil {
				return e
			}
		}
		tables, e := r.tracked("SELECT TABLE_NAME,ENGINE,TABLE_COLLATION,CREATE_OPTIONS,TABLE_COMMENT,TABLE_TYPE FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=BINARY ? AND TABLE_TYPE IN ('BASE TABLE','SYSTEM VERSIONED','SEQUENCE') ORDER BY BINARY TABLE_NAME", schema)
		if e != nil {
			return e
		}
		if len(tables) > r.spec.Limits.Nodes {
			return sc.ErrLimit
		}
		for _, row := range tables {
			if len(row) != 6 {
				return sc.ErrInvalid
			}
			ref := sc.Ref{Kind: "table", Schema: schema, Name: mariaText(row, 0)}
			if mariaText(row, 5) == "SEQUENCE" {
				if e = r.sequence(ref); e != nil {
					return e
				}
				continue
			}
			inv.Tables.Items = append(inv.Tables.Items, ref)
			if e = r.table(ref, row); e != nil {
				return e
			}
		}
		if e = r.sink.Inventory(inv); e != nil {
			return e
		}
	}
	for _, read := range r.reads {
		rows, e := r.read(read.sql, read.show, read.args...)
		if e != nil {
			return e
		}
		digest := mariaRowsDigest(rows)
		if read.indexOnly {
			if len(rows) != 1 || len(rows[0]) < 2 || rows[0][1] == nil {
				return sc.ErrInvalid
			}
			digest = mariaDefinitionIndexDigest(*rows[0][1], r.sqlMode)
		}
		if digest != read.digest {
			context.Visibility = "partial"
			if e = r.issue(nil, "capture", "concurrentDDL", "Native metadata changed during the best-effort capture."); e != nil {
				return e
			}
			break
		}
	}
	if e := r.nativePeriodsFresh(); e != nil {
		return e
	}
	if e := r.nativeDefaultsFresh(); e != nil {
		context.Visibility = "partial"
		if e = r.issue(nil, "defaults", "concurrentDDL", "Native stored-default metadata changed during capture or its exact binding became unavailable."); e != nil {
			return e
		}
	}
	context.FinishedAt = time.Now().UTC().Format(time.RFC3339Nano)
	return r.sink.Context(context)
}

func sortMariaOptions(options []sc.Option) {
	sort.Slice(options, func(i, j int) bool { return options[i].Name < options[j].Name })
}

func mariaRowsDigest(rows [][]*string) string {
	raw, e := json.Marshal(mysql.CatalogRawRows(rows))
	if e != nil {
		return ""
	}
	digest := sha256.Sum256(raw)
	return hex.EncodeToString(digest[:])
}

func mariaDefinitionIndexDigest(raw, mode string) string {
	attrs, known, parsed := mariaIndexAttributeEvidence(raw, mode)
	rows := [][]*string{}
	parsedValue := strconv.FormatBool(parsed)
	rows = append(rows, []*string{&parsedValue})
	// The same native definition supplies opaque partition/period facts. Bind
	// those properties too, while still excluding volatile table counters.
	partition, partitionKnown := mariaPartitionTail(raw, mode)
	partitionStatus := strconv.FormatBool(partitionKnown)
	rows = append(rows, []*string{&partitionStatus, &partition})
	periods, periodsKnown := mariaApplicationPeriods(raw, mode)
	periodsStatus := strconv.FormatBool(periodsKnown)
	periodsCount := strconv.Itoa(len(periods))
	rows = append(rows, []*string{&periodsStatus, &periodsCount})
	for _, period := range periods {
		owned := period
		rows = append(rows, []*string{&owned})
	}

	names := []string{}
	for name := range known {
		names = append(names, name)
	}
	for name := range attrs {
		if _, present := known[name]; !present {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	for _, name := range names {
		owned := name
		flag := strconv.FormatBool(known[name])
		rows = append(rows, []*string{&owned, &flag})
		keys := []string{}
		for key := range attrs[name] {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			k, v := key, attrs[name][key]
			rows = append(rows, []*string{&k, &v})
		}
	}
	return mariaRowsDigest(rows)
}
