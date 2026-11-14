package mariadb

import (
	"reflect"
	"strings"
	"unicode/utf8"

	"dbeer/helper/internal/tableedit"
)

// Only the native owning-table address changes on same-schema RENAME. The
// complete field layout and all remaining native trigger properties stay exact.
func mariaOwnedTriggerRowsDigest(columns []string, rows [][]*string, target tableedit.Target) (string, bool) {
	prefix := []string{"TRIGGER_SCHEMA", "TRIGGER_NAME", "ACTION_STATEMENT", "SQL_MODE", "EVENT_OBJECT_SCHEMA", "EVENT_OBJECT_TABLE"}
	if !target.Valid() || len(columns) <= len(prefix) || !reflect.DeepEqual(columns[:len(prefix)], prefix) {
		return "", false
	}
	native := columns[len(prefix):]
	positions := map[string]int{}
	header := make([]*string, len(native))
	for i, name := range native {
		if name == "" || len(name) > 65536 || !utf8.ValidString(name) || strings.ContainsRune(name, 0) {
			return "", false
		}
		if _, exists := positions[name]; exists {
			return "", false
		}
		positions[name] = i
		value := name
		header[i] = &value
	}
	for _, name := range prefix {
		if _, present := positions[name]; !present {
			return "", false
		}
	}
	normalized := [][]*string{header}
	for _, row := range rows {
		if len(row) != len(columns) {
			return "", false
		}
		for i, name := range prefix {
			if !reflect.DeepEqual(row[i], row[len(prefix)+positions[name]]) {
				return "", false
			}
		}
		if row[0] == nil || row[1] == nil || row[2] == nil || row[3] == nil || row[4] == nil || row[5] == nil {
			return "", false
		}
		if *row[4] != target.Schema || *row[5] != target.Table {
			continue
		}
		copyRow := append([]*string(nil), row[len(prefix):]...)
		address := ""
		copyRow[positions["EVENT_OBJECT_TABLE"]] = &address
		normalized = append(normalized, copyRow)
	}
	return mariaRowsDigest(normalized), true
}
