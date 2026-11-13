package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"time"
	"unicode/utf8"
)

const CatalogMetadataCapability = "catalogMetadataV1"
const IncomingRelationsCapability = "incomingRelationsV1"
const CatalogMetadataPageRows = 200
const CatalogMetadataMaxPageRows = 1000
const CatalogMetadataMaxBatch = 32

func validMetadataID(value string) bool {
	return ValidID(value) && !strings.ContainsAny(value, "\x00\r\n\t ")
}

// Selectors retain the exact legacy identifier semantics. Continuations belong
// to immutable observations and never represent offsets into a live catalog.
type CatalogMetadataRequest struct {
	Selectors  []CatalogRequest `json:"selectors"`
	Cursor     string           `json:"cursor,omitempty"`
	PageSize   int              `json:"pageSize,omitempty"`
	CaptureIDs []string         `json:"captureIds,omitempty"`
}

func MetadataSelectorValid(r CatalogRequest) bool {
	if !r.Valid() || r.Page != 0 || r.Cursor != "" || r.TypeChange != nil {
		return false
	}
	switch r.Kind {
	case "schemas", "objects", "search", "columns", "foreignKeys", "referencingTables", "keys", "indexes", "constraints", "triggers":
		return true
	default:
		return false
	}
}

func (r CatalogMetadataRequest) Valid(kind string) bool {
	if kind == "catalog.close" {
		if len(r.Selectors) != 0 || r.Cursor != "" || r.PageSize != 0 || len(r.CaptureIDs) == 0 || len(r.CaptureIDs) > CatalogMetadataMaxBatch {
			return false
		}
		for _, id := range r.CaptureIDs {
			if !validMetadataID(id) {
				return false
			}
		}
		return true
	}
	if len(r.CaptureIDs) != 0 {
		return false
	}
	if len(r.Selectors) == 0 || len(r.Selectors) > CatalogMetadataMaxBatch || r.PageSize < 0 || r.PageSize > CatalogMetadataMaxPageRows {
		return false
	}
	if kind == "catalog.page" && len(r.Selectors) != 1 || kind == "catalog.batch" && r.Cursor != "" {
		return false
	}
	if kind != "catalog.page" && kind != "catalog.batch" {
		return false
	}
	if r.Cursor != "" && !validMetadataID(r.Cursor) {
		return false
	}
	for i, selector := range r.Selectors {
		if !MetadataSelectorValid(selector) {
			return false
		}
		for _, previous := range r.Selectors[:i] {
			if reflect.DeepEqual(previous, selector) {
				return false
			}
		}
	}
	return true
}

func parseCatalogMetadata(raw json.RawMessage, kind string) (*CatalogMetadataRequest, bool) {
	var all map[string]json.RawMessage
	if json.Unmarshal(raw, &all) != nil || all == nil {
		return nil, false
	}
	for name, value := range all {
		if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return nil, false
		}
		if kind == "catalog.close" && name != "captureIds" {
			return nil, false
		}
		if kind != "catalog.close" && name != "selectors" && name != "cursor" && name != "pageSize" {
			return nil, false
		}
	}
	var request CatalogMetadataRequest
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) || decoder.Decode(&request) != nil || !request.Valid(kind) {
		return nil, false
	}
	var fields struct {
		Selectors []json.RawMessage `json:"selectors"`
	}
	if json.Unmarshal(raw, &fields) != nil {
		return nil, false
	}
	for _, selector := range fields.Selectors {
		var selectorFields map[string]json.RawMessage
		if json.Unmarshal(selector, &selectorFields) != nil || selectorFields == nil {
			return nil, false
		}
		for name, value := range selectorFields {
			if name != "kind" && name != "schema" && name != "object" && name != "objectKind" && name != "identity" && name != "search" {
				return nil, false
			}
			if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
				return nil, false
			}
		}
		if _, ok := parseCatalog(selector); !ok {
			return nil, false
		}
	}
	return &request, true
}

// CatalogRelationTarget is an exact server-resolved identifier, not SQL text.
// Only referencingTables observations carry this descriptor.
type CatalogRelationTarget struct {
	Schema string `json:"schema"`
	Name   string `json:"name"`
}

func (t CatalogRelationTarget) Valid() bool {
	for _, value := range []string{t.Schema, t.Name} {
		if value == "" || len(value) > 1024 || !utf8.ValidString(value) || strings.ContainsRune(value, 0) {
			return false
		}
	}
	return true
}

func (t *CatalogRelationTarget) UnmarshalJSON(data []byte) error {
	var fields map[string]json.RawMessage
	if json.Unmarshal(data, &fields) != nil || len(fields) != 2 {
		return errors.New("invalid catalog target")
	}
	for key, raw := range fields {
		if key != "schema" && key != "name" || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
			return errors.New("invalid catalog target")
		}
	}
	type plain CatalogRelationTarget
	var value plain
	if json.Unmarshal(data, &value) != nil || !CatalogRelationTarget(value).Valid() {
		return errors.New("invalid catalog target")
	}
	*t = CatalogRelationTarget(value)
	return nil
}

type CatalogMetadataCollection struct {
	Target      *CatalogRelationTarget `json:"target,omitempty"`
	Selector    CatalogRequest         `json:"selector"`
	CaptureID   string                 `json:"captureId"`
	ObservedAt  string                 `json:"observedAt"`
	Consistency string                 `json:"consistency"`
	State       string                 `json:"state"`
	Columns     []Column               `json:"columns"`
	Rows        [][]*string            `json:"rows"`
	NextCursor  string                 `json:"nextCursor,omitempty"`
	Issue       string                 `json:"issue,omitempty"`
}

func (c *CatalogMetadataCollection) UnmarshalJSON(data []byte) error {
	var fields map[string]json.RawMessage
	if json.Unmarshal(data, &fields) != nil {
		return errors.New("invalid metadata collection")
	}
	allowed := map[string]bool{"selector": true, "captureId": true, "observedAt": true, "consistency": true, "state": true, "columns": true, "rows": true, "nextCursor": true, "issue": true, "target": true}
	for key, raw := range fields {
		if !allowed[key] || key == "target" && bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
			return errors.New("invalid metadata collection")
		}
	}
	type plain CatalogMetadataCollection
	var value plain
	if json.Unmarshal(data, &value) != nil {
		return errors.New("invalid metadata collection")
	}
	if _, present := fields["target"]; present && value.Selector.Kind != "referencingTables" {
		return errors.New("unexpected catalog target")
	}
	*c = CatalogMetadataCollection(value)
	return nil
}

type CatalogMetadataReply struct {
	Collections []CatalogMetadataCollection `json:"collections"`
	Closed      bool                        `json:"closed,omitempty"`
}

func (r CatalogMetadataReply) Valid() bool {
	if r.Closed {
		return len(r.Collections) == 0
	}
	if len(r.Collections) == 0 || len(r.Collections) > CatalogMetadataMaxBatch {
		return false
	}
	for _, c := range r.Collections {
		if !MetadataSelectorValid(c.Selector) || !validMetadataID(c.CaptureID) || len(c.Columns) > 64 || len(c.Rows) > CatalogMetadataMaxPageRows+32 || len(c.Issue) > 4096 || strings.ContainsRune(c.Issue, 0) {
			return false
		}
		if _, err := time.Parse(time.RFC3339Nano, c.ObservedAt); err != nil || !monitorTimestamp.MatchString(c.ObservedAt) {
			return false
		}
		if c.Consistency != "repeatableRead" && c.Consistency != "schemaVersion" && c.Consistency != "bestEffort" {
			return false
		}
		if c.State != "complete" && c.State != "partial" && c.State != "unavailable" && c.State != "stale" {
			return false
		}
		if c.Selector.Kind == "referencingTables" {
			if c.Target != nil && !c.Target.Valid() || c.Target == nil && c.State != "unavailable" && c.State != "stale" {
				return false
			}
			if (c.State == "unavailable" || c.State == "stale") && c.Target != nil {
				return false
			}
		} else if c.Target != nil {
			return false
		}
		if c.NextCursor != "" && (!validMetadataID(c.NextCursor) || c.State == "unavailable" || c.State == "stale") {
			return false
		}
		if c.State != "complete" && c.Issue == "" {
			return false
		}
		seenColumns := map[string]bool{}
		for i, column := range c.Columns {
			if column.Index != i || column.Name == "" || seenColumns[column.Name] {
				return false
			}
			seenColumns[column.Name] = true
		}
		for _, row := range c.Rows {
			if len(row) != len(c.Columns) {
				return false
			}
		}
	}
	return true
}
