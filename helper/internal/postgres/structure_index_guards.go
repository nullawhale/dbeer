package postgres

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"fmt"
	"reflect"
	"sort"
	"strconv"
	"strings"
)

func resolveIndexGuard(ctx context.Context, q structureReader, kind string, ref tableedit.TypeReference, method string) (tableedit.IndexGuard, error) {
	q = pgCatalogReader(q)
	g := tableedit.IndexGuard{Kind: kind, Reference: ref, Method: method}
	limits := sc.Limits{Nodes: 128, Members: 4096, Bytes: 2 << 20, Scalar: 65536}
	r := &schemaCapture{ctx: ctx, tx: q, sink: sc.NewCollector(ctx, limits), spec: sc.CaptureSpec{Limits: limits}, skipCustomTypeFormatting: true, types: map[string]sc.TypeUse{}, loading: map[string]bool{}, sequences: map[string]bool{}}
	if q.QueryRow(ctx, "SELECT pg_catalog.current_setting('server_version_num')::pg_catalog.int4").Scan(&r.version) != nil {
		return g, tableedit.ErrUnsupported
	}
	var definition any
	switch kind {
	case "accessMethod":
		var handler string
		if q.QueryRow(ctx, `SELECT oid::pg_catalog.text,amhandler::pg_catalog.oid::pg_catalog.text FROM pg_catalog.pg_am WHERE amname=$1 AND amtype='i'`, ref.Name).Scan(&g.Identity, &handler) != nil {
			return g, fmt.Errorf("The selected index access method is unavailable.")
		}
		function, err := r.typeFunction(handler, "accessMethod")
		if err != nil {
			return g, err
		}
		var defaults []any
		if !builtinCatalogIdentity(g.Identity) {
			classes, err := r.rows(`SELECT oid::pg_catalog.text FROM pg_catalog.pg_opclass WHERE pg_catalog.oideq(opcmethod,$1::pg_catalog.oid) AND opcdefault`, g.Identity)
			if err != nil || len(classes) > 64 {
				return g, tableedit.ErrUnsupported
			}
			sort.Slice(classes, func(i, j int) bool { return pgInt(classes[i][0]) < pgInt(classes[j][0]) })
			for _, class := range classes {
				value, err := r.typeOperatorClass(class[0])
				if err != nil {
					return g, err
				}
				defaults = append(defaults, []any{class[0], value})
			}
		}
		definition = []any{function, defaults}
	case "opclass":
		if q.QueryRow(ctx, `SELECT o.oid::pg_catalog.text FROM pg_catalog.pg_opclass o JOIN pg_catalog.pg_namespace n ON n.oid=o.opcnamespace JOIN pg_catalog.pg_am a ON a.oid=o.opcmethod WHERE n.nspname=$1 AND o.opcname=$2 AND a.amname=$3 AND pg_catalog.has_schema_privilege(n.oid,'USAGE')`, ref.Schema, ref.Name, method).Scan(&g.Identity) != nil {
			return g, fmt.Errorf("The selected qualified operator class is unavailable for this access method or lacks schema USAGE.")
		}
		value, err := r.typeOperatorClass(g.Identity)
		if err != nil {
			return g, err
		}
		definition = value
	case "collation":
		if q.QueryRow(ctx, `SELECT c.oid::pg_catalog.text FROM pg_catalog.pg_collation c JOIN pg_catalog.pg_namespace n ON n.oid=c.collnamespace WHERE n.nspname=$1 AND c.collname=$2 AND c.collencoding IN (-1,(SELECT encoding FROM pg_catalog.pg_database WHERE datname=pg_catalog.current_database())) AND pg_catalog.has_schema_privilege(n.oid,'USAGE') ORDER BY c.collencoding DESC LIMIT 1`, ref.Schema, ref.Name).Scan(&g.Identity) != nil {
			return g, fmt.Errorf("The selected qualified index collation is unavailable or lacks schema USAGE.")
		}
		value, err := r.typeCollation(g.Identity)
		if err != nil {
			return g, err
		}
		definition = value
	default:
		return g, tableedit.ErrInvalid
	}
	raw, err := json.Marshal([]any{definition, r.rawExpressions})
	if err != nil || len(raw) > 2<<20 {
		return g, tableedit.ErrUnsupported
	}
	g.Definition = string(raw)
	return g, nil
}
func verifyIndexGuards(ctx context.Context, q structureReader, guards []tableedit.IndexGuard) bool {
	for _, guard := range guards {
		actual, err := resolveIndexGuard(ctx, q, guard.Kind, guard.Reference, guard.Method)
		if err != nil || !reflect.DeepEqual(actual, guard) {
			return false
		}
	}
	return true
}
func builtinCatalogIdentity(raw string) bool {
	n, err := strconv.ParseUint(raw, 10, 32)
	return err == nil && n < 16384
}
func captureIndexGuards(ctx context.Context, q structureReader, oid string) (map[string][]tableedit.IndexGuard, error) {
	rows, err := q.Query(ctx, `SELECT c.relname,a.oid::pg_catalog.text,a.amname,o.oid::pg_catalog.text,onsp.nspname,o.opcname,COALESCE(co.oid::pg_catalog.text,''),COALESCE(cn.nspname,''),COALESCE(co.collname,'') FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class c ON c.oid=i.indexrelid JOIN pg_catalog.pg_am a ON a.oid=c.relam CROSS JOIN LATERAL pg_catalog.unnest(i.indclass) WITH ORDINALITY k(opclass,ord) JOIN pg_catalog.pg_opclass o ON o.oid=k.opclass JOIN pg_catalog.pg_namespace onsp ON onsp.oid=o.opcnamespace LEFT JOIN pg_catalog.pg_collation co ON co.oid=i.indcollation[k.ord::pg_catalog.int4-1] LEFT JOIN pg_catalog.pg_namespace cn ON cn.oid=co.collnamespace WHERE i.indrelid=$1::pg_catalog.oid`, oid)
	if err != nil {
		return nil, err
	}
	type entry struct{ name, amID, method, opID, opSchema, opName, collID, collSchema, collName string }
	var all []entry
	unique := map[entry]bool{}
	rawCount := 0
	for rows.Next() {
		var e entry
		if rows.Scan(&e.name, &e.amID, &e.method, &e.opID, &e.opSchema, &e.opName, &e.collID, &e.collSchema, &e.collName) != nil {
			rows.Close()
			return nil, tableedit.ErrUnsupported
		}
		rawCount++
		if !unique[e] {
			unique[e] = true
			all = append(all, e)
		}
		if len(all) > 1024 || rawCount > 16384 {
			rows.Close()
			return nil, tableedit.ErrUnsupported
		}
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, err
	}
	// SQL DISTINCT/text ordering can consult extension AMs during planning.
	// Keep the same bounded records without invoking their handler callbacks.
	key := func(e entry) string {
		return strings.Join([]string{e.name, e.amID, e.method, e.opID, e.opSchema, e.opName, e.collID, e.collSchema, e.collName}, "\x00")
	}
	sort.Slice(all, func(i, j int) bool { return key(all[i]) < key(all[j]) })
	var out map[string][]tableedit.IndexGuard
	seen := map[string]bool{}
	for _, e := range all {
		requested := []struct{ kind, id, schema, name, method string }{{"accessMethod", e.amID, "pg_catalog", e.method, ""}, {"opclass", e.opID, e.opSchema, e.opName, e.method}, {"collation", e.collID, e.collSchema, e.collName, ""}}
		for _, v := range requested {
			if v.id == "" || builtinCatalogIdentity(v.id) {
				continue
			}
			key := e.name + "\x00" + v.kind + "\x00" + v.id
			if seen[key] {
				continue
			}
			seen[key] = true
			g, err := resolveIndexGuard(ctx, q, v.kind, tableedit.TypeReference{Schema: v.schema, Name: v.name}, v.method)
			if err != nil {
				return nil, err
			}
			if out == nil {
				out = map[string][]tableedit.IndexGuard{}
			}
			out[e.name] = append(out[e.name], g)
		}
	}
	return out, nil
}
