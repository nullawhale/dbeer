package protocol

import (
	"bytes"
	"dbeer/helper/internal/schemacompare"
	"encoding/json"
)

const SchemaComparisonCapability = "schemaComparisonV1"

type SchemaSide struct {
	Connection Connection `json:"connection"`
}
type SchemaComparisonRequest struct {
	Source     *SchemaSide             `json:"source,omitempty"`
	Target     *SchemaSide             `json:"target,omitempty"`
	Mappings   *schemacompare.Mappings `json:"mappings,omitempty"`
	JobID      string                  `json:"jobId,omitempty"`
	Collection string                  `json:"collection,omitempty"`
	Offset     int64                   `json:"offset,omitempty"`
	Limit      int                     `json:"limit,omitempty"`
	MaxBytes   int                     `json:"maxBytes,omitempty"`
	ValueRef   string                  `json:"valueRef,omitempty"`
}
type SchemaComparisonResponse struct {
	JobID   string                 `json:"jobId"`
	State   string                 `json:"state"`
	Code    string                 `json:"code,omitempty"`
	Message string                 `json:"message,omitempty"`
	Summary *schemacompare.Summary `json:"summary,omitempty"`
	Page    *schemacompare.Page    `json:"page,omitempty"`
	Value   *schemacompare.Chunk   `json:"value,omitempty"`
	Export  *schemacompare.Chunk   `json:"export,omitempty"`
}

func parseSchemaComparison(raw json.RawMessage, kind string) (SchemaComparisonRequest, bool) {
	var r SchemaComparisonRequest
	var f map[string]json.RawMessage
	if json.Unmarshal(raw, &f) != nil || f == nil {
		return r, false
	}
	allowed := map[string]bool{}
	needed := []string{"jobId"}
	switch kind {
	case "schema.start":
		needed = []string{"source", "target", "mappings"}
	case "schema.status", "schema.cancel", "schema.close":
	case "schema.page":
		allowed["collection"] = true
		needed = append(needed, "collection")
		allowed["offset"] = true
		allowed["limit"] = true
		allowed["maxBytes"] = true
	case "schema.value":
		allowed["valueRef"] = true
		needed = append(needed, "valueRef")
		allowed["offset"] = true
		allowed["maxBytes"] = true
	case "schema.export":
		allowed["offset"] = true
		allowed["maxBytes"] = true
	default:
		return r, false
	}
	for _, n := range needed {
		allowed[n] = true
		if !required(f, n) {
			return r, false
		}
	}
	for n := range f {
		if !allowed[n] || !required(f, n) {
			return r, false
		}
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(&r) != nil {
		return r, false
	}
	if kind == "schema.start" {
		for _, name := range []string{"source", "target"} {
			var nested map[string]json.RawMessage
			if json.Unmarshal(f[name], &nested) != nil || len(nested) != 1 {
				return r, false
			}
			c, ok := parseConnection(nested["connection"])
			if !ok {
				return r, false
			}
			if name == "source" {
				r.Source = &SchemaSide{c}
			} else {
				r.Target = &SchemaSide{c}
			}
		}
		return r, r.Mappings != nil && r.Mappings.Valid() && r.Source.Connection.DatabaseEngine() == r.Target.Connection.DatabaseEngine() && (r.Source.Connection.DatabaseEngine() == "postgresql" || r.Source.Connection.DatabaseEngine() == "mysql")
	}
	if !ValidID(r.JobID) || r.Offset < 0 {
		return r, false
	}
	if kind == "schema.page" {
		if _, ok := f["limit"]; !ok {
			r.Limit = 100
		}
		if _, ok := f["maxBytes"]; !ok {
			r.MaxBytes = 262144
		}
		return r, (r.Collection == "differences" || r.Collection == "issues") && r.Limit >= 1 && r.Limit <= 1000 && r.MaxBytes >= 4096 && r.MaxBytes <= 1<<20
	}
	if kind == "schema.value" || kind == "schema.export" {
		if _, ok := f["maxBytes"]; !ok {
			r.MaxBytes = 65536
		}
		return r, r.MaxBytes >= 1 && r.MaxBytes <= 1<<20 && (kind != "schema.value" || ValidID(r.ValueRef))
	}
	return r, true
}
