package protocol

import (
	"bytes"
	"dbeer/helper/internal/schemabundle"
	"dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/syncplan"
	"dbeer/helper/internal/textdiff"
	"encoding/json"
	"reflect"
)

const SchemaComparisonCapability = "schemaComparisonV1"
const SchemaBundleCapability = "schemaBundleV1"
const SchemaBundleSourceCapability = "schemaBundleSourceV1"

type SchemaSide struct {
	Connection Connection           `json:"connection,omitempty"`
	Bundle     *schemabundle.Source `json:"bundle,omitempty"`
}

func (s SchemaSide) Engine() string {
	if s.Bundle != nil {
		return s.Bundle.Engine
	}
	return s.Connection.DatabaseEngine()
}
func (s SchemaSide) Valid() bool {
	return s.Bundle == nil || reflect.DeepEqual(s.Connection, Connection{}) && s.Bundle.Valid(false)
}
func (s SchemaSide) MarshalJSON() ([]byte, error) {
	if !s.Valid() {
		return nil, schemabundle.ErrInvalid
	}
	if s.Bundle != nil {
		return json.Marshal(struct {
			Bundle *schemabundle.Source `json:"bundle"`
		}{s.Bundle})
	}
	return json.Marshal(struct {
		Connection Connection `json:"connection"`
	}{s.Connection})
}

type SchemaComparisonRequest struct {
	Bundle      *schemabundle.Source    `json:"bundle,omitempty"`
	Schemas     []string                `json:"schemas,omitempty"`
	Source      *SchemaSide             `json:"source,omitempty"`
	Target      *SchemaSide             `json:"target,omitempty"`
	Mappings    *schemacompare.Mappings `json:"mappings,omitempty"`
	JobID       string                  `json:"jobId,omitempty"`
	Collection  string                  `json:"collection,omitempty"`
	Offset      int64                   `json:"offset,omitempty"`
	Limit       int                     `json:"limit,omitempty"`
	MaxBytes    int                     `json:"maxBytes,omitempty"`
	ValueRef    string                  `json:"valueRef,omitempty"`
	ModelDigest string                  `json:"modelDigest,omitempty"`
}
type SchemaComparisonResponse struct {
	ImportSummary *schemabundle.ImportedSource `json:"importSummary,omitempty"`
	Offset        *int64                       `json:"offset,omitempty"`
	Diff          *textdiff.Diff               `json:"diff,omitempty"`
	JobID         string                       `json:"jobId"`
	State         string                       `json:"state"`
	Code          string                       `json:"code,omitempty"`
	Message       string                       `json:"message,omitempty"`
	BundleSummary *schemabundle.Summary        `json:"bundleSummary,omitempty"`
	Summary       *schemacompare.Summary       `json:"summary,omitempty"`
	Page          *schemacompare.Page          `json:"page,omitempty"`
	Value         *schemacompare.Chunk         `json:"value,omitempty"`
	Export        *schemacompare.Chunk         `json:"export,omitempty"`
	Plan          *syncplan.Plan               `json:"plan,omitempty"`
}

func parseSchemaComparison(raw json.RawMessage, kind string) (SchemaComparisonRequest, bool) {
	var r SchemaComparisonRequest
	var f map[string]json.RawMessage
	if !JSONUnicodeValid(raw) || json.Unmarshal(raw, &f) != nil || f == nil {
		return r, false
	}
	allowed := map[string]bool{}
	needed := []string{"jobId"}
	switch kind {
	case "schema.import.start":
		needed = []string{"bundle"}
	case "schema.bundle.start":
		needed = []string{"source", "schemas"}
	case "schema.start":
		needed = []string{"source", "target", "mappings"}
	case "schema.status", "schema.cancel", "schema.close", "schema.bundle.status", "schema.bundle.cancel", "schema.bundle.close", "schema.import.status", "schema.import.cancel", "schema.import.close":
	case "schema.plan":
		needed = append(needed, "modelDigest")
	case "schema.diff":
		allowed["offset"] = true
	case "schema.page":
		allowed["collection"] = true
		needed = append(needed, "collection")
		allowed["offset"] = true
		allowed["limit"] = true
		allowed["maxBytes"] = true
	case "schema.value", "schema.bundle.export":
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
	if kind == "schema.import.start" {
		return r, r.Bundle != nil && r.Bundle.Valid(true)
	}
	if kind == "schema.start" || kind == "schema.bundle.start" {
		names := []string{"source", "target"}
		if kind == "schema.bundle.start" {
			names = names[:1]
		}
		for _, name := range names {
			var nested map[string]json.RawMessage
			if json.Unmarshal(f[name], &nested) != nil || len(nested) != 1 {
				return r, false
			}
			var side SchemaSide
			if value, ok := nested["connection"]; ok {
				c, ok := parseConnection(value)
				if !ok {
					return r, false
				}
				side.Connection = c
			} else if value, ok := nested["bundle"]; ok && kind == "schema.start" {
				var bundle schemabundle.Source
				if json.Unmarshal(value, &bundle) != nil || !bundle.Valid(false) {
					return r, false
				}
				side.Bundle = &bundle
			} else {
				return r, false
			}
			if name == "source" {
				r.Source = &side
			} else {
				r.Target = &side
			}
		}
		if kind == "schema.bundle.start" {
			return r, r.Source != nil && schemabundle.SchemasValid(r.Source.Connection.DatabaseEngine(), r.Schemas)
		}
		return r, r.Mappings != nil && r.Mappings.Valid() && r.Source.Valid() && r.Target.Valid() && r.Source.Engine() == r.Target.Engine()
	}
	if !ValidID(r.JobID) || r.Offset < 0 {
		return r, false
	}
	if kind == "schema.plan" {
		return r, syncplan.DigestValid(r.ModelDigest)
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
	if kind == "schema.value" || kind == "schema.export" || kind == "schema.bundle.export" {
		if _, ok := f["maxBytes"]; !ok {
			r.MaxBytes = 65536
		}
		return r, r.MaxBytes >= 1 && r.MaxBytes <= 1<<20 && (kind == "schema.export" || kind == "schema.value" && ValidID(r.ValueRef) || kind == "schema.bundle.export" && (r.ValueRef == "manifest" || r.ValueRef == "capture" || syncplan.DigestValid(r.ValueRef)))
	}
	return r, true
}
