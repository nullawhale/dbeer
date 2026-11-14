package postgres

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"sort"
	"strconv"
)

func readStructureFacts(ctx context.Context, q structureReader, t tableedit.Target, oid uint32, advanced ...bool) (*tableedit.Facts, error) {
	q = pgCatalogReader(q)
	limits := sc.Limits{Nodes: 256, Members: 2048, Bytes: 2 << 20, Scalar: 65536}
	sink := sc.NewCollector(ctx, limits)
	var version int
	if q.QueryRow(ctx, "SELECT pg_catalog.current_setting('server_version_num')::pg_catalog.int4").Scan(&version) != nil {
		return nil, tableedit.ErrUnsupported
	}
	r := &schemaCapture{ctx: ctx, tx: q, sink: sink, spec: sc.CaptureSpec{Schemas: []string{t.Schema}, Limits: limits}, version: version, types: map[string]sc.TypeUse{}, loading: map[string]bool{}, sequences: map[string]bool{}, skipCustomTypeFormatting: true}
	// PostgreSQL18 can consult extension AMs while planning a metadata sort.
	// Filter and order this bounded core-function result locally.
	keywords, keywordErr := r.rows(`SELECT word,catcode FROM pg_catalog.pg_get_keywords()`)
	if keywordErr != nil {
		return nil, tableedit.ErrUnsupported
	}
	ref := sc.Ref{Kind: "table", Schema: t.Schema, Name: t.Table}
	id := strconv.FormatUint(uint64(oid), 10)
	columns, e := r.columns(ref, id)
	if e != nil {
		return nil, tableedit.ErrUnsupported
	}
	keys, e := r.constraints(ref, "conrelid", id)
	if e != nil {
		return nil, tableedit.ErrUnsupported
	}
	indexes, e := r.indexes(ref, id)
	if e != nil {
		return nil, tableedit.ErrUnsupported
	}
	var defaultOID string
	if q.QueryRow(ctx, "SELECT oid::pg_catalog.text FROM pg_catalog.pg_collation WHERE collname='default' AND collnamespace='pg_catalog'::pg_catalog.regnamespace").Scan(&defaultOID) != nil {
		return nil, tableedit.ErrUnsupported
	}
	defaultProperties, e := r.typeCollation(defaultOID)
	if e != nil {
		return nil, tableedit.ErrUnsupported
	}
	storage, e := structureTypeStorage(ctx, q)
	if e != nil {
		return nil, e
	}
	sequences, e := readStructureSequences(ctx, q, t, oid)
	if e != nil {
		return nil, e
	}
	for i := range columns {
		for _, seq := range sequences {
			if seq.Owner.Value != nil && *seq.Owner.Value == columns[i].Ref && columns[i].Identity.Value != nil && columns[i].Identity.Value.Kind != "none" {
				columns[i].Identity.Value.Sequence = &seq.Ref
			}
		}
	}
	f := &tableedit.Facts{ServerVersion: version, Sequences: sequences, TypeStorage: storage, DefaultCollationProperties: defaultProperties, Table: sc.Table{Ref: ref, Kind: sc.Known("r"), Storage: sc.Known("p"), Columns: sc.Complete(columns), Constraints: sc.Complete(keys), Indexes: sc.Complete(indexes)}, Types: sink.Capture.Types, Proof: true, Dependents: map[string][]string{}}
	defaults, err := r.rows(`SELECT c.relname,o.opcdefault::pg_catalog.text FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class c ON c.oid=i.indexrelid CROSS JOIN LATERAL pg_catalog.unnest(i.indclass) WITH ORDINALITY k(opclass,ord) JOIN pg_catalog.pg_opclass o ON o.oid=k.opclass WHERE i.indrelid=$1::pg_catalog.oid ORDER BY c.relname COLLATE pg_catalog."C",k.ord`, id)
	if err != nil {
		return nil, tableedit.ErrUnsupported
	}
	for _, entry := range defaults {
		if f.IndexDefaultOpclasses == nil {
			f.IndexDefaultOpclasses = map[string][]bool{}
		}
		f.IndexDefaultOpclasses[entry[0]] = append(f.IndexDefaultOpclasses[entry[0]], pgBool(entry[1]))
	}
	f.IndexCatalogGuards, e = captureIndexGuards(ctx, q, id)
	if e != nil {
		return nil, tableedit.ErrUnsupported
	}
	f.IndexAttributes = r.indexAttributes
	f.IndexDefaultCollations = r.indexDefaultCollations
	f.IndexBuiltinFunctions = r.indexBuiltinFunctions
	f.RawExpressions = r.rawExpressions
	f.ExpressionKeywords = []string{}
	for _, keyword := range keywords {
		if len(keyword) != 2 {
			return nil, tableedit.ErrUnsupported
		}
		if keyword[1] != "U" {
			f.ExpressionKeywords = append(f.ExpressionKeywords, keyword[0])
		}
	}
	sort.Strings(f.ExpressionKeywords)
	incoming, e := q.Query(ctx, `SELECT n.nspname,c.relname,k.conname,COALESCE((SELECT pg_catalog.json_agg(a.attname ORDER BY x.ord)::pg_catalog.text FROM pg_catalog.unnest(k.confkey) WITH ORDINALITY x(num,ord) JOIN pg_catalog.pg_attribute a ON a.attrelid=k.confrelid AND a.attnum=x.num),'[]') FROM pg_catalog.pg_constraint k JOIN pg_catalog.pg_class c ON c.oid=k.conrelid JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE k.confrelid=$1 AND k.contype='f' ORDER BY n.nspname,c.relname,k.conname LIMIT 257`, oid)
	if e != nil {
		return nil, tableedit.ErrUnsupported
	}
	for incoming.Next() {
		var x tableedit.Incoming
		var names string
		if incoming.Scan(&x.Schema, &x.Table, &x.Name, &names) != nil {
			return nil, tableedit.ErrUnsupported
		}
		if json.Unmarshal([]byte(names), &x.Columns) != nil {
			return nil, tableedit.ErrUnsupported
		}
		f.Incoming = append(f.Incoming, x)
	}
	e = incoming.Err()
	incoming.Close()
	if e != nil || len(f.Incoming) > 256 {
		return nil, tableedit.ErrUnsupported
	}
	rows, e := q.Query(ctx, `SELECT COALESCE(a.attname,''),pg_catalog.pg_describe_object(d.classid,d.objid,d.objsubid) FROM pg_catalog.pg_depend d LEFT JOIN pg_catalog.pg_attribute a ON pg_catalog.oideq(a.attrelid,d.refobjid) AND pg_catalog.int4eq(a.attnum::pg_catalog.int4,d.refobjsubid) WHERE d.refclassid OPERATOR(pg_catalog.=) ANY(ARRAY['pg_catalog.pg_class'::pg_catalog.regclass::pg_catalog.oid]) AND d.refobjid OPERATOR(pg_catalog.=) ANY(ARRAY[$1::pg_catalog.oid]) AND pg_catalog.charne(d.deptype,'i') AND NOT ($2::pg_catalog.bool AND ((d.classid='pg_catalog.pg_policy'::pg_catalog.regclass AND d.objid IN (SELECT oid FROM pg_catalog.pg_policy WHERE polrelid=$1)) OR (d.classid='pg_catalog.pg_class'::pg_catalog.regclass AND d.objid IN (SELECT inhrelid FROM pg_catalog.pg_inherits WHERE inhparent=$1)))) AND NOT (d.classid='pg_catalog.pg_class'::pg_catalog.regclass AND d.objid IN (SELECT indexrelid FROM pg_catalog.pg_index WHERE indrelid=$1)) AND NOT (d.classid='pg_catalog.pg_constraint'::pg_catalog.regclass AND d.objid IN (SELECT oid FROM pg_catalog.pg_constraint WHERE conrelid=$1 OR confrelid=$1)) AND NOT (d.classid='pg_catalog.pg_attrdef'::pg_catalog.regclass AND d.objid IN (SELECT oid FROM pg_catalog.pg_attrdef WHERE adrelid=$1)) LIMIT 2049`, oid, len(advanced) > 0 && advanced[0])
	if e != nil {
		return nil, tableedit.ErrUnsupported
	}
	count := 0
	for rows.Next() {
		var name, label string
		if rows.Scan(&name, &label) != nil {
			return nil, tableedit.ErrUnsupported
		}
		f.Dependents[name] = append(f.Dependents[name], label)
		count++
	}
	e = rows.Err()
	rows.Close()
	if e != nil || count > 2048 {
		return nil, tableedit.ErrUnsupported
	}
	for _, labels := range f.Dependents {
		sort.Strings(labels)
	}
	// A trigger may refer dynamically to fields, so any user trigger blocks widening.
	var triggers int
	if q.QueryRow(ctx, "SELECT count(*) FROM pg_catalog.pg_trigger WHERE tgrelid=$1 AND NOT tgisinternal", oid).Scan(&triggers) != nil {
		return nil, tableedit.ErrUnsupported
	}
	if triggers > 0 {
		f.Dependents[""] = append(f.Dependents[""], "user triggers")
	}
	encoded, _ := json.Marshal(f)
	if len(encoded) > 2<<20 {
		return nil, tableedit.ErrUnsupported
	}
	return f, nil
}

func readStructureDefaults(ctx context.Context, q structureReader, t tableedit.Target) (*tableedit.Facts, error) {
	q = pgCatalogReader(q)
	limits := sc.Limits{Nodes: 32, Members: 128, Bytes: 65536, Scalar: 4096}
	r := &schemaCapture{ctx: ctx, tx: q, sink: sc.NewCollector(ctx, limits), spec: sc.CaptureSpec{Limits: limits}, types: map[string]sc.TypeUse{}, loading: map[string]bool{}, sequences: map[string]bool{}, skipCustomTypeFormatting: true}
	if q.QueryRow(ctx, "SELECT pg_catalog.current_setting('server_version_num')::pg_catalog.int4").Scan(&r.version) != nil {
		return nil, tableedit.ErrUnsupported
	}
	var oid string
	if q.QueryRow(ctx, "SELECT oid::pg_catalog.text FROM pg_catalog.pg_collation WHERE collname='default' AND collnamespace='pg_catalog'::pg_catalog.regnamespace").Scan(&oid) != nil {
		return nil, tableedit.ErrUnsupported
	}
	properties, e := r.typeCollation(oid)
	if e != nil {
		return nil, tableedit.ErrUnsupported
	}
	storage, e := structureTypeStorage(ctx, q)
	if e != nil {
		return nil, e
	}
	return &tableedit.Facts{ServerVersion: r.version, TypeStorage: storage, Proof: true, DefaultCollationProperties: properties, Table: sc.Table{Ref: sc.Ref{Kind: "table", Schema: t.Schema, Name: t.Table}, Columns: sc.Complete[sc.Column](nil), Constraints: sc.Complete[sc.Constraint](nil), Indexes: sc.Complete[sc.Index](nil)}, Dependents: map[string][]string{}}, nil
}

func structureTypeStorage(ctx context.Context, q structureReader) (map[string]string, error) {
	rows, e := q.Query(ctx, "SELECT typname,typstorage::pg_catalog.text FROM pg_catalog.pg_type WHERE typnamespace='pg_catalog'::pg_catalog.regnamespace AND typname IN ('int4','int8','bool','numeric','varchar','text')")
	if e != nil {
		return nil, tableedit.ErrUnsupported
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var name, storage string
		if rows.Scan(&name, &storage) != nil {
			return nil, tableedit.ErrUnsupported
		}
		kind := map[string]string{"int4": "integer", "int8": "bigint", "bool": "boolean", "numeric": "numeric", "varchar": "varchar", "text": "text"}[name]
		out[kind] = storage
	}
	if rows.Err() != nil || len(out) != 6 {
		return nil, tableedit.ErrUnsupported
	}
	return out, nil
}
