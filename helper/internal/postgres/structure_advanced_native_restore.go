package postgres

import (
	"errors"
	"fmt"
	"strconv"
	"strings"

	"dbeer/helper/internal/tableedit"
	"github.com/jackc/pgx/v5"
)

func pgAdvancedNativeStorageOptions(value any, namespace ...string) (string, error) {
	prefix := ""
	if len(namespace) > 1 || len(namespace) == 1 && namespace[0] != "toast." {
		return "", tableedit.ErrUnsupported
	}
	if len(namespace) == 1 {
		prefix = namespace[0]
	}
	if value == nil {
		return "", nil
	}
	items, ok := value.([]any)
	if !ok {
		return "", tableedit.ErrUnsupported
	}
	out := []string{}
	for _, item := range items {
		text, ok := item.(string)
		if !ok {
			return "", tableedit.ErrUnsupported
		}
		name, value, ok := strings.Cut(text, "=")
		if !ok || !tableedit.Identifier(name) || strings.ContainsAny(name, ".\x00") {
			return "", errors.New("A captured native index storage option has no exact option/value replay shape.")
		}
		out = append(out, prefix+pgx.Identifier{name}.Sanitize()+"="+postgresTextLiteral(value))
	}
	return strings.Join(out, ","), nil
}

// Return reviewed SQL only. The caller must positively establish pg_catalog as
// the fixed search_path and own the locked target/context before executing it.
// The fresh TOAST index name/OID cannot be predicted by a Preview renderer.
func pgAdvancedNativeToastIndexCommentSQL(target tableedit.Target, text string) (string, error) {
	if !target.Valid() || target.Create || strings.HasPrefix(target.Schema, "pg_") || target.Schema == "information_schema" || len(text) > tableedit.MaxSQLBytes {
		return "", tableedit.ErrUnsupported
	}
	format := "COMMENT ON INDEX %I.%I IS %L"
	table := pgx.Identifier{target.Schema, target.Table}.Sanitize()
	body := `DECLARE n pg_catalog.name; r pg_catalog.name; BEGIN SELECT ns.nspname,ic.relname INTO STRICT n,r FROM pg_catalog.pg_class c JOIN pg_catalog.pg_index ix ON ix.indrelid OPERATOR(pg_catalog.=) c.reltoastrelid JOIN pg_catalog.pg_class ic ON ic.oid OPERATOR(pg_catalog.=) ix.indexrelid JOIN pg_catalog.pg_namespace ns ON ns.oid OPERATOR(pg_catalog.=) ic.relnamespace WHERE c.oid OPERATOR(pg_catalog.=) ` + postgresTextLiteral(table) + `::pg_catalog.regclass AND ix.indisunique AND ix.indisvalid AND ix.indisready AND ix.indislive; EXECUTE pg_catalog.format(` + postgresTextLiteral(format) + `,n,r,` + postgresTextLiteral(text) + `); END;`
	return "DO LANGUAGE plpgsql " + postgresTextLiteral(body) + ";", nil
}

// Render retained user-index settings and native TOAST-index options/comments.
// No SQL is executed here. Keep every returned statement visible in Preview and
// run the independent complete native address/property proof before COMMIT.
func pgAdvancedNativeIndexRestoreSQL(b tableedit.Baseline, id string, target tableedit.Target) ([]string, error) {
	if b.AdvancedEvidence == nil || !target.Valid() || target.Create {
		return nil, tableedit.ErrUnsupported
	}
	e := b.AdvancedEvidence
	classes := e.Rows[id+"/class"]
	attributes, known := e.Rows[id+"/indexAttributes"]
	if len(classes) != 1 || fmt.Sprint(classes[0]["oid"]) != id || !known {
		return nil, errors.New("Complete captured native index attributes are required before rendering restoration SQL.")
	}
	for _, a := range attributes {
		if a["atthasmissing"] != false || a["attmissingval"] != nil || tableedit.SemanticPostgresAttributeOptions(a["attoptions"]) != nil {
			return nil, errors.New("A captured native index-column layout or option requires explicit native reconciliation; no unknown source property is discarded.")
		}
	}
	out := []string{}
	for _, row := range e.Rows[id+"/indexes"] {
		class, cok := row["class"].(map[string]any)
		index, iok := row["index"].(map[string]any)
		if !cok || !iok || !tableedit.Identifier(fmt.Sprint(class["relname"])) {
			return nil, tableedit.ErrUnsupported
		}
		indexID := fmt.Sprint(class["oid"])
		name := pgx.Identifier{target.Schema, fmt.Sprint(class["relname"])}.Sanitize()
		options, err := pgAdvancedNativeStorageOptions(class["reloptions"])
		if err != nil {
			return nil, err
		}
		if class["relkind"] != "i" && class["relkind"] != "I" {
			return nil, errors.New("A retained user index has no supported native relation kind.")
		}
		if options != "" {
			if class["relkind"] == "I" {
				// Partitioned-index options belong in native CREATE INDEX. Native
				// ALTER INDEX SET rejects this kind; assert the retained definition
				// before the caller's independent complete post-operation proof.
				values := []string{}
				for _, value := range class["reloptions"].([]any) {
					values = append(values, postgresTextLiteral(value.(string)))
				}
				body := `DECLARE options pg_catalog.text[]; BEGIN SELECT c.reloptions INTO STRICT options FROM pg_catalog.pg_class c JOIN pg_catalog.pg_index x ON x.indexrelid OPERATOR(pg_catalog.=) c.oid WHERE c.oid OPERATOR(pg_catalog.=) ` + postgresTextLiteral(name) + `::pg_catalog.regclass AND x.indrelid OPERATOR(pg_catalog.=) ` + postgresTextLiteral(pgx.Identifier{target.Schema, target.Table}.Sanitize()) + `::pg_catalog.regclass AND c.relkind OPERATOR(pg_catalog.=) 'I'::pg_catalog."char"; IF options IS DISTINCT FROM ARRAY[` + strings.Join(values, ",") + `]::pg_catalog.text[] THEN RAISE EXCEPTION 'The native partitioned-index options were not preserved by their reviewed definition'; END IF; END;`
				out = append(out, "DO LANGUAGE plpgsql "+postgresTextLiteral(body)+";")
			} else {
				out = append(out, "ALTER INDEX "+name+" SET ("+options+");")
			}
		}
		keys := []string{}
		switch raw := index["indkey"].(type) {
		case string:
			keys = strings.Fields(raw)
		case []any:
			for _, key := range raw {
				keys = append(keys, fmt.Sprint(key))
			}
		default:
			return nil, tableedit.ErrUnsupported
		}
		natts, err := strconv.Atoi(fmt.Sprint(index["indnatts"]))
		if err != nil || natts < 1 || natts > 128 || len(keys) != natts {
			return nil, errors.New("The complete native index-term definition is unavailable.")
		}
		seen := map[int]bool{}
		for _, a := range attributes {
			if fmt.Sprint(a["attrelid"]) != indexID {
				continue
			}
			ordinal, err := strconv.Atoi(fmt.Sprint(a["attnum"]))
			stored, present := a["attstattarget"]
			if !present {
				return nil, errors.New("The native index-column statistics field is absent from capture.")
			}
			statistics, statErr := -1, error(nil)
			// NULL is an unset native target; its raw encoding stays exact in
			// the independent catalog proof rather than becoming a SQL override.
			if stored != nil {
				statistics, statErr = strconv.Atoi(fmt.Sprint(stored))
			}
			if err != nil || statErr != nil || ordinal < 1 || ordinal > natts || seen[ordinal] || statistics < -1 || statistics > 10000 || a["atthasmissing"] != false || a["attmissingval"] != nil {
				return nil, errors.New("An index-column ordinal, statistics target or native layout is incomplete.")
			}
			seen[ordinal] = true
			if tableedit.SemanticPostgresAttributeOptions(a["attoptions"]) != nil {
				return nil, errors.New("Additional per-index-column attribute options require an explicit native migration; restoration never discards unknown source properties.")
			}
			if statistics != -1 {
				if keys[ordinal-1] != "0" {
					return nil, errors.New("Native ALTER INDEX SET STATISTICS applies only to expression terms; a nonexpression term with a nondefault catalog target requires explicit native reconciliation.")
				}
				out = append(out, "ALTER INDEX "+name+" ALTER COLUMN "+strconv.Itoa(ordinal)+" SET STATISTICS "+strconv.Itoa(statistics)+";")
			}
		}
		if len(seen) != natts {
			return nil, errors.New("A native index-attribute record is missing; no partial settings restoration is rendered.")
		}
	}
	for _, toast := range e.Rows[id+"/toast"] {
		indexes, ok := toast["indexes"].([]any)
		if !ok || len(indexes) != 1 {
			return nil, errors.New("Complete unique native TOAST-index origin is required before restoration.")
		}
		index, iok := indexes[0].(map[string]any)
		class, cok := index["class"].(map[string]any)
		if !iok || !cok {
			return nil, tableedit.ErrUnsupported
		}
		if class["reloptions"] != nil {
			return nil, errors.New("PostgreSQL rejects ALTER INDEX storage-option changes on its internal TOAST index (SQLSTATE 42501). Nondefault internal-index catalog options require a separate explicit native migration; this renderer never disables system-catalog protection.")
		}
		toastClass, ok := toast["class"].(map[string]any)
		if !ok {
			return nil, tableedit.ErrUnsupported
		}
		options, err := pgAdvancedNativeStorageOptions(toastClass["reloptions"], "toast.")
		if err != nil {
			return nil, err
		}
		if options != "" {
			out = append(out, "ALTER TABLE ONLY "+pgx.Identifier{target.Schema, target.Table}.Sanitize()+" SET ("+options+");")
		}
		for _, comment := range e.Rows[id+"/comments"] {
			if fmt.Sprint(comment["classoid"]) != "1259" || fmt.Sprint(comment["objoid"]) != fmt.Sprint(class["oid"]) {
				continue
			}
			text, ok := comment["description"].(string)
			if !ok || fmt.Sprint(comment["objsubid"]) != "0" {
				return nil, errors.New("The exact native TOAST-index comment address is incomplete.")
			}
			statement, err := pgAdvancedNativeToastIndexCommentSQL(target, text)
			if err != nil {
				return nil, err
			}
			out = append(out, statement)
		}
	}
	size := 0
	for _, statement := range out {
		size += len(statement)
		if size > tableedit.MaxSQLBytes {
			return nil, tableedit.ErrUnsupported
		}
	}
	return out, nil
}
