package protocol

import (
	"encoding/json"
	"errors"
	"math"
	"strconv"
)

const SQLiteRelationshipBrowseCapability = "sqliteRelationshipBrowseV1"

type SQLiteRelationshipPair struct {
	Source   string      `json:"source"`
	Target   string      `json:"target"`
	Position int         `json:"position"`
	Value    SQLiteValue `json:"value"`
}

// SQLiteRelationshipScope is a declared FK predicate, not an ordinary child
// equality filter. Values are the selected parent's authoritative storage.
type SQLiteRelationshipScope struct {
	Child   CatalogRelationTarget    `json:"child"`
	Parent  CatalogRelationTarget    `json:"parent"`
	Name    string                   `json:"name"`
	Columns []SQLiteRelationshipPair `json:"columns"`
}

func (s SQLiteRelationshipScope) Valid() bool {
	if !s.Child.Valid() || !s.Parent.Valid() || s.Child.Schema != "main" || s.Parent.Schema != "main" ||
		!(CatalogRelationTarget{Schema: "main", Name: s.Name}).Valid() || len(s.Columns) == 0 || len(s.Columns) > 32 {
		return false
	}
	source, target := map[string]bool{}, map[string]bool{}
	bytes := 0
	for i, p := range s.Columns {
		if p.Position != i+1 || !(CatalogRelationTarget{Schema: p.Source, Name: p.Target}).Valid() || source[p.Source] || target[p.Target] ||
			!p.Value.Valid() || p.Value.Type == "null" || len(p.Value.Value) > 1024*1024 {
			return false
		}
		if p.Value.Type == "real" {
			bits, e := strconv.ParseUint(p.Value.Value, 16, 64)
			if e != nil || math.IsNaN(math.Float64frombits(bits)) {
				return false
			}
		}
		source[p.Source], target[p.Target] = true, true
		bytes += len(p.Value.Value)
	}
	return bytes <= 4*1024*1024
}

func (s *SQLiteRelationshipScope) UnmarshalJSON(data []byte) error {
	if !uniqueObjectKeys(data) {
		return errors.New("invalid relationship scope")
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(data, &fields) != nil || len(fields) != 4 {
		return errors.New("invalid relationship scope")
	}
	for _, name := range []string{"child", "parent", "name", "columns"} {
		if !required(fields, name) {
			return errors.New("invalid relationship scope")
		}
	}
	var pairs []map[string]json.RawMessage
	if json.Unmarshal(fields["columns"], &pairs) != nil {
		return errors.New("invalid relationship scope")
	}
	for _, p := range pairs {
		if len(p) != 4 {
			return errors.New("invalid relationship pair")
		}
		for _, name := range []string{"source", "target", "position", "value"} {
			if !required(p, name) {
				return errors.New("invalid relationship pair")
			}
		}
		var storage map[string]json.RawMessage
		if json.Unmarshal(p["value"], &storage) != nil {
			return errors.New("invalid relationship value")
		}
		if !required(storage, "type") {
			return errors.New("invalid relationship value")
		}
		for key := range storage {
			if !required(storage, key) || key != "type" && key != "value" {
				return errors.New("invalid relationship value")
			}
		}
	}
	type plain SQLiteRelationshipScope
	var value plain
	if json.Unmarshal(data, &value) != nil || !SQLiteRelationshipScope(value).Valid() {
		return errors.New("invalid relationship scope")
	}
	*s = SQLiteRelationshipScope(value)
	return nil
}
