package protocol

import (
	"bytes"
	"encoding/json"
	"strings"

	"dbeer/helper/internal/resultcompare"
)

const ResultComparisonCapability = "resultComparisonV1"

type ArtifactReference struct {
	Kind string `json:"kind"`
	ID   string `json:"id"`
}
type ComparisonRequest struct {
	Left       *ArtifactReference      `json:"left,omitempty"`
	Right      *ArtifactReference      `json:"right,omitempty"`
	Mode       string                  `json:"mode,omitempty"`
	Columns    []resultcompare.Mapping `json:"columns,omitempty"`
	JobID      string                  `json:"jobId,omitempty"`
	Offset     int64                   `json:"offset,omitempty"`
	Limit      int                     `json:"limit,omitempty"`
	MaxBytes   int                     `json:"maxBytes,omitempty"`
	CellOffset int                     `json:"cellOffset,omitempty"`
	ValueRef   string                  `json:"valueRef,omitempty"`
}
type ComparisonResponse struct {
	JobID   string                 `json:"jobId"`
	State   string                 `json:"state"`
	Message string                 `json:"message,omitempty"`
	Summary *resultcompare.Summary `json:"summary,omitempty"`
	Page    *resultcompare.Page    `json:"page,omitempty"`
	Value   *resultcompare.Value   `json:"value,omitempty"`
}

func ValidArtifactID(id string) bool {
	if len(id) != 36 {
		return false
	}
	for i, c := range id {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {
				return false
			}
		} else if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			return false
		}
	}
	return true
}
func parseComparison(raw json.RawMessage, kind string) (ComparisonRequest, bool) {
	var r ComparisonRequest
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil || fields == nil {
		return r, false
	}
	allowed := map[string]bool{}
	needed := []string{}
	switch kind {
	case "compare.start":
		allowed = map[string]bool{"left": true, "right": true, "mode": true, "columns": true}
		needed = []string{"left", "right", "mode", "columns"}
	case "compare.status", "compare.cancel", "compare.close":
		allowed["jobId"] = true
		needed = []string{"jobId"}
	case "compare.page":
		allowed = map[string]bool{"jobId": true, "offset": true, "limit": true, "maxBytes": true, "cellOffset": true}
		needed = []string{"jobId"}
	case "compare.value":
		allowed = map[string]bool{"jobId": true, "valueRef": true, "offset": true, "maxBytes": true}
		needed = []string{"jobId", "valueRef"}
	default:
		return r, false
	}
	for name := range fields {
		if !allowed[name] || !required(fields, name) {
			return r, false
		}
	}
	for _, name := range needed {
		if !required(fields, name) {
			return r, false
		}
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&r) != nil {
		return r, false
	}
	if kind == "compare.start" {
		for _, a := range []*ArtifactReference{r.Left, r.Right} {
			if a == nil || a.Kind != "snapshot" || !ValidArtifactID(a.ID) {
				return r, false
			}
		}
		if r.Mode != "key" && r.Mode != "rowOrder" || len(r.Columns) == 0 {
			return r, false
		}
		var rawColumns []map[string]json.RawMessage
		if json.Unmarshal(fields["columns"], &rawColumns) != nil {
			return r, false
		}
		left, right := map[int]bool{}, map[int]bool{}
		keys := 0
		for i, m := range r.Columns {
			f := rawColumns[i]
			if !required(f, "left") || !required(f, "right") || m.Left < 0 || m.Right < 0 || left[m.Left] || right[m.Right] {
				return r, false
			}
			for name := range f {
				if !required(f, name) {
					return r, false
				}
			}
			left[m.Left], right[m.Right] = true, true
			if m.Key {
				keys++
			}
		}
		return r, r.Mode == "key" && keys > 0 || r.Mode == "rowOrder" && keys == 0
	}
	if !ValidID(r.JobID) || strings.ContainsAny(r.JobID, "\x00\r\n") {
		return r, false
	}
	if r.Offset < 0 || r.Limit < 0 || r.Limit > 1000 || r.CellOffset < 0 {
		return r, false
	}
	if kind == "compare.page" {
		return r, r.MaxBytes == 0 || r.MaxBytes >= resultcompare.MinPageBytes && r.MaxBytes <= resultcompare.MaxPageBytes
	}
	if kind == "compare.value" {
		return r, len(r.ValueRef) > 0 && len(r.ValueRef) <= 256 && r.MaxBytes >= 0 && r.MaxBytes <= resultcompare.MaxValueBytes
	}
	return r, true
}
