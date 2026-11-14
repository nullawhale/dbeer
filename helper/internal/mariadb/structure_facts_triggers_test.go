package mariadb

import (
	"reflect"
	"testing"

	"dbeer/helper/internal/tableedit"
)

func mariaTriggerDigestFixture() ([]string, [][]*string, tableedit.Target) {
	columns := []string{"TRIGGER_SCHEMA", "TRIGGER_NAME", "ACTION_STATEMENT", "SQL_MODE", "EVENT_OBJECT_SCHEMA", "EVENT_OBJECT_TABLE", "TRIGGER_NAME", "TRIGGER_SCHEMA", "EVENT_OBJECT_TABLE", "EVENT_OBJECT_SCHEMA", "ACTION_STATEMENT", "SQL_MODE", "ACTION_TIMING", "DEFINER", "CREATED", "CHARACTER_SET_CLIENT", "COLLATION_CONNECTION", "unknown"}
	values := []string{"s", "native_trigger", "SET NEW.n=1", "STRICT_TRANS_TABLES", "s", "old", "native_trigger", "s", "old", "s", "SET NEW.n=1", "STRICT_TRANS_TABLES", "BEFORE", "actor@localhost", "2026-01-01 01:02:03.00", "utf8mb4", "utf8mb4_bin", ""}
	row := make([]*string, len(values))
	for i := range values {
		v := values[i]
		row[i] = &v
	}
	row[len(row)-1] = nil
	return columns, [][]*string{row}, tableedit.Target{Schema: "s", Table: "old"}
}
func TestMariaDBOwnedTriggerRowsDigestExact(t *testing.T) {
	columns, rows, target := mariaTriggerDigestFixture()
	digest, ok := mariaOwnedTriggerRowsDigest(columns, rows, target)
	if !ok || digest == "" {
		t.Fatal("complete trigger fixture refused")
	}
	original := mariaRowsDigest(rows)
	renamed := tableedit.Target{Schema: "s", Table: "new"}
	next := append([]*string(nil), rows[0]...)
	name := "new"
	next[5] = &name
	next[8] = &name
	if value, ok := mariaOwnedTriggerRowsDigest(columns, [][]*string{next}, renamed); !ok || value != digest {
		t.Fatal("only native table address was not rename-stable")
	}
	if mariaRowsDigest(rows) != original {
		t.Fatal("observed trigger rows were mutated")
	}
	for _, i := range []int{0, 1, 2, 3, 4, 6, 7, 9, 10, 11, 12, 13, 14, 15, 16, 17} {
		t.Run(columns[i], func(t *testing.T) {
			changed := append([]*string(nil), rows[0]...)
			value := "changed"
			changed[i] = &value
			// Update both bound occurrences so this probes semantic equality as well as layout guards.
			pairs := map[int]int{0: 7, 1: 6, 2: 10, 3: 11, 4: 9, 6: 1, 7: 0, 9: 4, 10: 2, 11: 3}
			if pair, yes := pairs[i]; yes {
				changed[pair] = &value
			}
			if got, valid := mariaOwnedTriggerRowsDigest(columns, [][]*string{changed}, target); valid && got == digest {
				t.Fatal("native trigger property drift was ignored")
			}
		})
	}
	if !reflect.DeepEqual(columns, append([]string(nil), columns...)) {
		t.Fatal("column layout mutated")
	}
}
func TestMariaDBOwnedTriggerRowsDigestRejectsIncomplete(t *testing.T) {
	columns, rows, target := mariaTriggerDigestFixture()
	for _, mode := range []string{"prefix", "duplicateNative", "missingAddress", "rowWidth", "nullBody", "duplicateMismatch"} {
		t.Run(mode, func(t *testing.T) {
			names := append([]string(nil), columns...)
			row := append([]*string(nil), rows[0]...)
			switch mode {
			case "prefix":
				names[0] = "unknown"
			case "duplicateNative":
				names[17] = names[8]
			case "missingAddress":
				names[8] = "unmodeled"
			case "rowWidth":
				row = row[:len(row)-1]
			case "nullBody":
				row[2] = nil
				row[10] = nil
			case "duplicateMismatch":
				v := "different"
				row[8] = &v
			}
			if _, ok := mariaOwnedTriggerRowsDigest(names, [][]*string{row}, target); ok {
				t.Fatal("incomplete native trigger layout gained authority")
			}
		})
	}
}
