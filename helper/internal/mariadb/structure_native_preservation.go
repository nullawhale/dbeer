package mariadb

import (
	"dbeer/helper/internal/tableedit"
	"reflect"
	"strconv"
	"strings"
)

type mariaDBNativeClause struct {
	kind, name string
	tokens     []mariaIndexMetadataToken
}
type mariaDBNativeDefinition struct {
	columns, objects map[string]mariaDBNativeClause
	suffix           []mariaIndexMetadataToken
}

// Native unknown properties stay in the compared token bags. Only the exact
// reviewed object's grammar slot may differ after its typed transition proof.
func mariaDBNativeStructure(raw, mode, name string) (mariaDBNativeDefinition, bool) {
	out := mariaDBNativeDefinition{columns: map[string]mariaDBNativeClause{}, objects: map[string]mariaDBNativeClause{}}
	ts, ok := mariaIndexMetadataTokens(raw, mode, 0)
	if !ok || len(ts) < 6 || !mariaDBNativeWord(ts[0], "CREATE") || !mariaDBNativeWord(ts[1], "TABLE") || ts[2].kind != "identifier" || ts[2].value != name || ts[3].value != "(" {
		return out, false
	}
	begin, level, close := 4, 1, -1
	add := func(v []mariaIndexMetadataToken) bool {
		if len(v) < 2 {
			return false
		}
		c := mariaDBNativeClause{tokens: mariaDBNativeTokens(v)}
		switch {
		case v[0].kind == "identifier":
			c.kind = "column"
			c.name = v[0].value
		case mariaDBNativeWord(v[0], "PRIMARY") && mariaDBNativeWord(v[1], "KEY"):
			c.kind = "key"
			c.name = "PRIMARY"
		case mariaDBNativeWord(v[0], "UNIQUE") && len(v) > 3 && (mariaDBNativeWord(v[1], "KEY") || mariaDBNativeWord(v[1], "INDEX")):
			c.kind = "key"
			c.name = v[2].value
		case mariaDBNativeWord(v[0], "KEY") || mariaDBNativeWord(v[0], "INDEX"):
			c.kind = "index"
			c.name = v[1].value
		case (mariaDBNativeWord(v[0], "FULLTEXT") || mariaDBNativeWord(v[0], "SPATIAL")) && len(v) > 3 && (mariaDBNativeWord(v[1], "KEY") || mariaDBNativeWord(v[1], "INDEX")):
			c.kind = "index"
			c.name = v[2].value
		case mariaDBNativeWord(v[0], "CONSTRAINT") && v[1].kind == "identifier":
			c.kind = "constraint"
			c.name = v[1].value
		case mariaDBNativeWord(v[0], "PERIOD") && mariaDBNativeWord(v[1], "FOR"):
			c.kind = "period"
			c.name = "SYSTEM_TIME"
		default:
			return false
		}
		bag := out.objects
		if c.kind == "column" {
			bag = out.columns
		}
		key := c.name
		if c.kind != "column" {
			key = mariaDBNativeObjectKey(c.kind, c.name)
		}
		if _, exists := bag[key]; exists {
			return false
		}
		bag[key] = c
		return true
	}
	for i := begin; i < len(ts); i++ {
		if ts[i].kind != "punct" {
			continue
		}
		switch ts[i].value {
		case "(":
			level++
		case ")":
			level--
			if level == 0 {
				if !add(ts[begin:i]) {
					return out, false
				}
				close = i
				i = len(ts)
			}
		case ",":
			if level == 1 {
				if !add(ts[begin:i]) {
					return out, false
				}
				begin = i + 1
			}
		}
	}
	if close < 0 || len(out.columns) == 0 {
		return out, false
	}
	out.suffix = mariaDBNativeTokens(ts[close+1:])
	return out, true
}
func mariaDBNativeWord(t mariaIndexMetadataToken, word string) bool {
	return t.kind == "word" && strings.EqualFold(t.value, word)
}
func mariaDBNativeTokens(input []mariaIndexMetadataToken) []mariaIndexMetadataToken {
	out := make([]mariaIndexMetadataToken, len(input))
	for i, t := range input {
		out[i] = mariaIndexMetadataToken{kind: t.kind, value: t.value}
		if t.kind == "word" {
			out[i].value = strings.ToUpper(t.value)
		}
	}
	return out
}
func mariaDBStructureMode(b tableedit.Baseline) string {
	if b.Facts != nil {
		for _, o := range b.Facts.EngineContext {
			if o.Name == "sqlMode" {
				return o.Value
			}
		}
	}
	return ""
}

func mariaDBNativeDefaultSlot(ts []mariaIndexMetadataToken) ([]mariaIndexMetadataToken, bool) {
	level := 0
	for i := 1; i < len(ts); i++ {
		t := ts[i]
		if t.kind == "punct" {
			if t.value == "(" {
				level++
			}
			if t.value == ")" {
				level--
			}
			if level < 0 {
				return nil, false
			}
		}
		if level != 0 || !mariaDBNativeWord(t, "DEFAULT") {
			continue
		}
		end := i + 1
		if end >= len(ts) {
			return nil, false
		}
		if ts[end].value == "+" || ts[end].value == "-" {
			end++
			if end >= len(ts) {
				return nil, false
			}
		}
		if ts[end].value == "(" {
			depth := 1
			end++
			for end < len(ts) && depth > 0 {
				if ts[end].kind == "punct" && ts[end].value == "(" {
					depth++
				}
				if ts[end].kind == "punct" && ts[end].value == ")" {
					depth--
				}
				end++
			}
			if depth != 0 {
				return nil, false
			}
		} else {
			end++
			// Native numeric fractions and charset/hex literal prefixes are single slots.
			if end+1 < len(ts) && ts[end].value == "." && ts[end-1].kind == "word" && ts[end+1].kind == "word" {
				end += 2
			}
			if end < len(ts) && ts[end].kind == "string" && ts[end-1].kind == "word" {
				end++
			}
			if end < len(ts) && ts[end].value == "(" {
				depth := 1
				end++
				for end < len(ts) && depth > 0 {
					if ts[end].kind == "punct" && ts[end].value == "(" {
						depth++
					}
					if ts[end].kind == "punct" && ts[end].value == ")" {
						depth--
					}
					end++
				}
				if depth != 0 {
					return nil, false
				}
			}
		}
		// Anything other than a known subsequent column attribute is unproven.
		if end < len(ts) && !mariaDBNativeColumnAttribute(ts[end]) {
			return nil, false
		}
		out := append([]mariaIndexMetadataToken(nil), ts[:i]...)
		out = append(out, ts[end:]...)
		return out, true
	}
	return append([]mariaIndexMetadataToken(nil), ts...), true
}
func mariaDBNativeColumnAttribute(t mariaIndexMetadataToken) bool {
	if t.kind != "word" {
		return false
	}
	switch strings.ToUpper(t.value) {
	case "NOT", "NULL", "DEFAULT", "GENERATED", "AUTO_INCREMENT", "UNIQUE", "PRIMARY", "COMMENT", "COLLATE", "CHARACTER", "ON", "VISIBLE", "INVISIBLE", "CHECK", "REFERENCES", "WITH", "WITHOUT", "COLUMN_FORMAT", "STORAGE":
		return true
	}
	return false
}
func mariaDBNativeNullableSlot(ts []mariaIndexMetadataToken) ([]mariaIndexMetadataToken, bool) {
	out := []mariaIndexMetadataToken{}
	level := 0
	for i := 0; i < len(ts); i++ {
		t := ts[i]
		if t.kind == "punct" {
			if t.value == "(" {
				level++
			}
			if t.value == ")" {
				level--
			}
			if level < 0 {
				return nil, false
			}
		}
		if level == 0 && mariaDBNativeWord(t, "NOT") && i+1 < len(ts) && mariaDBNativeWord(ts[i+1], "NULL") {
			i++
			continue
		}
		if level == 0 && mariaDBNativeWord(t, "NULL") && (i == 0 || !mariaDBNativeWord(ts[i-1], "DEFAULT")) {
			continue
		}
		out = append(out, t)
	}
	return out, level == 0
}

func mariaDBNativeStructurePreserved(before, after tableedit.Baseline, c tableedit.Condition) bool {
	a, ok := mariaDBNativeStructure(before.NativeDefinition, mariaDBStructureMode(before), before.Target.Table)
	if !ok {
		return false
	}
	b, ok := mariaDBNativeStructure(after.NativeDefinition, mariaDBStructureMode(after), after.Target.Table)
	if !ok {
		return false
	}
	if c.Operation.Change != nil && c.Operation.Change.Identity != nil {
		var valid bool
		a.suffix, valid = mariaDBNativeCounterSlot(a.suffix)
		if !valid {
			return false
		}
		b.suffix, valid = mariaDBNativeCounterSlot(b.suffix)
		if !valid {
			return false
		}
	}
	if !reflect.DeepEqual(a.suffix, b.suffix) {
		return false
	}
	op := c.Operation
	switch op.Kind {
	case "addColumn":
		if op.Column == nil {
			return false
		}
		if _, exists := a.columns[op.Column.Name]; exists {
			return false
		}
		if _, exists := b.columns[op.Column.Name]; !exists {
			return false
		}
		delete(b.columns, op.Column.Name)
	case "dropColumn":
		if op.Change == nil {
			return false
		}
		if _, exists := a.columns[op.Change.Name]; !exists {
			return false
		}
		if _, exists := b.columns[op.Change.Name]; exists {
			return false
		}
		delete(a.columns, op.Change.Name)
	case "changeColumn":
		if op.Change == nil {
			return false
		}
		change := op.Change
		x, xok := a.columns[change.Name]
		y, yok := b.columns[change.Name]
		if !xok || !yok {
			return false
		}
		if change.Unsigned != nil || change.Charset != nil || change.Collation != nil {
			return false
		}
		if change.Generated != nil {
			x.tokens, ok = mariaDBNativeGenerationSlot(x.tokens)
			if !ok {
				return false
			}
			y.tokens, ok = mariaDBNativeGenerationSlot(y.tokens)
			if !ok {
				return false
			}
			x.tokens, ok = mariaDBNativeDefaultSlot(x.tokens)
			if !ok {
				return false
			}
			y.tokens, ok = mariaDBNativeDefaultSlot(y.tokens)
			if !ok {
				return false
			}
		}
		if change.Identity != nil {
			x.tokens = mariaDBNativeIdentitySlot(x.tokens)
			y.tokens = mariaDBNativeIdentitySlot(y.tokens)
		}
		if change.Type != nil {
			x.tokens, ok = mariaDBNativeTypeSlot(x.tokens)
			if !ok {
				return false
			}
			y.tokens, ok = mariaDBNativeTypeSlot(y.tokens)
			if !ok {
				return false
			}
		}
		// Native nullable SQL NULL defaults disappear when a required column is
		// selected. Exact typed none/sqlNull normalization is independently proved.
		normalizeNullDefault := false
		if change.Nullable != nil {
			old, exists := tableedit.FindColumn(before, change.Name)
			normalizeNullDefault = exists && old.Default.Value != nil && (old.Default.Value.Kind == "none" || old.Default.Value.Kind == "sqlNull")
		}
		if change.Default != nil || normalizeNullDefault {
			x.tokens, ok = mariaDBNativeDefaultSlot(x.tokens)
			if !ok {
				return false
			}
			y.tokens, ok = mariaDBNativeDefaultSlot(y.tokens)
			if !ok {
				return false
			}
		}
		if change.Nullable != nil {
			x.tokens, ok = mariaDBNativeNullableSlot(x.tokens)
			if !ok {
				return false
			}
			y.tokens, ok = mariaDBNativeNullableSlot(y.tokens)
			if !ok {
				return false
			}
		}
		a.columns[change.Name] = x
		b.columns[change.Name] = y
	case "renameColumn":
		if op.Change == nil || op.Change.RenameTo == nil {
			return false
		}
		x, exists := a.columns[op.Change.Name]
		if !exists {
			return false
		}
		if _, collision := a.columns[*op.Change.RenameTo]; collision {
			return false
		}
		delete(a.columns, op.Change.Name)
		x.name = *op.Change.RenameTo
		x.tokens[0].value = x.name
		a.columns[x.name] = x
	case "backfill":
		// A reviewed UPDATE changes no native schema slot. Every clause remains exact.
	case "reorder":
		// The independent typed verifier proves the complete requested order;
		// every native column/object clause and suffix remains exact here.
	case "renameTable":
		if op.Name == nil || after.Target.Table != *op.Name {
			return false
		}
	case "addIndex", "dropIndex":
		if op.Index == nil {
			return false
		}
		name := mariaDBNativeObjectKey("index", op.Index.Name)
		if op.Kind == "addIndex" {
			if _, exists := a.objects[name]; exists {
				return false
			}
			x, exists := b.objects[name]
			if !exists || x.kind != "index" {
				return false
			}
			delete(b.objects, name)
		} else {
			x, exists := a.objects[name]
			if !exists || x.kind != "index" {
				return false
			}
			if _, exists := b.objects[name]; exists {
				return false
			}
			delete(a.objects, name)
		}
	case "addKey", "dropKey":
		if op.Key == nil {
			return false
		}
		kind := "key"
		if op.Key.Kind == "foreign" {
			kind = "constraint"
		}
		name := mariaDBNativeObjectKey(kind, op.Key.Name)
		if op.Kind == "addKey" {
			if _, exists := a.objects[name]; exists {
				return false
			}
			if _, exists := b.objects[name]; !exists {
				return false
			}
			delete(b.objects, name)
		} else {
			if _, exists := a.objects[name]; !exists {
				return false
			}
			if _, exists := b.objects[name]; exists {
				return false
			}
			delete(a.objects, name)
		}
	default:
		return false
	}
	return reflect.DeepEqual(a.columns, b.columns) && reflect.DeepEqual(a.objects, b.objects)
}

// Only the initial type grammar is removed; all subsequent native column slots
// remain exact. The typed transition separately proves every selected modifier.
func mariaDBNativeTypeSlot(ts []mariaIndexMetadataToken) ([]mariaIndexMetadataToken, bool) {
	if len(ts) < 2 || ts[0].kind != "identifier" || ts[1].kind != "word" {
		return nil, false
	}
	end := 2
	if end < len(ts) && ts[end].value == "(" {
		depth := 1
		end++
		for end < len(ts) && depth > 0 {
			if ts[end].value == "(" {
				depth++
			}
			if ts[end].value == ")" {
				depth--
			}
			end++
		}
		if depth != 0 {
			return nil, false
		}
	}
	for end < len(ts) && (mariaDBNativeWord(ts[end], "UNSIGNED") || mariaDBNativeWord(ts[end], "ZEROFILL")) {
		end++
	}
	if end < len(ts) && !mariaDBNativeColumnAttribute(ts[end]) {
		return nil, false
	}
	return append(append([]mariaIndexMetadataToken(nil), ts[:1]...), ts[end:]...), true
}

// Only native generation grammar is removed after the exact typed generated/default
// transition has succeeded. Every other column attribute remains in the proof.
func mariaDBNativeGenerationSlot(ts []mariaIndexMetadataToken) ([]mariaIndexMetadataToken, bool) {
	for i := 1; i < len(ts); i++ {
		if !mariaDBNativeWord(ts[i], "GENERATED") {
			continue
		}
		if i+4 >= len(ts) || !mariaDBNativeWord(ts[i+1], "ALWAYS") || !mariaDBNativeWord(ts[i+2], "AS") || ts[i+3].value != "(" {
			return nil, false
		}
		depth := 1
		j := i + 4
		for j < len(ts) && depth > 0 {
			if ts[j].kind == "punct" && ts[j].value == "(" {
				depth++
			}
			if ts[j].kind == "punct" && ts[j].value == ")" {
				depth--
			}
			j++
		}
		if depth != 0 || j >= len(ts) || !mariaDBNativeWord(ts[j], "STORED") && !mariaDBNativeWord(ts[j], "VIRTUAL") {
			return nil, false
		}
		out := append([]mariaIndexMetadataToken(nil), ts[:i]...)
		return append(out, ts[j+1:]...), true
	}
	return append([]mariaIndexMetadataToken(nil), ts...), true
}
func mariaDBNativeIdentitySlot(ts []mariaIndexMetadataToken) []mariaIndexMetadataToken {
	out := []mariaIndexMetadataToken{}
	level := 0
	for _, t := range ts {
		if t.kind == "punct" && t.value == "(" {
			level++
		}
		if t.kind == "punct" && t.value == ")" {
			level--
		}
		if level == 0 && mariaDBNativeWord(t, "AUTO_INCREMENT") {
			continue
		}
		out = append(out, t)
	}
	return out
}
func mariaDBNativeCounterSlot(ts []mariaIndexMetadataToken) ([]mariaIndexMetadataToken, bool) {
	out := []mariaIndexMetadataToken{}
	seen := false
	for i := 0; i < len(ts); i++ {
		if mariaDBNativeWord(ts[i], "AUTO_INCREMENT") {
			if seen || i+2 >= len(ts) || ts[i+1].value != "=" {
				return nil, false
			}
			v, e := strconv.ParseUint(ts[i+2].value, 10, 64)
			if e != nil || strconv.FormatUint(v, 10) != ts[i+2].value {
				return nil, false
			}
			seen = true
			i += 2
			continue
		}
		out = append(out, ts[i])
	}
	return out, true
}

func mariaDBNativeObjectKey(kind, name string) string {
	if kind == "key" {
		kind = "index"
	}
	return kind + "\x00" + name
}
