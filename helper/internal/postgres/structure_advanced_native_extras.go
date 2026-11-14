package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"dbeer/helper/internal/tableedit"
)

// Capture-only enrichment: no authored-expression/custom-datum evaluation,
// user-row scan or DDL. Valid trusted server callbacks remain permitted.
// Keep these raw addresses in the fingerprint; a rewrite must map each proven
// replacement address and compare every retained property independently.
func pgAdvancedNativeExtras(ctx context.Context, q structureReader, b *tableedit.Baseline) error {
	q = pgCatalogReader(q)
	if b == nil || b.AdvancedEvidence == nil || len(b.AdvancedEvidence.Targets) == 0 {
		return tableedit.ErrUnsupported
	}
	e := tableedit.CloneAdvancedEvidence(b.AdvancedEvidence)
	ids := []uint32{}
	for key, rows := range e.Rows {
		if !strings.HasSuffix(key, "/class") {
			continue
		}
		id, err := strconv.ParseUint(strings.TrimSuffix(key, "/class"), 10, 32)
		if err != nil || id == 0 || len(rows) != 1 || fmt.Sprint(rows[0]["oid"]) != fmt.Sprint(id) {
			return tableedit.ErrUnsupported
		}
		ids = append(ids, uint32(id))
	}
	if len(ids) != len(e.Targets) || len(ids) > 64 {
		return tableedit.ErrUnsupported
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	bytes := 0
	for _, id := range ids {
		prefix := fmt.Sprint(id) + "/"
		// Index tuples have no native fast missing datum. Guard both the flag
		// and datum before row_to_json could invoke any element output routine.
		const indexes = `WITH indexes(oid) AS (SELECT i.indexrelid FROM pg_catalog.pg_index i WHERE i.indrelid=$1::pg_catalog.oid UNION SELECT i.indexrelid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_index i ON i.indrelid=c.reltoastrelid WHERE c.oid=$1::pg_catalog.oid) `
		var safe bool
		if q.QueryRow(ctx, indexes+`SELECT NOT EXISTS(SELECT 1 FROM pg_catalog.pg_attribute a JOIN indexes i ON i.oid=a.attrelid WHERE a.attnum>0 AND (a.atthasmissing OR a.attmissingval IS NOT NULL))`, id).Scan(&safe) != nil || !safe {
			return errors.New("A native index attribute has a missing datum; observation stopped before any datum output.")
		}
		attributes, err := pgAdvancedRows(ctx, q, indexes+`SELECT pg_catalog.row_to_json(a)::pg_catalog.text FROM pg_catalog.pg_attribute a JOIN indexes i ON i.oid=a.attrelid WHERE a.attnum>0 ORDER BY a.attrelid,a.attnum LIMIT 2049`, id)
		if err != nil || len(attributes) > 2048 {
			return errors.New("Complete native index-attribute proof exceeds its 2048-record bound.")
		}
		e.Rows[prefix+"indexAttributes"] = attributes
		// The automatic array type and TOAST relation/index objects have their
		// own dependency/comment/label addresses, beyond the user's table OID.
		const objects = `WITH objects(classid,objid) AS (SELECT 'pg_catalog.pg_type'::pg_catalog.regclass::pg_catalog.oid,t.typarray FROM pg_catalog.pg_class c JOIN pg_catalog.pg_type t ON t.oid=c.reltype WHERE c.oid=$1::pg_catalog.oid AND t.typarray<>0 UNION SELECT 'pg_catalog.pg_class'::pg_catalog.regclass::pg_catalog.oid,c.reltoastrelid FROM pg_catalog.pg_class c WHERE c.oid=$1::pg_catalog.oid AND c.reltoastrelid<>0 UNION SELECT 'pg_catalog.pg_class'::pg_catalog.regclass::pg_catalog.oid,i.indexrelid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_index i ON i.indrelid=c.reltoastrelid WHERE c.oid=$1::pg_catalog.oid) `
		queries := []struct{ category, sql string }{
			{"dependencies", objects + `SELECT (pg_catalog.to_jsonb(d)||pg_catalog.jsonb_build_object('classid',d.classid::pg_catalog.oid::pg_catalog.text,'objid',d.objid::pg_catalog.oid::pg_catalog.text,'refclassid',d.refclassid::pg_catalog.oid::pg_catalog.text,'refobjid',d.refobjid::pg_catalog.oid::pg_catalog.text))::pg_catalog.text FROM pg_catalog.pg_depend d WHERE EXISTS(SELECT 1 FROM objects o WHERE (d.classid=o.classid AND d.objid=o.objid) OR (d.refclassid=o.classid AND d.refobjid=o.objid)) ORDER BY d.classid,d.objid,d.objsubid,d.refclassid,d.refobjid,d.refobjsubid LIMIT 2049`},
			{"comments", objects + `SELECT pg_catalog.row_to_json(d)::pg_catalog.text FROM pg_catalog.pg_description d JOIN objects o ON o.classid=d.classoid AND o.objid=d.objoid ORDER BY d.classoid,d.objoid,d.objsubid LIMIT 2049`},
			{"labels", objects + `SELECT pg_catalog.row_to_json(d)::pg_catalog.text FROM pg_catalog.pg_seclabel d JOIN objects o ON o.classid=d.classoid AND o.objid=d.objoid ORDER BY d.classoid,d.objoid,d.objsubid,d.provider LIMIT 2049`},
		}
		for _, query := range queries {
			rows, err := pgAdvancedRows(ctx, q, query.sql, id)
			if err != nil || len(rows) > 2048 {
				return errors.New("Complete automatic-type/TOAST native metadata exceeds its bounded catalog envelope.")
			}
			merged, err := pgAdvancedNativeMerge(e.Rows[prefix+query.category], rows, 2048)
			if err != nil {
				return err
			}
			e.Rows[prefix+query.category] = merged
		}
		for _, category := range []string{"indexAttributes", "dependencies", "comments", "labels"} {
			raw, err := json.Marshal(e.Rows[prefix+category])
			if err != nil {
				return tableedit.ErrUnsupported
			}
			bytes += len(raw)
			if bytes > 4<<20 {
				return errors.New("Complete enriched native metadata exceeds its four MiB bound; no partial proof is retained.")
			}
		}
	}
	b.AdvancedEvidence = e
	return nil
}

func pgAdvancedNativeMerge(left, right []map[string]any, limit int) ([]map[string]any, error) {
	unique := map[string]map[string]any{}
	for _, rows := range [][]map[string]any{left, right} {
		for _, row := range rows {
			if row == nil {
				return nil, tableedit.ErrUnsupported
			}
			raw, err := json.Marshal(row)
			if err != nil {
				return nil, tableedit.ErrUnsupported
			}
			unique[string(raw)] = row
		}
	}
	if len(unique) > limit {
		return nil, errors.New("Complete native metadata exceeds its record bound; no partial merge is accepted.")
	}
	keys := make([]string, 0, len(unique))
	for key := range unique {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	out := make([]map[string]any, 0, len(keys))
	for _, key := range keys {
		out = append(out, unique[key])
	}
	return out, nil
}
