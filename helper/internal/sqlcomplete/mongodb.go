package sqlcomplete

import (
	"encoding/json"
	"sort"
	"strings"
	"unicode/utf8"
)

type mongoToken struct {
	value      string
	start, end int
	quoted     bool
}

// mongoTokens is an unfinished-JSON scanner, never a JavaScript evaluator.
func mongoTokens(text string) []mongoToken {
	var tokens []mongoToken
	for i := 0; i < len(text); {
		if len(tokens) >= 100_000 {
			return nil
		}
		if strings.ContainsRune(" \t\r\n", rune(text[i])) {
			i++
			continue
		}
		start := i
		if text[i] == '"' {
			i++
			for i < len(text) {
				if text[i] == '\\' {
					i += min(2, len(text)-i)
					continue
				}
				if text[i] == '"' {
					i++
					break
				}
				i++
			}
			var value string
			if json.Unmarshal([]byte(text[start:i]), &value) != nil {
				_ = json.Unmarshal([]byte(text[start:i]+`"`), &value)
			}
			tokens = append(tokens, mongoToken{value, start, i, true})
		} else if strings.ContainsRune("{}[]:,", rune(text[i])) {
			i++
			tokens = append(tokens, mongoToken{text[start:i], start, i, false})
		} else {
			for i < len(text) && !strings.ContainsRune(" \t\r\n{}[]:,\"", rune(text[i])) {
				i++
			}
			tokens = append(tokens, mongoToken{text[start:i], start, i, false})
		}
	}
	return tokens
}

func mongoComplete(text string, offset int, context Context) []Item {
	if offset < 0 || offset > len(text) || len(text) > 2<<20 || !utf8.ValidString(text) || offset < len(text) && !utf8.RuneStart(text[offset]) {
		return []Item{}
	}
	tokens := mongoTokens(text)
	if tokens == nil && len(text) > 0 {
		return []Item{}
	}
	start, end, prefix := offset, offset, ""
	before := []mongoToken{}
	for _, t := range tokens {
		if offset > t.start && offset <= t.end && (t.quoted || !strings.Contains("{}[]:,", t.value)) {
			start, end = t.start, t.end
			prefix = strings.TrimPrefix(text[start:offset], `"`)
			prefix = strings.TrimSuffix(prefix, `"`)
			break
		}
		if t.end <= offset {
			before = append(before, t)
		}
	}
	if len(prefix) > 1024 {
		return []Item{}
	}
	last := ""
	if len(before) > 0 {
		last = before[len(before)-1].value
	}
	valueKey := ""
	if last == ":" && len(before) >= 2 {
		valueKey = before[len(before)-2].value
	}
	collection, database := "", ""
	for i := 0; i+2 < len(tokens); i++ {
		if tokens[i+1].value != ":" || !tokens[i+2].quoted {
			continue
		}
		if tokens[i].value == "collection" {
			collection = tokens[i+2].value
		}
		if tokens[i].value == "database" {
			database = tokens[i+2].value
		}
	}
	r := &request{text: text, start: start, end: end, prefix: prefix, context: context, seen: map[string]bool{}, matcher: newNameMatcher(prefix), items: []Item{}}
	quote := func(value string) string { encoded, _ := json.Marshal(value); return string(encoded) }
	next := strings.TrimSpace(text[end:])
	hasColon := strings.HasPrefix(next, ":")
	addKey := func(name, initial, detail string, kind int) {
		insertion := quote(name)
		if !hasColon {
			insertion += ": " + initial
		}
		r.add(name, insertion, detail, kind, 0)
	}
	if valueKey == "collection" || valueKey == "database" {
		for _, relation := range context.Catalog {
			if valueKey == "database" {
				r.add(relation.Schema, quote(relation.Schema), "MongoDB database", 9, 0)
			} else if database == "" || database == relation.Schema {
				r.add(relation.Name, quote(relation.Name), "Collection · "+relation.Schema, 7, 0)
			}
		}
	} else if valueKey == "$type" {
		for _, name := range strings.Fields("double string object array binData undefined objectId bool date null regex dbPointer javascript symbol javascriptWithScope int timestamp long decimal minKey maxKey number") {
			r.add(name, quote(name), "BSON type", 13, 0)
		}
	} else if valueKey != "" {
		if strings.HasPrefix(prefix, "$") {
			for _, relation := range context.Catalog {
				if collection != "" && relation.Name != collection || database != "" && relation.Schema != database {
					continue
				}
				for _, name := range relation.Columns {
					r.add("$"+name, quote("$"+name), "Sampled document field", 5, 0)
				}
			}
		}
	} else {
		depth := 0
		for _, t := range before {
			if t.value == "{" || t.value == "[" {
				depth++
			}
			if t.value == "}" || t.value == "]" {
				depth--
			}
		}
		if depth <= 1 {
			for _, entry := range [][2]string{{"database", `"database"`}, {"collection", `"collection"`}, {"find", "{}"}, {"aggregate", "[]"}, {"sort", "{}"}, {"projection", "{}"}, {"limit", "1000"}} {
				addKey(entry[0], entry[1], "MongoDB request", 10)
			}
		} else {
			for _, relation := range context.Catalog {
				if collection != "" && relation.Name != collection || database != "" && relation.Schema != database {
					continue
				}
				for _, name := range relation.Columns {
					addKey(name, "null", "Sampled field · "+relation.Name, 5)
				}
			}
			for _, entry := range [][2]string{
				{"$match", "{}"}, {"$project", "{}"}, {"$sort", "{}"}, {"$limit", "1000"}, {"$skip", "0"}, {"$group", `{"_id": null}`}, {"$unwind", `"$field"`}, {"$lookup", "{}"}, {"$facet", "{}"}, {"$addFields", "{}"}, {"$set", "{}"}, {"$unset", `"field"`}, {"$count", `"count"`}, {"$replaceRoot", "{}"}, {"$replaceWith", `"$field"`}, {"$sample", `{"size": 10}`}, {"$unionWith", `"collection"`}, {"$sortByCount", `"$field"`}, {"$out", `"collection"`}, {"$merge", `"collection"`},
				{"$eq", "null"}, {"$ne", "null"}, {"$gt", "0"}, {"$gte", "0"}, {"$lt", "0"}, {"$lte", "0"}, {"$in", "[]"}, {"$nin", "[]"}, {"$and", "[]"}, {"$or", "[]"}, {"$nor", "[]"}, {"$not", "{}"}, {"$exists", "true"}, {"$type", `"string"`}, {"$regex", `"pattern"`}, {"$elemMatch", "{}"}, {"$all", "[]"}, {"$size", "0"}, {"$expr", "{}"}, {"$sum", "1"}, {"$avg", `"$field"`}, {"$min", `"$field"`}, {"$max", `"$field"`}, {"$push", `"$field"`}, {"$first", `"$field"`}, {"$last", `"$field"`}, {"$cond", "[]"}, {"$ifNull", "[]"}, {"$literal", "null"}, {"$toString", `"$field"`}, {"$convert", "{}"},
				{"$oid", `"507f1f77bcf86cd799439011"`}, {"$numberInt", `"0"`}, {"$numberLong", `"0"`}, {"$numberDouble", `"0.0"`}, {"$numberDecimal", `"0.00"`}, {"$date", `{"$numberLong": "0"}`}, {"$binary", `{"base64": "", "subType": "00"}`}, {"$timestamp", `{"t": 0, "i": 0}`}, {"$regularExpression", `{"pattern": "", "options": ""}`}, {"$minKey", "1"}, {"$maxKey", "1"},
			} {
				detail := "MongoDB operator"
				if entry[0] == "$out" || entry[0] == "$merge" {
					detail = "Output stage · writes to a collection"
				}
				addKey(entry[0], entry[1], detail, 14)
			}
		}
	}
	sort.SliceStable(r.items, func(i, j int) bool { return lessCompletion(r.items[i], r.items[j]) })
	if len(r.items) > 256 {
		r.items = r.items[:256]
	}
	for i := range r.items {
		r.items[i].Matches = r.matcher.spans(r.items[i].Label)
	}
	return r.items
}
