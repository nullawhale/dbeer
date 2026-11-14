package mysql

import (
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"reflect"
	"strconv"
	"strings"
)

type physicalMySQLSuffix struct {
	Table       []string
	Header      []string
	Parts       map[string][]string
	Partitioned bool
}

func physicalMySQLTokens(raw, mode string) ([]indexMetadataToken, []string, bool) {
	tokens, ok := mysqlIndexMetadataTokens(raw, mode, 0)
	if !ok {
		return nil, nil, false
	}
	canonical := make([]string, len(tokens))
	for i, t := range tokens {
		if t.start < 0 || t.end > len(raw) || t.start >= t.end {
			return nil, nil, false
		}
		canonical[i] = t.kind + ":" + raw[t.start:t.end]
	}
	return tokens, canonical, true
}
func physicalMySQLMode(b tableedit.Baseline) string {
	if b.Facts != nil {
		for _, o := range b.Facts.EngineContext {
			if o.Name == "sqlMode" {
				return o.Value
			}
		}
	}
	return ""
}

// Only partition syntax is removed from the native table suffix. Every table
// option and every unselected partition option remains exact opaque evidence.
func readPhysicalMySQLSuffix(b tableedit.Baseline) (physicalMySQLSuffix, bool) {
	out := physicalMySQLSuffix{Parts: map[string][]string{}}
	_, _, suffix, ok := mysqlReconstructionDefinition(b.NativeDefinition, b.Facts)
	if !ok {
		return out, false
	}
	tokens, canonical, ok := physicalMySQLTokens(suffix, physicalMySQLMode(b))
	if !ok {
		return out, false
	}
	part := -1
	for i, t := range tokens {
		if t.kind == "word" && strings.EqualFold(t.value, "PARTITION") {
			if i+1 >= len(tokens) || !strings.EqualFold(tokens[i+1].value, "BY") {
				return out, false
			}
			part = i
			break
		}
	}
	if part < 0 {
		out.Table = canonical
		return out, true
	}
	out.Partitioned = true
	out.Table = canonical[:part]
	// Find the outer partition-definition list after the key expression. Native
	// HASH/KEY may omit the list and use only PARTITIONS n.
	level, start, listStart := 0, -1, -1
	for i := part + 2; i < len(tokens); i++ {
		t := tokens[i]
		if t.value == "(" {
			if level == 0 && i+1 < len(tokens) && strings.EqualFold(tokens[i+1].value, "PARTITION") {
				listStart = i
				break
			}
			level++
		} else if t.value == ")" {
			level--
			if level < 0 {
				return out, false
			}
		}
	}
	endHeader := len(tokens)
	if listStart >= 0 {
		endHeader = listStart
	}
	if level != 0 {
		return out, false
	}
	out.Header = []string{}
	for i := part; i < endHeader; i++ {
		if strings.EqualFold(tokens[i].value, "PARTITIONS") {
			if i+1 >= endHeader {
				return out, false
			}
			if _, e := strconv.Atoi(tokens[i+1].value); e != nil {
				return out, false
			}
			i++
			continue
		}
		out.Header = append(out.Header, canonical[i])
	}
	if listStart < 0 {
		return out, true
	}
	level = 1
	start = listStart + 1
	add := func(end int) bool {
		if start+1 >= end || !strings.EqualFold(tokens[start].value, "PARTITION") || (tokens[start+1].kind != "word" && tokens[start+1].kind != "identifier") {
			return false
		}
		name := tokens[start+1].value
		if _, exists := out.Parts[name]; exists {
			return false
		}
		optionStart := start + 2
		if optionStart < end && strings.EqualFold(tokens[optionStart].value, "VALUES") {
			open := -1
			for i := optionStart + 1; i < end; i++ {
				if tokens[i].value == "(" {
					open = i
					break
				}
			}
			if open < 0 {
				if optionStart+3 < end && strings.EqualFold(tokens[optionStart+1].value, "LESS") && strings.EqualFold(tokens[optionStart+2].value, "THAN") && strings.EqualFold(tokens[optionStart+3].value, "MAXVALUE") {
					optionStart += 4
				} else {
					return false
				}
			} else {
				depth := 1
				optionStart = -1
				for i := open + 1; i < end; i++ {
					if tokens[i].value == "(" {
						depth++
					}
					if tokens[i].value == ")" {
						depth--
						if depth == 0 {
							optionStart = i + 1
							break
						}
					}
				}
				if optionStart < 0 {
					return false
				}
			}
		}
		out.Parts[name] = append([]string(nil), canonical[optionStart:end]...)
		return true
	}
	for i := start; i < len(tokens); i++ {
		if tokens[i].value == "(" {
			level++
		}
		if tokens[i].value == ")" {
			level--
			if level == 0 {
				if !add(i) || i != len(tokens)-1 {
					return out, false
				}
				return out, true
			}
		}
		if tokens[i].value == "," && level == 1 {
			if !add(i) {
				return out, false
			}
			start = i + 1
		}
	}
	return out, false
}
func physicalMySQLDefaultPartitionOptions(options []string, engine string) bool {
	return len(options) == 3 && options[0] == "word:ENGINE" && options[1] == "punct:=" && options[2] == "word:"+engine
}
func physicalMySQLPartitionProperties(before, after myPhysicalEvidence, x tableedit.PhysicalIntent) bool {
	a, b := before.Baseline, after.Baseline
	if a.Facts == nil || b.Facts == nil || before.Engine != after.Engine || a.Scope != b.Scope {
		return false
	}
	sa, ok := readPhysicalMySQLSuffix(a)
	if !ok {
		return false
	}
	sb, ok := readPhysicalMySQLSuffix(b)
	if !ok || !reflect.DeepEqual(sa.Table, sb.Table) {
		return false
	}
	var af, bf tableedit.Facts
	raw, e := json.Marshal(a.Facts)
	if e != nil || json.Unmarshal(raw, &af) != nil {
		return false
	}
	raw, e = json.Marshal(b.Facts)
	if e != nil || json.Unmarshal(raw, &bf) != nil {
		return false
	}
	normalize := func(f *tableedit.Facts, partitioned bool) bool {
		options := ""
		for _, o := range f.Table.Options.Items {
			if o.Name == "createOptions" {
				options = o.Value
			}
		}
		expected := sc.Known("table")
		if before.Engine != "InnoDB" || options != "" {
			expected = sc.Unknown[string]("tableEngineOrOptions")
		}
		if !reflect.DeepEqual(f.Table.Kind, expected) {
			return false
		}
		if x.Kind == "partitionTable" || x.Kind == "removePartitioning" {
			found := false
			out := f.Table.Options.Items[:0]
			for _, o := range f.Table.Options.Items {
				if o.Name == "createOptions" {
					words := strings.Fields(o.Value)
					retained := []string{}
					for _, word := range words {
						if word == "partitioned" {
							if found {
								return false
							}
							found = true
						} else {
							retained = append(retained, word)
						}
					}
					o.Value = strings.Join(retained, " ")
					if o.Value == "" {
						continue
					}
				}
				out = append(out, o)
			}
			if found != partitioned {
				return false
			}
			f.Table.Options.Items = out
			f.Table.Kind = sc.Known("table")
		}
		return true
	}
	if !normalize(&af, sa.Partitioned) || !normalize(&bf, sb.Partitioned) || !reflect.DeepEqual(af, bf) {
		return false
	}
	if x.Kind == "partitionTable" {
		if sa.Partitioned || !sb.Partitioned {
			return false
		}
	} else if x.Kind == "removePartitioning" {
		return sa.Partitioned && !sb.Partitioned
	} else if !sa.Partitioned || !sb.Partitioned || !reflect.DeepEqual(sa.Header, sb.Header) {
		return false
	}
	selected := map[string]bool{}
	for _, n := range x.Partitions {
		selected[n] = true
	}
	for _, d := range x.Definitions {
		selected[d.Name] = true
	}
	if x.Kind == "truncatePartition" || x.Kind == "exchangePartition" {
		return reflect.DeepEqual(sa.Parts, sb.Parts)
	}
	for name, options := range sa.Parts {
		if !selected[name] {
			if !reflect.DeepEqual(options, sb.Parts[name]) {
				return false
			}
		} else if x.Kind == "reorganizePartition" && !physicalMySQLDefaultPartitionOptions(options, before.Engine) {
			return false
		}
	}
	for name, options := range sb.Parts {
		if _, existed := sa.Parts[name]; !existed || x.Kind == "partitionTable" || x.Kind == "reorganizePartition" && selected[name] {
			if !physicalMySQLDefaultPartitionOptions(options, after.Engine) {
				return false
			}
		}
	}
	return true
}
func physicalMySQLReorganizeProperties(e myPhysicalEvidence, x tableedit.PhysicalIntent) bool {
	if x.Kind != "reorganizePartition" && x.Kind != "addHashPartitions" && x.Kind != "coalescePartitions" {
		return true
	}
	suffix, ok := readPhysicalMySQLSuffix(e.Baseline)
	if !ok {
		return false
	}
	selected := map[string]bool{}
	for _, n := range x.Partitions {
		selected[n] = true
	}
	for name, options := range suffix.Parts {
		if x.Kind != "reorganizePartition" || selected[name] {
			if !physicalMySQLDefaultPartitionOptions(options, e.Engine) {
				return false
			}
		}
	}
	return true
}
