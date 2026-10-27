// Package mongoscript parses the bounded, non-JavaScript MongoDB editor format.
// Safety assessment and execution share this parser so they cannot disagree.
package mongoscript

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"unicode/utf8"

	"go.mongodb.org/mongo-driver/v2/bson"
)

var ErrInvalid = errors.New("Use one MongoDB JSON object with collection and either find or aggregate; JavaScript is unsupported")

type Script struct {
	Database, Collection     string
	Filter, Sort, Projection bson.D
	Pipeline                 []bson.D
	Limit                    int64
	Aggregate, Write         bool
}

// Parse retains BSON scalar widths, ordered documents and sort precedence.
// Duplicate keys and executable JavaScript operators are rejected at all depths.
func Parse(text string) (Script, error) {
	var s Script
	if len(text) > 2<<20 || !utf8.ValidString(text) || !uniqueJSON([]byte(text)) {
		return s, ErrInvalid
	}
	var doc bson.D
	if bson.UnmarshalExtJSON([]byte(text), false, &doc) != nil {
		return s, ErrInvalid
	}
	find, aggregate := false, false
	for _, e := range doc {
		switch e.Key {
		case "database":
			s.Database, _ = e.Value.(string)
			if !ValidName(s.Database) {
				return s, ErrInvalid
			}
		case "collection":
			s.Collection, _ = e.Value.(string)
		case "find":
			var ok bool
			s.Filter, ok = e.Value.(bson.D)
			if !ok {
				return s, ErrInvalid
			}
			find = true
		case "sort":
			var ok bool
			s.Sort, ok = e.Value.(bson.D)
			if !ok || !validSort(s.Sort) {
				return s, ErrInvalid
			}
		case "projection":
			var ok bool
			s.Projection, ok = e.Value.(bson.D)
			if !ok {
				return s, ErrInvalid
			}
		case "limit":
			switch n := e.Value.(type) {
			case int32:
				s.Limit = int64(n)
			case int64:
				s.Limit = n
			default:
				return s, ErrInvalid
			}
			if s.Limit < 1 || s.Limit > 1_000_000 {
				return s, ErrInvalid
			}
		case "aggregate":
			stages, ok := e.Value.(bson.A)
			if !ok || len(stages) > 256 {
				return s, ErrInvalid
			}
			for _, stage := range stages {
				d, ok := stage.(bson.D)
				if !ok || len(d) != 1 {
					return s, ErrInvalid
				}
				s.Pipeline = append(s.Pipeline, d)
			}
			aggregate = true
		default:
			return s, ErrInvalid
		}
	}
	if !ValidName(s.Collection) || find == aggregate || aggregate && (s.Sort != nil || s.Projection != nil || s.Limit != 0) || !safeValue(doc, 0) {
		return s, ErrInvalid
	}
	s.Aggregate = aggregate
	if aggregate {
		for i, stage := range s.Pipeline {
			switch stage[0].Key {
			case "$out", "$merge":
				if i != len(s.Pipeline)-1 {
					return s, ErrInvalid
				}
				s.Write = true
			default:
				if !readStage(stage[0].Key) || !safeStage(stage, 0) {
					return s, ErrInvalid
				}
			}
		}
	}
	return s, nil
}

func ValidName(name string) bool {
	return name != "" && len(name) <= 1024 && utf8.ValidString(name) && !strings.ContainsRune(name, 0)
}

// Value validates the same JSON/Extended JSON grammar as editor scripts, while
// preserving exact scalar widths for generated browse filters.
func Value(text string) (any, error) {
	if len(text) > 1<<20 || !utf8.ValidString(text) || !uniqueJSON([]byte(text)) {
		return nil, ErrInvalid
	}
	var doc bson.D
	if bson.UnmarshalExtJSON([]byte(`{"value":`+text+`}`), false, &doc) != nil || len(doc) != 1 {
		return nil, ErrInvalid
	}
	return doc[0].Value, nil
}

func validSort(sort bson.D) bool {
	if len(sort) > 32 {
		return false
	}
	for _, e := range sort {
		if !ValidName(e.Key) {
			return false
		}
		switch n := e.Value.(type) {
		case int32:
			if n != 1 && n != -1 {
				return false
			}
		case int64:
			if n != 1 && n != -1 {
				return false
			}
		default:
			return false
		}
	}
	return true
}

func readStage(name string) bool {
	switch name {
	case "$addFields", "$bucket", "$bucketAuto", "$collStats", "$count", "$densify", "$documents", "$facet", "$fill", "$geoNear", "$graphLookup", "$group", "$indexStats", "$limit", "$lookup", "$match", "$project", "$redact", "$replaceRoot", "$replaceWith", "$sample", "$set", "$setWindowFields", "$skip", "$sort", "$sortByCount", "$unionWith", "$unset", "$unwind":
		return true
	}
	return false
}

// Only actual aggregation sub-pipelines are interpreted as stages. A document
// field named pipeline remains ordinary data in filters and literal objects.
func safeStage(stage bson.D, depth int) bool {
	if depth > 32 {
		return false
	}
	nested := func(value any) bool {
		stages, ok := value.(bson.A)
		if !ok || len(stages) > 256 {
			return false
		}
		for _, value := range stages {
			d, ok := value.(bson.D)
			if !ok || len(d) != 1 || !readStage(d[0].Key) || !safeStage(d, depth+1) {
				return false
			}
		}
		return true
	}
	switch stage[0].Key {
	case "$facet":
		facets, ok := stage[0].Value.(bson.D)
		if !ok {
			return false
		}
		for _, facet := range facets {
			if !nested(facet.Value) {
				return false
			}
		}
	case "$lookup", "$unionWith":
		if fields, ok := stage[0].Value.(bson.D); ok {
			for _, field := range fields {
				if field.Key == "pipeline" && !nested(field.Value) {
					return false
				}
			}
		}
	}
	return true
}

func safeValue(value any, depth int) bool {
	if depth > 64 {
		return false
	}
	switch v := value.(type) {
	case bson.D:
		for _, e := range v {
			switch e.Key {
			case "$where", "$function", "$accumulator", "$eval", "$changeStream":
				return false
			}
			if !safeValue(e.Value, depth+1) {
				return false
			}
		}
	case bson.A:
		for _, e := range v {
			if !safeValue(e, depth+1) {
				return false
			}
		}
	case bson.JavaScript, bson.CodeWithScope:
		return false
	}
	return true
}

func uniqueJSON(data []byte) bool {
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	var value func(int) bool
	value = func(depth int) bool {
		if depth > 64 {
			return false
		}
		t, err := d.Token()
		if err != nil {
			return false
		}
		if delimiter, ok := t.(json.Delim); ok {
			switch delimiter {
			case '{':
				keys := map[string]bool{}
				for d.More() {
					t, err := d.Token()
					key, ok := t.(string)
					if err != nil || !ok || keys[key] {
						return false
					}
					keys[key] = true
					if !value(depth + 1) {
						return false
					}
				}
				t, err = d.Token()
				return err == nil && t == json.Delim('}')
			case '[':
				for d.More() {
					if !value(depth + 1) {
						return false
					}
				}
				t, err = d.Token()
				return err == nil && t == json.Delim(']')
			default:
				return false
			}
		}
		return true
	}
	if !value(0) {
		return false
	}
	_, err := d.Token()
	return errors.Is(err, io.EOF)
}
