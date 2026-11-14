package mariadb

import (
	"regexp"
	"strings"
)

var mariaExtraUpdate = regexp.MustCompile(`(?i)on update current_timestamp(?:\([0-9]*\))?`)

func mariaUnmodeledExtra(extra string) string {
	extra = mariaExtraUpdate.ReplaceAllString(extra, "")
	for _, known := range []string{"STORED GENERATED", "VIRTUAL GENERATED", "auto_increment", "INVISIBLE", "WITHOUT SYSTEM VERSIONING"} {
		extra = strings.ReplaceAll(extra, known, "")
	}
	return strings.TrimSpace(extra)
}

// Keep the complete native tail opaque; this locates its outer token boundary,
// and never parses, rewrites or executes its expressions or bounds.
func mariaPartitionTail(raw, mode string) (string, bool) {
	tokens, ok := mariaIndexMetadataTokens(raw, mode, 0)
	if !ok {
		return "", false
	}
	level := 0
	opened, closed := false, false
	for i, token := range tokens {
		if token.kind == "punct" {
			switch token.value {
			case "(":
				level++
				opened = true
			case ")":
				level--
				if level < 0 {
					return "", false
				}
				if opened && level == 0 {
					closed = true
				}
			}
		}
		if closed && level == 0 && token.kind == "word" && strings.EqualFold(token.value, "PARTITION") && i+1 < len(tokens) && strings.EqualFold(tokens[i+1].value, "BY") {
			return strings.Clone(raw[token.start:]), true
		}
	}
	return "", false
}

func mariaApplicationPeriods(raw, mode string) ([]string, bool) {
	tokens, ok := mariaIndexMetadataTokens(raw, mode, 0)
	if !ok {
		return nil, false
	}
	periods := []string{}
	for i, t := range tokens {
		if t.kind != "word" || !strings.EqualFold(t.value, "PERIOD") {
			continue
		}
		if i+3 >= len(tokens) || !strings.EqualFold(tokens[i+1].value, "FOR") {
			continue
		}
		name := tokens[i+2]
		if name.kind != "word" && name.kind != "identifier" {
			return nil, false
		}
		if strings.EqualFold(name.value, "SYSTEM_TIME") {
			continue
		}
		if tokens[i+3].kind != "punct" || tokens[i+3].value != "(" {
			return nil, false
		}
		level := 0
		end := -1
		for j := i + 3; j < len(tokens); j++ {
			if tokens[j].kind == "punct" {
				if tokens[j].value == "(" {
					level++
				}
				if tokens[j].value == ")" {
					level--
					if level == 0 {
						end = tokens[j].end
						break
					}
				}
			}
		}
		if end < 0 {
			return nil, false
		}
		periods = append(periods, strings.Clone(raw[t.start:end]))
	}
	return periods, true
}
