package postgres

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"reflect"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

type pgPhysicalRelation struct {
	Target             tableedit.Target
	OID                uint32
	Class              map[string]any
	Columns            []map[string]any
	Defaults           []json.RawMessage
	Constraints        []json.RawMessage
	Indexes            []json.RawMessage
	Triggers           []json.RawMessage
	Dependencies       []json.RawMessage
	Comments           []json.RawMessage
	ExtendedStatistics []json.RawMessage
	Policies           []json.RawMessage
	Inherits           []json.RawMessage
	Partition          json.RawMessage
	States             []tableedit.PhysicalIndexState
	Children           []tableedit.PhysicalPartition
	Method             string
	KeyColumns         []string
	KeyCount           int
	DefaultOID         uint32
}
type pgPhysicalEvidence struct {
	Version       int
	Environment   string
	Relations     []pgPhysicalRelation
	Ordinary      *tableedit.Baseline
	Guards        []tableedit.IndexGuard
	SQL           []string
	RIFunctions   map[string]string
	RIProof       string
	DetachCheck   string
	Transactional bool
}

func pgPhysicalName(t tableedit.Target) string { return pgx.Identifier{t.Schema, t.Table}.Sanitize() }
func pgPhysicalRows(ctx context.Context, q structureReader, sql string, args ...any) ([]json.RawMessage, error) {
	rows, e := q.Query(ctx, sql, args...)
	if e != nil {
		return nil, tableedit.ErrUnsupported
	}
	defer rows.Close()
	out := []json.RawMessage{}
	size := 0
	for rows.Next() {
		var raw string
		if rows.Scan(&raw) != nil {
			return nil, tableedit.ErrUnsupported
		}
		size += len(raw)
		if len(out) >= 2048 || size > 2<<20 {
			return nil, tableedit.ErrUnsupported
		}
		out = append(out, json.RawMessage(strings.Clone(raw)))
	}
	return out, rows.Err()
}
func pgPhysicalRead(ctx context.Context, q structureReader, t tableedit.Target) (pgPhysicalRelation, error) {
	r := pgPhysicalRelation{Target: t, States: []tableedit.PhysicalIndexState{}, Children: []tableedit.PhysicalPartition{}}
	var raw string
	var owned bool
	e := q.QueryRow(ctx, `SELECT c.oid,pg_catalog.row_to_json(c)::pg_catalog.text,pg_catalog.pg_has_role(c.relowner,'USAGE') FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname=$2`, t.Schema, t.Table).Scan(&r.OID, &raw, &owned)
	if errors.Is(e, pgx.ErrNoRows) {
		r.Class = map[string]any{"absent": true}
		return r, nil
	}
	if e != nil || !owned || strings.HasPrefix(t.Schema, "pg_") || t.Schema == "information_schema" || json.Unmarshal([]byte(raw), &r.Class) != nil {
		return r, tableedit.ErrUnsupported
	}
	if r.Class["relpersistence"] != "p" || (r.Class["relkind"] != "r" && r.Class["relkind"] != "p") || r.Class["relrowsecurity"] == true || r.Class["relforcerowsecurity"] == true || fmt.Sprint(r.Class["reloftype"]) != "0" {
		return r, errors.New("Physical authoring requires an owned permanent ordinary or declaratively partitioned table without RLS or a typed-table binding.")
	}
	for _, k := range []string{"relpages", "reltuples", "relallvisible", "relallfrozen", "relfrozenxid", "relminmxid", "relhasindex"} {
		delete(r.Class, k)
	}
	cols, e := pgPhysicalRows(ctx, q, `SELECT pg_catalog.json_build_object('attname',a.attname,'attnum',a.attnum,'atttypid',a.atttypid,'atttypmod',a.atttypmod,'attcollation',a.attcollation,'attnotnull',a.attnotnull,'attidentity',a.attidentity,'attgenerated',a.attgenerated,'attisdropped',a.attisdropped,'attinhcount',a.attinhcount,'attislocal',a.attislocal,'attstorage',a.attstorage,'attoptions',a.attoptions,'attacl',a.attacl,'atthasmissing',a.atthasmissing,'nativeType',n.nspname||'.'||t.typname)::pg_catalog.text FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_type t ON t.oid=a.atttypid JOIN pg_catalog.pg_namespace n ON n.oid=t.typnamespace WHERE a.attrelid=$1 AND a.attnum>0 ORDER BY a.attnum LIMIT 130`, r.OID)
	if e != nil || len(cols) > tableedit.MaxColumns {
		return r, tableedit.ErrUnsupported
	}
	r.Columns = []map[string]any{}
	for _, raw := range cols {
		var c map[string]any
		if json.Unmarshal(raw, &c) != nil {
			return r, tableedit.ErrUnsupported
		}
		if c["atthasmissing"] == true {
			return r, errors.New("Physical partition proof requires no stored fast-default values; materialize them in a separately reviewed reconstruction first.")
		}
		r.Columns = append(r.Columns, c)
	}
	// Read the complete version-specific attribute row only when no missing datum
	// can invoke a user-defined element output routine. CASE protects observation races.
	completeColumns, completeErr := pgPhysicalRows(ctx, q, `SELECT CASE WHEN a.atthasmissing THEN NULL::pg_catalog.text ELSE (pg_catalog.to_jsonb(a)||pg_catalog.jsonb_build_object('nativeType',n.nspname||'.'||t.typname))::pg_catalog.text END FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_type t ON t.oid=a.atttypid JOIN pg_catalog.pg_namespace n ON n.oid=t.typnamespace WHERE a.attrelid=$1 AND a.attnum>0 ORDER BY a.attnum LIMIT 130`, r.OID)
	if completeErr != nil || len(completeColumns) != len(r.Columns) {
		return r, tableedit.ErrUnsupported
	}
	for i, raw := range completeColumns {
		var column map[string]any
		if json.Unmarshal(raw, &column) != nil {
			return r, tableedit.ErrUnsupported
		}
		r.Columns[i] = column
	}
	queries := []struct {
		out *[]json.RawMessage
		sql string
	}{
		{&r.Defaults, `SELECT pg_catalog.row_to_json(d)::pg_catalog.text FROM pg_catalog.pg_attrdef d WHERE d.adrelid=$1 ORDER BY d.adnum LIMIT 130`},
		{&r.Constraints, `SELECT pg_catalog.row_to_json(c)::pg_catalog.text FROM pg_catalog.pg_constraint c WHERE c.conrelid=$1 OR c.confrelid=$1 ORDER BY c.oid LIMIT 2049`},
		{&r.Indexes, `SELECT pg_catalog.json_build_object('index',pg_catalog.row_to_json(i),'class',pg_catalog.row_to_json(c),'parents',COALESCE((SELECT pg_catalog.json_agg(h.inhparent ORDER BY h.inhparent) FROM pg_catalog.pg_inherits h WHERE h.inhrelid=c.oid),'[]'))::pg_catalog.text FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class c ON c.oid=i.indexrelid WHERE i.indrelid=$1 ORDER BY c.relname COLLATE pg_catalog."C" LIMIT 130`},
		{&r.Triggers, `SELECT pg_catalog.row_to_json(t)::pg_catalog.text FROM pg_catalog.pg_trigger t WHERE t.tgrelid=$1 ORDER BY t.oid LIMIT 2049`},
		{&r.Dependencies, `SELECT pg_catalog.row_to_json(d)::pg_catalog.text FROM pg_catalog.pg_depend d WHERE (d.refclassid='pg_catalog.pg_class'::pg_catalog.regclass AND d.refobjid=$1) OR (d.classid='pg_catalog.pg_class'::pg_catalog.regclass AND d.objid=$1) ORDER BY d.classid,d.objid,d.objsubid,d.refclassid,d.refobjid,d.refobjsubid LIMIT 2049`},
		{&r.Inherits, `SELECT pg_catalog.row_to_json(i)::pg_catalog.text FROM pg_catalog.pg_inherits i WHERE i.inhparent=$1 OR i.inhrelid=$1 ORDER BY i.inhparent,i.inhrelid LIMIT 130`},
		{&r.Comments, `SELECT pg_catalog.row_to_json(d)::pg_catalog.text FROM pg_catalog.pg_description d WHERE d.classoid='pg_catalog.pg_class'::pg_catalog.regclass AND (d.objoid=$1 OR d.objoid IN (SELECT indexrelid FROM pg_catalog.pg_index WHERE indrelid=$1)) OR d.classoid='pg_catalog.pg_constraint'::pg_catalog.regclass AND d.objoid IN (SELECT oid FROM pg_catalog.pg_constraint WHERE conrelid=$1) OR d.classoid='pg_catalog.pg_trigger'::pg_catalog.regclass AND d.objoid IN (SELECT oid FROM pg_catalog.pg_trigger WHERE tgrelid=$1) ORDER BY d.classoid,d.objoid,d.objsubid LIMIT 2049`},
		{&r.ExtendedStatistics, `SELECT pg_catalog.row_to_json(s)::pg_catalog.text FROM pg_catalog.pg_statistic_ext s WHERE s.stxrelid=$1 ORDER BY s.oid LIMIT 130`},
		{&r.Policies, `SELECT pg_catalog.row_to_json(p)::pg_catalog.text FROM pg_catalog.pg_policy p WHERE p.polrelid=$1 ORDER BY p.oid LIMIT 130`},
	}
	for stage, x := range queries {
		v, e := pgPhysicalRows(ctx, q, x.sql, r.OID)
		if e != nil {
			return r, fmt.Errorf("Physical catalog proof stage %d is unavailable.", stage)
		}
		*x.out = v
	}
	// Physical planner statistics in index pg_class rows are volatile too.
	for i, raw := range r.Indexes {
		var m map[string]any
		if json.Unmarshal(raw, &m) != nil {
			return r, tableedit.ErrUnsupported
		}
		c, _ := m["class"].(map[string]any)
		for _, k := range []string{"relpages", "reltuples", "relallvisible", "relallfrozen", "relfrozenxid", "relminmxid"} {
			delete(c, k)
		}
		r.Indexes[i], _ = json.Marshal(m)
	}
	parts, e := pgPhysicalRows(ctx, q, `SELECT pg_catalog.row_to_json(p)::pg_catalog.text FROM pg_catalog.pg_partitioned_table p WHERE p.partrelid=$1`, r.OID)
	if e != nil {
		return r, e
	}
	if len(parts) > 0 {
		r.Partition = parts[0]
		var p struct {
			Strategy string      `json:"partstrat"`
			Count    int         `json:"partnatts"`
			Default  json.Number `json:"partdefid"`
		}
		if json.Unmarshal(parts[0], &p) != nil {
			return r, tableedit.ErrUnsupported
		}
		r.Method = map[string]string{"r": "range", "l": "list", "h": "hash"}[p.Strategy]
		r.KeyCount = p.Count
		defaultOID, parseErr := strconv.ParseUint(string(p.Default), 10, 32)
		if parseErr != nil {
			return r, tableedit.ErrUnsupported
		}
		r.DefaultOID = uint32(defaultOID)
		keyRows, keyErr := q.Query(ctx, `SELECT COALESCE(a.attname,'') FROM pg_catalog.pg_partitioned_table p CROSS JOIN LATERAL pg_catalog.unnest(p.partattrs) WITH ORDINALITY k(num,ord) LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid=p.partrelid AND a.attnum=k.num WHERE p.partrelid=$1 ORDER BY k.ord`, r.OID)
		if keyErr != nil {
			return r, tableedit.ErrUnsupported
		}
		for keyRows.Next() {
			var name string
			if keyRows.Scan(&name) != nil {
				keyRows.Close()
				return r, tableedit.ErrUnsupported
			}
			if name != "" {
				r.KeyColumns = append(r.KeyColumns, name)
			}
		}
		keyErr = keyRows.Err()
		keyRows.Close()
		if keyErr != nil {
			return r, tableedit.ErrUnsupported
		}

	}
	rows, e := q.Query(ctx, `SELECT n.nspname,c.relname,COALESCE(c.relpartbound::pg_catalog.text,''),i.inhdetachpending FROM pg_catalog.pg_inherits i JOIN pg_catalog.pg_class c ON c.oid=i.inhrelid JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE i.inhparent=$1 ORDER BY n.nspname COLLATE pg_catalog."C",c.relname COLLATE pg_catalog."C" LIMIT 130`, r.OID)
	if e != nil {
		return r, tableedit.ErrUnsupported
	}
	for rows.Next() {
		var p tableedit.PhysicalPartition
		var t tableedit.Target
		if rows.Scan(&t.Schema, &t.Table, &p.Description, &p.DetachPending) != nil {
			rows.Close()
			return r, tableedit.ErrUnsupported
		}
		p.Name = t.Table
		p.Target = &t
		p.Method = r.Method
		r.Children = append(r.Children, p)
	}
	e = rows.Err()
	rows.Close()
	if e != nil || len(r.Children) > 128 {
		return r, tableedit.ErrUnsupported
	}
	rows, e = q.Query(ctx, `SELECT c.relname,i.indisvalid,i.indisready,i.indislive FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class c ON c.oid=i.indexrelid WHERE i.indrelid=$1 ORDER BY c.relname COLLATE pg_catalog."C" LIMIT 130`, r.OID)
	if e != nil {
		return r, tableedit.ErrUnsupported
	}
	for rows.Next() {
		var v tableedit.PhysicalIndexState
		if rows.Scan(&v.Name, &v.Valid, &v.Ready, &v.Live) != nil {
			rows.Close()
			return r, tableedit.ErrUnsupported
		}
		r.States = append(r.States, v)
	}
	e = rows.Err()
	rows.Close()
	return r, e
}
func (r pgPhysicalRelation) object() tableedit.PhysicalObject {
	columns := []tableedit.ObservedColumn{}
	for _, c := range r.Columns {
		if c["attisdropped"] != true {
			name, _ := c["attname"].(string)
			typ, _ := c["nativeType"].(string)
			columns = append(columns, tableedit.ObservedColumn{Name: name, NativeType: typ, Nullable: c["attnotnull"] != true})
		}
	}

	kind, _ := r.Class["relkind"].(string)
	if r.Class["absent"] == true {
		kind = "absent"
	}
	return tableedit.PhysicalObject{Columns: columns, PartitionMethod: r.Method, PartitionKeyCount: r.KeyCount, PartitionColumns: r.KeyColumns, Target: r.Target, Identity: strconv.FormatUint(uint64(r.OID), 10), Kind: kind, Fingerprint: tableedit.Fingerprint(r), Partitions: r.Children, Indexes: r.States, Limitations: []string{"Raw catalog bounds are observations, not portable SQL. Catalog inspection never evaluates expressions or scans rows."}}
}
func (s *Session) pgPhysicalInspect(ctx context.Context, d tableedit.PhysicalDraft) (pgPhysicalEvidence, error) {
	var e pgPhysicalEvidence
	if !d.Valid() || s.TransactionStatus() != "idle" || !nativePostgresEncodingSafe(s.conn.PgConn().ParameterStatus("client_encoding"), s.conn.PgConn().ParameterStatus("server_encoding")) {
		return e, tableedit.ErrUnsupported
	}
	tx, err := s.conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return e, tableedit.ErrUnsupported
	}
	defer structureRollback(tx)
	if tx.QueryRow(ctx, `SELECT pg_catalog.current_setting('server_version_num')::pg_catalog.int4,pg_catalog.current_database()||':'||current_user||':'||pg_catalog.current_setting('search_path')||':'||pg_catalog.current_setting('server_encoding')||':'||pg_catalog.current_setting('standard_conforming_strings')`).Scan(&e.Version, &e.Environment) != nil || e.Version < 140000 || e.Version >= 190000 {
		return e, errors.New("Guarded PostgreSQL physical operations require PostgreSQL 14 through 18.")
	}
	if e.Version < 150000 {
		var err error
		e.RIFunctions, e.RIProof, err = pgPhysicalReadRI(ctx, tx)
		if err != nil {
			return e, err
		}
	}
	targets := []tableedit.Target{d.Target}
	r, err := pgPhysicalRead(ctx, tx, d.Target)
	if err != nil || r.OID == 0 {
		return e, tableedit.ErrUnsupported
	}
	e.Relations = append(e.Relations, r)
	if d.Intent.Child != nil {
		targets = append(targets, *d.Intent.Child)
	}
	for _, p := range r.Children {
		if p.Target != nil {
			targets = append(targets, *p.Target)
		}
	}
	seen := map[tableedit.Target]bool{d.Target: true}
	for _, t := range targets[1:] {
		if seen[t] {
			continue
		}
		if len(e.Relations) >= 130 {
			return e, tableedit.ErrUnsupported
		}
		seen[t] = true
		r, err := pgPhysicalRead(ctx, tx, t)
		if err != nil {
			return e, err
		}
		e.Relations = append(e.Relations, r)
	}
	if raw, marshalErr := json.Marshal(e); marshalErr != nil || len(raw) > 8<<20 {
		return e, errors.New("Physical catalog evidence exceeds the bounded 8 MiB plan limit.")
	}
	if err = tx.Commit(ctx); err != nil {
		return e, tableedit.ErrUnsupported
	}
	return e, nil
}
func pgPhysicalLiteral(v tableedit.PhysicalValue) (string, error) {
	if !v.Valid() {
		return "", tableedit.ErrInvalid
	}
	switch v.Kind {
	case "integer":
		return *v.Value, nil
	case "text":
		return postgresTextLiteral(*v.Value), nil
	case "null":
		return "NULL", nil
	case "min":
		return "MINVALUE", nil
	case "max":
		return "MAXVALUE", nil
	}
	return "", tableedit.ErrInvalid
}
func pgPhysicalBound(b tableedit.PhysicalBound, method string, keys int) (string, error) {
	if !b.Valid() || b.Kind != "default" && b.Kind != method {
		return "", tableedit.ErrInvalid
	}
	tuple := func(v []tableedit.PhysicalValue, allowNull bool) (string, error) {
		if len(v) != keys {
			return "", tableedit.ErrInvalid
		}
		out := []string{}
		for _, x := range v {
			if x.Kind == "null" && !allowNull {
				return "", tableedit.ErrInvalid
			}
			z, e := pgPhysicalLiteral(x)
			if e != nil {
				return "", e
			}
			out = append(out, z)
		}
		return "(" + strings.Join(out, ", ") + ")", nil
	}
	switch b.Kind {
	case "default":
		if method == "hash" {
			return "", tableedit.ErrInvalid
		}
		return "DEFAULT", nil
	case "range":
		a, e := tuple(b.From, false)
		if e != nil {
			return "", e
		}
		z, e := tuple(b.To, false)
		if e != nil {
			return "", e
		}
		return "FOR VALUES FROM " + a + " TO " + z, nil
	case "list":
		if keys != 1 {
			return "", tableedit.ErrUnsupported
		}
		out := []string{}
		for _, v := range b.Values {
			if len(v) != 1 || v[0].Kind == "min" || v[0].Kind == "max" {
				return "", tableedit.ErrInvalid
			}
			z, e := pgPhysicalLiteral(v[0])
			if e != nil {
				return "", e
			}
			out = append(out, z)
		}
		return "FOR VALUES IN (" + strings.Join(out, ", ") + ")", nil
	case "hash":
		return fmt.Sprintf("FOR VALUES WITH (MODULUS %d, REMAINDER %d)", b.Modulus, *b.Remainder), nil
	}
	return "", tableedit.ErrInvalid
}
func (s *Session) PhysicalPrepare(ctx context.Context, d tableedit.PhysicalDraft) (tableedit.PhysicalPlan, error) {
	p := tableedit.PhysicalPlan{Engine: "postgresql", Draft: d, SQL: []string{}, Prerequisites: []string{"An idle dedicated physical session, complete current metadata and confirmation of this exact plan are required."}, Risks: []string{"Preview reads bounded catalogs only; it never scans rows or executes expressions. Apply may scan tables, invoke expression/operator/trigger/event-trigger code, wait for snapshots or locks, and consume disk. No CASCADE, disabled constraint, automatic retry or cleanup is generated.", "Stop does not undo an acknowledged operation. Lost server acknowledgement stays unknown even if later catalog observation resembles the requested result."}, Consequences: []tableedit.Consequence{}, TransactionMode: "transaction", Locking: "Ordered ACCESS EXCLUSIVE table locks; lock_timeout=5s. Apply uses one transaction for the displayed operation."}
	e, err := s.pgPhysicalInspect(ctx, d)
	if err != nil {
		return p, err
	}
	p.ServerVersion = e.Version
	for _, r := range e.Relations {
		p.Objects = append(p.Objects, r.object())
	}
	r := e.Relations[0]
	x := d.Intent
	target := pgPhysicalName(d.Target)
	e.Transactional = true
	switch x.Kind {
	case "concurrentIndex":
		if r.Class["relkind"] != "r" || len(r.Children) > 0 {
			return p, errors.New("CREATE/DROP INDEX CONCURRENTLY requires an ordinary table or leaf partition; PostgreSQL does not support it on partitioned parents.")
		}
		b := tableedit.Baseline{Target: d.Target, Engine: "postgresql", Columns: []tableedit.ObservedColumn{}, Keys: []tableedit.Key{}, Indexes: []tableedit.Index{}, Identity: strconv.FormatUint(uint64(r.OID), 10)}
		b.Facts, err = readStructureFacts(ctx, s.conn, d.Target, r.OID)
		if err != nil {
			return p, err
		}
		for _, c := range r.Columns {
			if c["attisdropped"] != true {
				b.Columns = append(b.Columns, tableedit.ObservedColumn{Name: c["attname"].(string)})
			}
		}
		tableedit.Summarize(&b)
		b.Fingerprint = tableedit.Fingerprint(r)
		edit := *x.Index
		if edit.Action == "add" {
			var exists bool
			if s.conn.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname=$2)`, d.Target.Schema, edit.Name).Scan(&exists) != nil || exists {
				return p, errors.New("The selected index name must be absent. An existing INVALID index requires a separate reviewed drop, never automatic replacement.")
			}
			if edit.Definition == nil {
				terms := []tableedit.IndexTerm{}
				for _, n := range edit.Columns {
					n := n
					terms = append(terms, tableedit.IndexTerm{Column: &n})
				}
				edit.Definition = &tableedit.IndexDefinition{Method: "btree", Terms: terms}
				edit.Columns = nil
			}
			e.Guards, err = s.prepareAuthoredIndexes(ctx, b, tableedit.Draft{AuthoringVersion: 3, Columns: []tableedit.Column{}, Indexes: []tableedit.IndexEdit{edit}})
			if err != nil {
				return p, err
			}
			sql, err := renderPGIndex(ctx, d.Target, edit)
			if err != nil {
				return p, err
			}
			sql = strings.Replace(sql, "INDEX ", "INDEX CONCURRENTLY ", 1)
			p.SQL = []string{sql}
		} else {
			var allowed bool
			if s.conn.QueryRow(ctx, `SELECT c.relkind='i' AND c.relpersistence='p' AND NOT EXISTS(SELECT 1 FROM pg_catalog.pg_constraint k WHERE k.conindid=c.oid) AND NOT EXISTS(SELECT 1 FROM pg_catalog.pg_inherits h WHERE h.inhrelid=c.oid OR h.inhparent=c.oid) AND NOT i.indisreplident AND NOT i.indisclustered FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace JOIN pg_catalog.pg_index i ON i.indexrelid=c.oid WHERE n.nspname=$1 AND c.relname=$2 AND i.indrelid=$3`, d.Target.Schema, edit.Name, r.OID).Scan(&allowed) != nil || !allowed {
				return p, errors.New("Concurrent DROP requires one non-constraint, non-inherited, non-replica-identity, non-clustered index on this table. INVALID indexes are eligible only through this explicit reviewed drop.")
			}
			p.SQL = []string{"DROP INDEX CONCURRENTLY " + pgx.Identifier{d.Target.Schema, edit.Name}.Sanitize() + ";"}
		}
		e.Ordinary = &b
		e.Transactional = false
		p.TransactionMode = "outsideTransaction"
		p.Locking = "PostgreSQL concurrent index locks and snapshot waits; session lock_timeout=5s. No encompassing user transaction."
		p.Risks = append(p.Risks, "Concurrent CREATE can fail or be cancelled after creating an INVALID index, which may still impose write/uniqueness overhead. Concurrent DROP can leave intermediate index states. Reconcile validity/readiness/liveness explicitly; no automatic drop or replay occurs.")
	case "createPartition", "attachPartition", "detachPartition", "finalizePartition", "dropPartition", "truncatePartition":
		if r.Class["relkind"] != "p" || r.Method == "" || x.Child == nil {
			return p, errors.New("Select an owned declaratively partitioned parent and an explicit child table.")
		}
		child := *x.Child
		if child == d.Target {
			return p, tableedit.ErrInvalid
		}
		var cr *pgPhysicalRelation
		for i := range e.Relations {
			if e.Relations[i].Target == child {
				cr = &e.Relations[i]
			}
		}
		if cr == nil {
			return p, tableedit.ErrInvalid
		}
		attached, pending := false, false
		for _, c := range r.Children {
			if c.Target != nil && *c.Target == child {
				attached = true
				pending = c.DetachPending
			}
		}
		if x.Kind == "createPartition" || x.Kind == "attachPartition" {
			if len(r.Children) >= 128 {
				return p, errors.New("The resulting direct partition count exceeds the bounded catalog proof limit of 128.")
			}
			bound, err := pgPhysicalBound(*x.Bound, r.Method, r.KeyCount)
			if err != nil {
				return p, err
			}
			if attached || pending {
				return p, errors.New("The child is already attached or pending detach.")
			}
			if x.Kind == "createPartition" {
				if cr.OID != 0 {
					return p, errors.New("The new partition name must be absent.")
				}
				p.SQL = []string{"CREATE TABLE " + pgPhysicalName(child) + " PARTITION OF " + target + " " + bound + ";"}
				p.Risks = append(p.Risks, "CREATE PARTITION copies parent columns, defaults, constraints, indexes and applicable triggers using native PostgreSQL semantics. Existing sibling/default partitions may be scanned and locked.")
			} else {
				if cr.OID == 0 || cr.Class["relkind"] != "r" || len(cr.Inherits) > 0 {
					return p, errors.New("ATTACH requires an existing unattached ordinary leaf table; nested/inherited candidates need a separately authored migration.")
				}
				p.SQL = []string{"ALTER TABLE " + target + " ATTACH PARTITION " + pgPhysicalName(child) + " " + bound + ";"}
				p.Risks = append(p.Risks, "ATTACH validates column/constraint compatibility and partition bounds during Apply, may scan the candidate and default partition, and may create/attach backing indexes or cloned triggers. Preview cannot prove data acceptance.")
			}
		} else {
			if !attached {
				return p, errors.New("The selected child is not a direct partition of this parent.")
			}
			if pending && x.Kind != "finalizePartition" {
				return p, errors.New("This partition has a pending concurrent detach. Reconcile and review FINALIZE explicitly.")
			}
			switch x.Kind {
			case "detachPartition":
				p.Risks = append(p.Risks, "DETACH separates inherited indexes, removes parent-cloned triggers from the child and can acquire SHARE locks on referencing foreign-key tables. Concurrent detach adds a CHECK matching the old partition bound. The standalone child and its own retained properties remain; no external dependency is dropped implicitly.")
				p.SQL = []string{"ALTER TABLE " + target + " DETACH PARTITION " + pgPhysicalName(child) + ";"}
				if x.Concurrent {
					if r.DefaultOID != 0 {
						return p, errors.New("Concurrent detach is not supported when this parent has a default partition.")
					}
					p.SQL[0] = strings.TrimSuffix(p.SQL[0], ";") + " CONCURRENTLY;"
					e.Transactional = false
					p.TransactionMode = "outsideTransaction"
					p.Locking = "PostgreSQL concurrent detach uses two internal transactions and SHARE UPDATE EXCLUSIVE locks; no encompassing transaction. Session lock_timeout=5s."
					p.Risks = append(p.Risks, "Cancellation can leave inhdetachpending=true after the first internal transaction. Review a fresh FINALIZE operation explicitly; never replay DETACH.")
				}
			case "finalizePartition":
				if !pending {
					return p, errors.New("FINALIZE requires observed inhdetachpending=true on this exact parent/child pair.")
				}
				p.SQL = []string{"ALTER TABLE " + target + " DETACH PARTITION " + pgPhysicalName(child) + " FINALIZE;"}
			case "dropPartition":
				p.SQL = []string{"DROP TABLE " + pgPhysicalName(child) + " RESTRICT;"}
				p.Consequences = append(p.Consequences, tableedit.Consequence{Kind: "dataLoss", Object: child.Schema + "." + child.Table, Message: "DROP permanently removes this partition and all its rows. RESTRICT rejects external dependencies; no hidden CASCADE is generated."})
			case "truncatePartition":
				p.SQL = []string{"TRUNCATE TABLE ONLY " + pgPhysicalName(child) + " RESTRICT;"}
				p.Consequences = append(p.Consequences, tableedit.Consequence{Kind: "dataLoss", Object: child.Schema + "." + child.Table, Message: "TRUNCATE deletes every row in this partition, fires TRUNCATE triggers, and does not restart sequences. External foreign keys may reject it; no CASCADE is generated."})
			}
		}
	default:
		return p, errors.New("This operation is MySQL-specific. PostgreSQL manages RANGE/LIST/HASH partitions through explicit create, attach, detach, finalize, drop and truncate operations.")
	}
	if x.Kind == "detachPartition" && x.Concurrent || x.Kind == "finalizePartition" {
		if r.Class["relispartition"] == true {
			return p, errors.New("Concurrent detach/finalize bound-CHECK proof currently requires a root partitioned parent. A subpartitioned parent can use ordinary reviewed detach without deparsing ancestor expressions.")
		}
		var safe bool
		if s.conn.QueryRow(ctx, `SELECT NOT EXISTS(SELECT 1 FROM pg_catalog.pg_partitioned_table p CROSS JOIN LATERAL pg_catalog.unnest(p.partattrs) k(num) LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid=p.partrelid AND a.attnum=k.num JOIN pg_catalog.pg_type t ON t.oid=a.atttypid WHERE p.partrelid=$1 AND (k.num=0 OR t.oid>=16384)) AND NOT EXISTS(SELECT 1 FROM pg_catalog.pg_partitioned_table p CROSS JOIN LATERAL pg_catalog.unnest(p.partattrs) k(num) WHERE p.partrelid=$1 AND k.num=0)`, r.OID).Scan(&safe) != nil || !safe {
			return p, errors.New("Concurrent detach/finalize bound-CHECK proof requires direct partition-key columns with built-in types. Expression or custom-type keys remain eligible for ordinary reviewed detach.")
		}
		var childOID uint32
		for _, rel := range e.Relations {
			if x.Child != nil && rel.Target == *x.Child {
				childOID = rel.OID
			}
		}
		if childOID == 0 || s.conn.QueryRow(ctx, `SELECT pg_catalog.pg_get_partition_constraintdef($1::pg_catalog.oid)`, childOID).Scan(&e.DetachCheck) != nil || e.DetachCheck == "" {
			return p, errors.New("The exact parent-to-child partition-bound CHECK could not be captured without evaluating expressions.")
		}
		p.Consequences = append(p.Consequences, tableedit.Consequence{Kind: "partitionBoundCheck", Object: x.Child.Schema + "." + x.Child.Table, Message: "Concurrent detach/finalize retains or adds this exact server-derived partition-bound CHECK on the standalone child: " + e.DetachCheck})
	}
	e.SQL = append([]string(nil), p.SQL...)
	p.Evidence = e
	p.EvidenceDigest = tableedit.Fingerprint(e)
	return p, nil
}
func pgPhysicalSame(a, b pgPhysicalEvidence) bool {
	return a.Version == b.Version && a.Environment == b.Environment && a.RIProof == b.RIProof && reflect.DeepEqual(a.RIFunctions, b.RIFunctions) && tableedit.Fingerprint(a.Relations) == tableedit.Fingerprint(b.Relations)
}
func (s *Session) PhysicalExecute(ctx context.Context, p tableedit.PhysicalPlan, progress func(int, string)) []tableedit.Execution {
	e, ok := p.Evidence.(pgPhysicalEvidence)
	fail := func(state, message string) []tableedit.Execution {
		return []tableedit.Execution{{State: state, Message: message}}
	}
	if !ok || len(p.SQL) != 1 || !reflect.DeepEqual(p.SQL, e.SQL) || tableedit.Fingerprint(e) != p.EvidenceDigest || s.TransactionStatus() != "idle" || ctx.Err() != nil {
		return fail("notStarted", "Invalid retained physical plan or non-idle session; no DDL was sent.")
	}
	progress(0, "metadataRecheck")
	if !e.Transactional {
		if _, err := s.conn.Exec(ctx, "SET lock_timeout = '5s'"); err != nil {
			return fail("notStarted", "Cannot set the reviewed lock timeout.")
		}
		defer func() {
			cleanup, c := context.WithTimeout(context.Background(), 3*time.Second)
			defer c()
			if _, err := s.conn.Exec(cleanup, "RESET lock_timeout"); err != nil {
				closeConnection(s.conn)
			}
		}()
		fresh, err := s.pgPhysicalInspect(ctx, p.Draft)
		if err != nil || !pgPhysicalSame(e, fresh) || !verifyIndexGuards(ctx, s.conn, e.Guards) {
			return fail("notStarted", tableedit.ErrStale.Error())
		}
		if ctx.Err() != nil {
			return fail("notStarted", "Cancelled before DDL dispatch.")
		}
		progress(0, "running")
		_, err = s.conn.Exec(ctx, p.SQL[0])
		if err != nil {
			var server *pgconn.PgError
			if errors.As(err, &server) {
				return fail("failed", "PostgreSQL rejected or cancelled the operation. Concurrent operations can leave INVALID indexes or pending detach state; reconcile explicitly without replay.")
			}
			return fail("unknown", "Server acknowledgement was lost after dispatch. Completion and intermediate catalog state are unknown; never replay automatically.")
		}
		progress(0, "acknowledged")
		message := ""
		if !s.pgPhysicalVerification(ctx, p, e) {
			message = "The concurrent operation was acknowledged, but its requested effect and preservation comparison could not be verified. Reconcile explicitly before another edit."
		}
		return fail("applied", message)
	}
	tx, err := s.conn.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return fail("notStarted", "Cannot begin the reviewed transaction.")
	}
	defer structureRollback(tx)
	if _, err = tx.Exec(ctx, "SET LOCAL lock_timeout='5s'"); err != nil {
		return fail("notStarted", "Cannot set lock timeout.")
	}
	relations := append([]pgPhysicalRelation(nil), e.Relations...)
	sort.Slice(relations, func(i, j int) bool { return pgPhysicalName(relations[i].Target) < pgPhysicalName(relations[j].Target) })
	for _, r := range relations {
		if r.OID == 0 {
			continue
		}
		if _, err = tx.Exec(ctx, "LOCK TABLE ONLY "+pgPhysicalName(r.Target)+" IN ACCESS EXCLUSIVE MODE"); err != nil {
			return fail("notStarted", "A reviewed table lock could not be acquired. No DDL was sent.")
		}
	}
	if e.Version < 150000 {
		ids, proof, err := pgPhysicalReadRI(ctx, tx)
		if err != nil || proof != e.RIProof || !reflect.DeepEqual(ids, e.RIFunctions) {
			return fail("notStarted", tableedit.ErrStale.Error())
		}
	}
	for _, r := range e.Relations {
		fresh, err := pgPhysicalRead(ctx, tx, r.Target)
		if err != nil || tableedit.Fingerprint(r) != tableedit.Fingerprint(fresh) {
			return fail("notStarted", tableedit.ErrStale.Error())
		}
	}
	if ctx.Err() != nil {
		return fail("notStarted", "Cancelled before DDL dispatch.")
	}
	progress(0, "running")
	if _, err = tx.Exec(ctx, p.SQL[0]); err != nil {
		var server *pgconn.PgError
		if errors.As(err, &server) {
			return fail("failed", "PostgreSQL rejected the operation; no COMMIT was sent.")
		}
		return fail("unknown", "Operation completion could not be confirmed. No automatic replay is permitted.")
	}
	commit := func() error { return tx.Commit(ctx) }
	if s.structureCommitOverride != nil {
		err = s.structureCommitOverride(commit)
	} else {
		err = commit()
	}
	if err != nil {
		return fail("unknown", "COMMIT acknowledgement was lost; the operation may be applied.")
	}
	progress(0, "acknowledged")
	message := ""
	if !s.pgPhysicalVerification(ctx, p, e) {
		message = "The operation was acknowledged, but its requested effect and preservation comparison could not be verified. Reconcile explicitly before another edit."
	}
	return fail("applied", message)
}
func (s *Session) PhysicalObserve(ctx context.Context, p tableedit.PhysicalPlan) ([]tableedit.PhysicalObject, error) {
	// Observe all reviewed names, including dropped/detached children, independently of eligibility to repeat the operation.
	e, ok := p.Evidence.(pgPhysicalEvidence)
	if !ok {
		return nil, tableedit.ErrInvalid
	}
	if s.TransactionStatus() != "idle" {
		return nil, tableedit.ErrUnsupported
	}
	out := []tableedit.PhysicalObject{}
	for _, r := range e.Relations {
		fresh, err := pgPhysicalRead(ctx, s.conn, r.Target)
		if err != nil {
			return nil, err
		}
		out = append(out, fresh.object())
	}
	return out, nil
}

func (s *Session) PhysicalInspect(ctx context.Context, t tableedit.Target) (tableedit.PhysicalInspection, error) {
	d := tableedit.PhysicalDraft{Version: 1, Target: t, Intent: tableedit.PhysicalIntent{Kind: "concurrentIndex", Index: &tableedit.IndexEdit{Action: "add", Name: "inspection_only", Columns: []string{"inspection_only"}}}}
	e, err := s.pgPhysicalInspect(ctx, d)
	if err != nil {
		return tableedit.PhysicalInspection{}, err
	}
	out := tableedit.PhysicalInspection{Version: 1, Engine: "postgresql", ServerVersion: e.Version, Objects: []tableedit.PhysicalObject{}, Operations: []string{}}
	for _, r := range e.Relations {
		out.Objects = append(out.Objects, r.object())
	}
	if e.Relations[0].Class["relkind"] == "p" {
		out.Operations = []string{"createPartition", "attachPartition", "detachPartition", "finalizePartition", "dropPartition", "truncatePartition"}
	} else {
		out.Operations = []string{"concurrentIndex"}
	}
	return out, nil
}

// Acknowledgement and catalog preservation are separate evidence. Expected
// native inheritance changes never make unrelated columns or sibling objects mutable.
func pgPhysicalExpected(before, after pgPhysicalEvidence, x tableedit.PhysicalIntent) bool {
	if before.Version != after.Version || before.Environment != after.Environment || len(before.Relations) == 0 || len(after.Relations) == 0 {
		return false
	}
	if x.Kind == "concurrentIndex" {
		return true
	} // Verified through the existing typed index transition below.
	byTarget := map[tableedit.Target]pgPhysicalRelation{}
	for _, r := range after.Relations {
		byTarget[r.Target] = r
	}
	parent := before.Relations[0].Target
	for _, old := range before.Relations {
		next, found := byTarget[old.Target]
		if !found {
			return false
		}
		isChild := x.Child != nil && old.Target == *x.Child
		if isChild && x.Kind == "dropPartition" {
			if next.OID != 0 {
				return false
			}
			continue
		}
		if old.OID == 0 {
			if !isChild || x.Kind != "createPartition" || next.OID == 0 {
				return false
			}
			continue
		}
		if old.OID != next.OID {
			return false
		}
		if old.Target != parent && !isChild {
			if tableedit.Fingerprint(old) != tableedit.Fingerprint(next) {
				return false
			}
			continue
		}
		clone := func(v any) map[string]any {
			raw, _ := json.Marshal(v)
			var m map[string]any
			_ = json.Unmarshal(raw, &m)
			return m
		}
		a, b := clone(old.Class), clone(next.Class)
		if old.Target == parent {
			delete(a, "relhassubclass")
			delete(b, "relhassubclass")
		}
		if isChild && (x.Kind == "attachPartition" || x.Kind == "detachPartition" || x.Kind == "finalizePartition") {
			delete(a, "relhastriggers")
			delete(b, "relhastriggers")
			if before.DetachCheck != "" {
				a["relchecks"] = b["relchecks"]
			}
			for _, k := range []string{"relispartition", "relpartbound"} {
				delete(a, k)
				delete(b, k)
			}
		}
		if isChild && x.Kind == "truncatePartition" {
			delete(a, "relfilenode")
			delete(b, "relfilenode")
		}
		if !reflect.DeepEqual(old.Comments, next.Comments) || !reflect.DeepEqual(old.ExtendedStatistics, next.ExtendedStatistics) || !reflect.DeepEqual(old.Policies, next.Policies) {
			return false
		}
		if !reflect.DeepEqual(a, b) || !reflect.DeepEqual(old.Defaults, next.Defaults) || len(old.Columns) != len(next.Columns) {
			return false
		}
		for i := range old.Columns {
			a, b = clone(old.Columns[i]), clone(next.Columns[i])
			if isChild && (x.Kind == "attachPartition" || x.Kind == "detachPartition" || x.Kind == "finalizePartition") {
				for _, k := range []string{"attinhcount", "attislocal"} {
					delete(a, k)
					delete(b, k)
				}
			}
			if !reflect.DeepEqual(a, b) {
				return false
			}
		}
		if isChild && old.OID != 0 {
			if !pgPhysicalMembersPreserved(old, next, x.Kind) {
				return false
			}
		}
		if old.Target == parent {
			if !reflect.DeepEqual(old.Constraints, next.Constraints) || !pgPhysicalParentIndexesPreserved(old, next, x.Kind) || !reflect.DeepEqual(old.Triggers, next.Triggers) || old.Method != next.Method || old.KeyCount != next.KeyCount {
				return false
			}
		}
	}
	r := after.Relations[0]
	attached, pending := false, false
	for _, p := range r.Children {
		if p.Target != nil && x.Child != nil && *p.Target == *x.Child {
			attached = true
			pending = p.DetachPending
		}
	}
	switch x.Kind {
	case "createPartition", "attachPartition":
		return attached && !pending
	case "detachPartition", "finalizePartition", "dropPartition":
		return !attached
	case "truncatePartition":
		return attached && !pending
	}
	return false
}
func (s *Session) pgPhysicalVerification(ctx context.Context, p tableedit.PhysicalPlan, e pgPhysicalEvidence) bool {
	fresh, err := s.pgPhysicalInspect(ctx, p.Draft)
	if err != nil || e.RIProof != fresh.RIProof || !reflect.DeepEqual(e.RIFunctions, fresh.RIFunctions) {
		return false
	}
	if p.Draft.Intent.Kind != "concurrentIndex" {
		return pgPhysicalCloneChanges(e, fresh, p.Draft.Intent.Kind) && s.pgPhysicalNewConstraints(ctx, e, fresh, p.Draft.Intent) && pgPhysicalExpected(e, fresh, p.Draft.Intent)
	}
	if e.Ordinary == nil || !verifyIndexGuards(ctx, s.conn, e.Guards) {
		return false
	}
	old := *e.Ordinary
	next := old
	next.Facts, err = readStructureFacts(ctx, s.conn, p.Draft.Target, fresh.Relations[0].OID)
	if err != nil {
		return false
	}
	tableedit.Summarize(&next)
	condition := tableedit.Condition{Operation: tableedit.Operation{Kind: map[string]string{"add": "addIndex", "drop": "dropIndex"}[p.Draft.Intent.Index.Action], Index: p.Draft.Intent.Index}}
	return tableedit.VerifyTransition(old, next, condition, func(c sc.Column, w tableedit.Default) bool { return structureDefaultMatchesFacts(c, w, next.Facts) })
}

func pgPhysicalMembersPreserved(old, next pgPhysicalRelation, kind string) bool {
	if kind == "detachPartition" || kind == "finalizePartition" {
		for _, raw := range next.Indexes {
			_, _, parents, ok := pgPhysicalIndexParts(raw)
			if !ok || len(parents) > 0 {
				return false
			}
		}
	}
	inheritance := kind == "attachPartition" || kind == "detachPartition" || kind == "finalizePartition"
	compare := func(a, b []json.RawMessage, category string) bool {
		rows := map[string]map[string]any{}
		decode := func(raw json.RawMessage) (string, map[string]any) {
			var m map[string]any
			if json.Unmarshal(raw, &m) != nil {
				return "", nil
			}
			name := ""
			switch category {
			case "constraint":
				name, _ = m["conname"].(string)
				if inheritance {
					for _, k := range []string{"conparentid", "coninhcount", "conislocal"} {
						delete(m, k)
					}
				}
			case "index":
				c, _ := m["class"].(map[string]any)
				name, _ = c["relname"].(string)
				if inheritance {
					delete(m, "parents")
					delete(c, "relispartition")
					delete(c, "relpartbound")
				}
				if kind == "truncatePartition" {
					delete(c, "relfilenode")
				}
			case "trigger":
				name, _ = m["tgname"].(string)
			}
			return name, m
		}
		for _, raw := range b {
			name, m := decode(raw)
			if name == "" {
				return false
			}
			rows[name] = m
		}
		oldNames := map[string]bool{}
		for _, raw := range a {
			name, _ := decode(raw)
			oldNames[name] = true
		}
		if category != "constraint" && kind != "attachPartition" && kind != "createPartition" {
			for name := range rows {
				if !oldNames[name] {
					return false
				}
			}
		}
		for _, raw := range a {
			name, m := decode(raw)
			if category == "trigger" && (kind == "detachPartition" || kind == "finalizePartition") && fmt.Sprint(m["tgparentid"]) != "0" {
				continue
			}
			if !reflect.DeepEqual(m, rows[name]) {
				return false
			}
		}
		return true
	}
	return compare(old.Constraints, next.Constraints, "constraint") && compare(old.Indexes, next.Indexes, "index") && compare(old.Triggers, next.Triggers, "trigger")
}

func (s *Session) pgPhysicalNewConstraints(ctx context.Context, before, after pgPhysicalEvidence, x tableedit.PhysicalIntent) bool {
	if x.Child == nil || x.Kind == "createPartition" || x.Kind == "attachPartition" || x.Kind == "dropPartition" {
		return true
	}
	var old, next *pgPhysicalRelation
	for i := range before.Relations {
		if before.Relations[i].Target == *x.Child {
			old = &before.Relations[i]
		}
	}
	for i := range after.Relations {
		if after.Relations[i].Target == *x.Child {
			next = &after.Relations[i]
		}
	}
	if old == nil || next == nil {
		return false
	}
	oldIDs := map[string]bool{}
	for _, raw := range old.Constraints {
		var c map[string]any
		if json.Unmarshal(raw, &c) != nil {
			return false
		}
		oldIDs[fmt.Sprint(c["oid"])] = true
	}
	parentIDs := map[string]map[string]any{}
	for _, raw := range before.Relations[0].Constraints {
		var c map[string]any
		if json.Unmarshal(raw, &c) != nil {
			return false
		}
		parentIDs[fmt.Sprint(c["oid"])] = c
	}
	checks := 0
	for _, raw := range next.Constraints {
		var c map[string]any
		if json.Unmarshal(raw, &c) != nil {
			return false
		}
		if oldIDs[fmt.Sprint(c["oid"])] {
			continue
		}
		if x.Kind == "attachPartition" {
			parent, ok := parentIDs[fmt.Sprint(c["conparentid"])]
			if !ok || c["contype"] != parent["contype"] {
				return false
			}
			continue
		}
		if before.DetachCheck == "" || c["contype"] != "c" || c["convalidated"] != true || fmt.Sprint(c["conrelid"]) != strconv.FormatUint(uint64(next.OID), 10) {
			return false
		}
		node, ok := c["conbin"].(string)
		if !ok {
			return false
		}
		for _, match := range regexp.MustCompile(`:consttype ([0-9]+)`).FindAllStringSubmatch(node, -1) {
			oid, e := strconv.ParseUint(match[1], 10, 32)
			if e != nil || oid >= 16384 {
				return false
			}
		}
		var expression string
		if s.conn.QueryRow(ctx, `SELECT pg_catalog.pg_get_expr(conbin,conrelid) FROM pg_catalog.pg_constraint WHERE oid=$1::pg_catalog.oid AND conrelid=$2`, fmt.Sprint(c["oid"]), next.OID).Scan(&expression) != nil || expression != before.DetachCheck {
			return false
		}
		checks++
	}
	return checks <= 1
}
