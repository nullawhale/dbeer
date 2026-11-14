package mariadb

import (
	"dbeer/helper/internal/tableedit"
	"strings"
)

type mariaIndexMetadataToken struct {
	kind, value string
	start, end  int
}

// SHOW CREATE is metadata evidence only. Executable version comments are read,
// strings/identifiers stay distinct, and unrecognized tails remain unavailable.
func mariaIndexMetadataTokens(raw, mode string, depth int) ([]mariaIndexMetadataToken, bool) {
	if len(raw) > tableedit.MaxSQLBytes || depth > 2 {
		return nil, false
	}
	noBackslash, ansi := false, false
	for _, m := range strings.Split(mode, ",") {
		noBackslash = noBackslash || m == "NO_BACKSLASH_ESCAPES"
		ansi = ansi || m == "ANSI_QUOTES"
	}
	var out []mariaIndexMetadataToken
	for i := 0; i < len(raw); {
		if len(out) > 16384 {
			return nil, false
		}
		c := raw[i]
		if c == ' ' || c == '\n' || c == '\t' || c == '\r' {
			i++
			continue
		}
		if c == '#' || c == '-' && i+1 < len(raw) && raw[i+1] == '-' && (i+2 == len(raw) || raw[i+2] <= ' ') {
			for i < len(raw) && raw[i] != '\n' {
				i++
			}
			continue
		}
		if c == '/' && i+1 < len(raw) && raw[i+1] == '*' {
			end := strings.Index(raw[i+2:], "*/")
			if end < 0 {
				return nil, false
			}
			end += i + 2
			if i+2 < len(raw) && (raw[i+2] == '!' || i+3 < len(raw) && raw[i+2] == 'M' && raw[i+3] == '!') {
				start := i + 3
				if raw[i+2] == 'M' {
					start++
				}
				for start < end && raw[start] >= '0' && raw[start] <= '9' {
					start++
				}
				tokens, ok := mariaIndexMetadataTokens(raw[start:end], mode, depth+1)
				if !ok {
					return nil, false
				}
				for j := range tokens {
					tokens[j].start += start
					tokens[j].end += start
				}
				out = append(out, tokens...)
			}
			i = end + 2
			continue
		}
		if c == '\'' || c == '"' || c == '`' {
			start, quote := i, c
			identifier := quote == '`' || quote == '"' && ansi
			i++
			var value strings.Builder
			closed := false
			for i < len(raw) {
				c = raw[i]
				i++
				if c == '\\' && !identifier && !noBackslash {
					if i == len(raw) {
						return nil, false
					}
					value.WriteByte(raw[i])
					i++
					continue
				}
				if c == quote {
					if i < len(raw) && raw[i] == quote {
						value.WriteByte(c)
						i++
						continue
					}
					closed = true
					break
				}
				value.WriteByte(c)
			}
			if !closed {
				return nil, false
			}
			kind := "string"
			if identifier {
				kind = "identifier"
			}
			out = append(out, mariaIndexMetadataToken{kind: kind, value: value.String(), start: start, end: i})
			continue
		}
		if c == '_' || c == '$' || c >= 128 || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' {
			start := i
			i++
			for i < len(raw) {
				c = raw[i]
				if !(c == '_' || c == '$' || c >= 128 || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') {
					break
				}
				i++
			}
			out = append(out, mariaIndexMetadataToken{kind: "word", value: raw[start:i], start: start, end: i})
			continue
		}
		out = append(out, mariaIndexMetadataToken{kind: "punct", value: string(c), start: i, end: i + 1})
		i++
	}
	return out, true
}
func mariaIndexAttributeEvidence(raw, mode string) (map[string]map[string]string, map[string]bool, bool) {
	tokens, ok := mariaIndexMetadataTokens(raw, mode, 0)
	if !ok {
		return nil, nil, false
	}
	open := -1
	for i, t := range tokens {
		if t.kind == "punct" && t.value == "(" {
			open = i
			break
		}
	}
	if open < 0 {
		return nil, nil, false
	}
	type metadataClause struct {
		tokens     []mariaIndexMetadataToken
		start, end int
	}
	var clauses []metadataClause
	start, level := open+1, 1
	startOffset := tokens[open].end
	closed := false
	for i := start; i < len(tokens); i++ {
		t := tokens[i]
		if t.kind != "punct" {
			continue
		}
		if t.value == "(" {
			level++
		}
		if t.value == ")" {
			level--
			if level == 0 {
				clauses = append(clauses, metadataClause{tokens: tokens[start:i], start: startOffset, end: t.start})
				closed = true
				break
			}
		}
		if t.value == "," && level == 1 {
			clauses = append(clauses, metadataClause{tokens: tokens[start:i], start: startOffset, end: t.start})
			start = i + 1
			startOffset = t.end
		}
	}
	if !closed {
		return nil, nil, false
	}
	known := map[string]bool{}
	var attrs map[string]map[string]string
	word := func(t mariaIndexMetadataToken, value string) bool {
		return t.kind == "word" && strings.EqualFold(t.value, value)
	}
	for _, record := range clauses {
		clause := record.tokens
		if len(clause) < 3 || clause[0].kind != "word" {
			continue
		}
		i := 0
		name := ""
		if word(clause[i], "PRIMARY") {
			if !word(clause[1], "KEY") {
				continue
			}
			name = "PRIMARY"
			i = 2
		} else {
			if word(clause[i], "UNIQUE") || word(clause[i], "FULLTEXT") || word(clause[i], "SPATIAL") {
				i++
			}
			if i >= len(clause) || !word(clause[i], "KEY") && !word(clause[i], "INDEX") {
				continue
			}
			i++
			if i >= len(clause) || clause[i].kind != "identifier" && clause[i].kind != "word" {
				return nil, nil, false
			}
			name = clause[i].value
			i++
		}
		if known[name] {
			return nil, nil, false
		}
		known[name] = true
		if i+1 < len(clause) && word(clause[i], "USING") {
			i += 2
		}
		if i >= len(clause) || clause[i].value != "(" {
			return nil, nil, false
		}
		level := 0
		for ; i < len(clause); i++ {
			if clause[i].kind == "punct" {
				if clause[i].value == "(" {
					level++
				}
				if clause[i].value == ")" {
					level--
					if level == 0 {
						i++
						break
					}
				}
			}
		}
		if level != 0 {
			return nil, nil, false
		}
		reason := ""
		for i < len(clause) {
			if word(clause[i], "USING") && i+1 < len(clause) && (word(clause[i+1], "BTREE") || word(clause[i+1], "HASH")) {
				i += 2
				continue
			}
			if word(clause[i], "COMMENT") && i+1 < len(clause) && clause[i+1].kind == "string" {
				i += 2
				continue
			}
			if word(clause[i], "IGNORED") || word(clause[i], "NOT_IGNORED") {
				i++
				continue
			}
			if word(clause[i], "WITH") && i+1 < len(clause) && word(clause[i+1], "PARSER") {
				reason = "FULLTEXT parser"
			} else if word(clause[i], "ENGINE_ATTRIBUTE") || word(clause[i], "SECONDARY_ENGINE_ATTRIBUTE") {
				reason = "index engine attributes"
			} else if word(clause[i], "KEY_BLOCK_SIZE") {
				reason = "index key block size"
			} else {
				reason = "unrecognized index options"
			}
			break
		}
		if reason != "" {
			if attrs == nil {
				attrs = map[string]map[string]string{}
			}
			begin, end := record.start, record.end
			if begin < 0 || end > len(raw) || end < begin {
				return nil, nil, false
			}
			attrs[name] = map[string]string{"reason": reason, "definition": strings.TrimSpace(raw[begin:end])}
		}
	}
	return attrs, known, true
}
