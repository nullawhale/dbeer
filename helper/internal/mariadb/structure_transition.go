package mariadb

import (
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"encoding/base64"
	"encoding/json"
	"reflect"
	"sort"
	"strings"
)

// The global FK-name inventory is private metadata, not an execution grant.
// Normalize a comparison clone only after proving its exact selected-row delta.
func mariaDBExpectedForeignNames(before, after, source tableedit.Baseline, c tableedit.Condition) (tableedit.Baseline, bool) {
	return mariaDBExpectedForeignNamesOperations(before, after, source, []tableedit.Operation{c.Operation})
}

func mariaDBExpectedForeignNamesOperations(before, after, source tableedit.Baseline, operations []tableedit.Operation) (tableedit.Baseline, bool) {
	if before.Facts == nil || after.Facts == nil {
		return after, false
	}
	if before.Target.Schema != source.Target.Schema {
		return after, true
	}
	get := func(b tableedit.Baseline) (string, bool) {
		value := ""
		seen := false
		for _, o := range b.Facts.EngineContext {
			if o.Name == "schemaForeignKeyNames" {
				if seen {
					return "", false
				}
				seen = true
				value = o.Value
			}
		}
		return value, seen
	}
	raw, ok := get(before)
	next, present := get(after)
	if !ok || !present {
		return after, false
	}
	var expected, observed [][]string
	decode := func(raw string) ([][]string, bool) {
		var rows [][]*string
		trimmed := strings.TrimSpace(raw)
		if len(trimmed) == 0 || trimmed[0] != '[' {
			return nil, false
		}
		if json.Unmarshal([]byte(raw), &rows) != nil || len(rows) > 2048 {
			return nil, false
		}
		out := [][]string{}
		seen := map[string]bool{}
		for _, row := range rows {
			if len(row) != 2 || row[0] == nil || row[1] == nil {
				return nil, false
			}
			left, leftErr := base64.StdEncoding.DecodeString(*row[0])
			right, rightErr := base64.StdEncoding.DecodeString(*row[1])
			if leftErr != nil || rightErr != nil {
				return nil, false
			}
			name, constraint := string(left), string(right)
			if !mariaDBNameValid(name) || !mariaDBNameValid(constraint) {
				return nil, false
			}
			key := name + "\x00" + constraint
			if seen[key] {
				return nil, false
			}
			seen[key] = true
			out = append(out, []string{name, constraint})
		}
		return out, true
	}
	expected, ok = decode(raw)
	if !ok {
		return after, false
	}
	observed, ok = decode(next)
	if !ok {
		return after, false
	}
	owner := source.Target.Table
	dropped := false
	for _, op := range operations {
		if dropped {
			return after, false
		}
		if (op.Kind == "addKey" || op.Kind == "dropKey") && op.Key != nil && op.Key.Kind == "foreign" {
			if !mariaDBNameValid(op.Key.Name) {
				return after, false
			}
			row := []string{owner, op.Key.Name}
			found := -1
			for i, v := range expected {
				if reflect.DeepEqual(v, row) {
					found = i
					break
				}
			}
			if op.Kind == "addKey" {
				if found >= 0 {
					return after, false
				}
				expected = append(expected, row)
			} else {
				if found < 0 {
					return after, false
				}
				expected = append(expected[:found], expected[found+1:]...)
			}
		}
		if op.Kind == "renameTable" {
			if op.Name == nil || !mariaDBNameValid(*op.Name) {
				return after, false
			}
			for _, row := range expected {
				if row[0] == owner {
					row[0] = *op.Name
				}
			}
			owner = *op.Name
		}
		if op.Kind == "dropTable" {
			kept := [][]string{}
			for _, row := range expected {
				if row[0] != owner {
					kept = append(kept, row)
				}
			}
			expected = kept
			dropped = true
		}
	}
	order := func(v [][]string) {
		sort.Slice(v, func(i, j int) bool {
			if v[i][0] == v[j][0] {
				return v[i][1] < v[j][1]
			}
			return v[i][0] < v[j][0]
		})
	}
	order(expected)
	order(observed)
	if !reflect.DeepEqual(expected, observed) {
		return after, false
	}
	facts := *after.Facts
	facts.EngineContext = append([]sc.Option(nil), after.Facts.EngineContext...)
	after.Facts = &facts
	for i := range facts.EngineContext {
		if facts.EngineContext[i].Name == "schemaForeignKeyNames" {
			facts.EngineContext[i].Value = raw
		}
	}
	return after, true
}
func mariaDBTypedStructurePreserved(before, after tableedit.Baseline, c tableedit.Condition) bool {
	if c.Operation.Kind == "create" {
		return tableedit.VerifyTransition(before, after, c, func(col sc.Column, d tableedit.Default) bool { return mariaDBDefaultMatches(col, d, after.Facts) })
	}
	normalized, ok := mariaDBExpectedForeignNames(before, after, before, c)
	return ok && tableedit.VerifyTransition(before, normalized, c, func(col sc.Column, d tableedit.Default) bool { return mariaDBDefaultMatches(col, d, after.Facts) })
}
func mariaDBReferencePreserved(before, after, source tableedit.Baseline, c tableedit.Condition) bool {
	normalized, ok := mariaDBExpectedForeignNames(before, after, source, c)
	return ok && tableedit.VerifyReference(before, normalized, source, c)
}
