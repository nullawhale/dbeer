package postgres

import (
	"dbeer/helper/internal/tableedit"
	"strings"
)

// Keep every native property-restoration statement visible in the same reviewed
// transaction. The local block restores the owning session's exact search_path.
func pgAdvancedRestoreUnitSQL(b tableedit.Baseline, id string, target tableedit.Target, statement string) (string, error) {
	restore, err := pgAdvancedNativeIndexRestoreSQL(b, id, target)
	if err != nil || len(restore) == 0 {
		return statement, err
	}
	body := "DECLARE saved_search_path pg_catalog.text := pg_catalog.current_setting('search_path'); BEGIN PERFORM pg_catalog.set_config('search_path','pg_catalog',true); "
	for _, sql := range restore {
		body += "EXECUTE " + postgresTextLiteral(sql) + "; "
	}
	body += "PERFORM pg_catalog.set_config('search_path',saved_search_path,true); END;"
	block := "DO LANGUAGE plpgsql " + postgresTextLiteral(body) + ";"
	result := strings.TrimSpace(statement)
	if result != "" {
		result += "\n"
	}
	result += block
	if len(result) > tableedit.MaxSQLBytes {
		return "", tableedit.ErrUnsupported
	}
	return result, nil
}

// Rendering a later ALTER must not restore settings of an object explicitly
// removed by an earlier reviewed unit. The original execution proof stays exact.
func pgAdvancedRestoreAfterOperations(b tableedit.Baseline, prior []tableedit.Operation) (tableedit.Baseline, error) {
	if b.AdvancedEvidence == nil {
		return b, tableedit.ErrUnsupported
	}
	removed := map[string]bool{}
	for _, op := range prior {
		selected := false
		found := false
		switch op.Kind {
		case "dropIndex":
			selected = true
			if op.Index == nil {
				return b, tableedit.ErrUnsupported
			}
			for _, row := range b.AdvancedEvidence.Rows[b.Identity+"/indexes"] {
				cl, ok := row["class"].(map[string]any)
				if !ok {
					return b, tableedit.ErrUnsupported
				}
				if cl["relname"] == op.Index.Name {
					id := pgPhysicalOID(cl["oid"])
					if id == "" {
						return b, tableedit.ErrUnsupported
					}
					removed[id] = true
					found = true
				}
			}
		case "dropKey":
			if op.Key == nil {
				return b, tableedit.ErrUnsupported
			}
			if op.Key.Kind != "primary" && op.Key.Kind != "unique" {
				continue
			}
			selected = true
			for _, row := range b.AdvancedEvidence.Rows[b.Identity+"/constraints"] {
				if row["conname"] == op.Key.Name && (row["contype"] == "p" || row["contype"] == "u") && pgPhysicalOID(row["conrelid"]) == b.Identity {
					id := pgPhysicalOID(row["conindid"])
					if id == "" {
						return b, tableedit.ErrUnsupported
					}
					removed[id] = true
					found = true
				}
			}
		}
		if selected && !found {
			return b, tableedit.ErrUnsupported
		}
	}
	if len(removed) == 0 {
		return b, nil
	}
	for changed := true; changed; {
		changed = false
		for key, rows := range b.AdvancedEvidence.Rows {
			if !strings.HasSuffix(key, "/indexes") {
				continue
			}
			for _, row := range rows {
				cl, ok := row["class"].(map[string]any)
				if !ok {
					return b, tableedit.ErrUnsupported
				}
				id := pgPhysicalOID(cl["oid"])
				parents, ok := row["parents"].([]any)
				if !ok {
					return b, tableedit.ErrUnsupported
				}
				for _, parent := range parents {
					if removed[pgPhysicalOID(parent)] && !removed[id] {
						removed[id] = true
						changed = true
					}
				}
			}
		}
	}
	b.AdvancedEvidence = tableedit.CloneAdvancedEvidence(b.AdvancedEvidence)
	for key, rows := range b.AdvancedEvidence.Rows {
		field := ""
		if strings.HasSuffix(key, "/indexes") {
			field = "index"
		} else if strings.HasSuffix(key, "/indexAttributes") {
			field = "attribute"
		} else {
			continue
		}
		kept := []map[string]any{}
		for _, row := range rows {
			id := pgPhysicalOID(row["attrelid"])
			if field == "index" {
				cl, ok := row["class"].(map[string]any)
				if !ok {
					return b, tableedit.ErrUnsupported
				}
				id = pgPhysicalOID(cl["oid"])
			}
			if !removed[id] {
				kept = append(kept, row)
			}
		}
		b.AdvancedEvidence.Rows[key] = kept
	}
	return b, nil
}
