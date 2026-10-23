package protocol

import (
	"bytes"
	"dbeer/helper/internal/resultcompare"
	tc "dbeer/helper/internal/tablecapture"
	"dbeer/helper/internal/textdiff"
	"encoding/json"
	"strings"
)

const DataComparisonCapability = "dataComparisonV1"

type DataReadSide struct {
	Connection       Connection   `json:"connection"`
	Table            tc.Table     `json:"table"`
	DescriptorDigest string       `json:"descriptorDigest,omitempty"`
	Filters          *[]tc.Filter `json:"filters,omitempty"`
	ReadLimit        int          `json:"readLimit,omitempty"`
}
type DataComparisonRequest struct {
	Source     *DataReadSide `json:"source,omitempty"`
	Target     *DataReadSide `json:"target,omitempty"`
	Columns    []tc.Mapping  `json:"columns,omitempty"`
	Originals  string        `json:"originals,omitempty"`
	JobID      string        `json:"jobId,omitempty"`
	Offset     int64         `json:"offset,omitempty"`
	Limit      int           `json:"limit,omitempty"`
	MaxBytes   int           `json:"maxBytes,omitempty"`
	CellOffset int           `json:"cellOffset,omitempty"`
	ValueRef   string        `json:"valueRef,omitempty"`
}
type DataDescriptors struct {
	Source tc.Descriptor `json:"source"`
	Target tc.Descriptor `json:"target"`
}
type DataComparisonSummary struct {
	FormatVersion int                   `json:"formatVersion"`
	Comparison    resultcompare.Summary `json:"comparison"`
	Source        tc.Outcome            `json:"source"`
	Target        tc.Outcome            `json:"target"`
	MappedColumns int                   `json:"mappedColumns"`
	KeyColumns    int                   `json:"keyColumns"`
	ModelDigest   string                `json:"modelDigest"`
}
type DataComparisonResponse struct {
	Offset      *int64                 `json:"offset,omitempty"`
	CellOffset  *int                   `json:"cellOffset,omitempty"`
	Diff        *textdiff.Diff         `json:"diff,omitempty"`
	JobID       string                 `json:"jobId"`
	State       string                 `json:"state"`
	Phase       string                 `json:"phase,omitempty"`
	Code        string                 `json:"code,omitempty"`
	Message     string                 `json:"message,omitempty"`
	Descriptors *DataDescriptors       `json:"descriptors,omitempty"`
	Summary     *DataComparisonSummary `json:"summary,omitempty"`
	Page        *resultcompare.Page    `json:"page,omitempty"`
	Value       *resultcompare.Value   `json:"value,omitempty"`
}

func dataDigest(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, r := range s {
		if !(r >= '0' && r <= '9' || r >= 'a' && r <= 'f') {
			return false
		}
	}
	return true
}
func parseDataComparison(raw json.RawMessage, kind string) (DataComparisonRequest, bool) {
	var r DataComparisonRequest
	var f map[string]json.RawMessage
	if json.Unmarshal(raw, &f) != nil || f == nil {
		return r, false
	}
	allowed := map[string]bool{}
	needed := []string{"jobId"}
	switch kind {
	case "data.describe":
		needed = []string{"source", "target"}
	case "data.start":
		needed = []string{"source", "target", "columns", "originals"}
	case "data.status", "data.cancel", "data.close":
	case "data.diff":
		allowed = map[string]bool{"offset": true, "cellOffset": true}
	case "data.page":
		allowed = map[string]bool{"offset": true, "limit": true, "maxBytes": true, "cellOffset": true}
	case "data.value":
		needed = append(needed, "valueRef")
		allowed = map[string]bool{"offset": true, "maxBytes": true}
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
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&r) != nil {
		return r, false
	}
	if kind == "data.start" || kind == "data.describe" {
		for _, name := range []string{"source", "target"} {
			var nested map[string]json.RawMessage
			if json.Unmarshal(f[name], &nested) != nil || !required(nested, "connection") || !required(nested, "table") {
				return r, false
			}
			side := r.Source
			if name == "target" {
				side = r.Target
			}
			connection, ok := parseConnection(nested["connection"])
			if !ok || side == nil || !side.Table.Valid() {
				return r, false
			}
			side.Connection = connection
			if kind == "data.describe" {
				if len(nested) != 2 {
					return r, false
				}
			} else {
				if len(nested) != 5 || !required(nested, "descriptorDigest") || !required(nested, "filters") || !required(nested, "readLimit") || !dataDigest(side.DescriptorDigest) || side.Filters == nil || len(*side.Filters) > 32 || side.ReadLimit < 1 || side.ReadLimit > 100000 {
					return r, false
				}
				var filters []map[string]json.RawMessage
				_ = json.Unmarshal(nested["filters"], &filters)
				for i, filter := range *side.Filters {
					if !filter.Valid() {
						return r, false
					}
					for name := range filters[i] {
						if !required(filters[i], name) {
							return r, false
						}
					}
				}
			}
		}
		if r.Source.Connection.DatabaseEngine() != r.Target.Connection.DatabaseEngine() || r.Source.Connection.DatabaseEngine() != "postgresql" && r.Source.Connection.DatabaseEngine() != "mysql" {
			return r, false
		}
		if kind == "data.describe" {
			return r, true
		}
		if r.Originals != "allColumns" && r.Originals != "selectedColumns" || len(r.Columns) == 0 || len(r.Columns) > tc.MaxColumns {
			return r, false
		}
		left, right := map[string]bool{}, map[string]bool{}
		keys := 0
		var columns []map[string]json.RawMessage
		_ = json.Unmarshal(f["columns"], &columns)
		for i, c := range r.Columns {
			if !tc.Name(c.Source) || !tc.Name(c.Target) || left[c.Source] || right[c.Target] || !required(columns[i], "source") || !required(columns[i], "target") || !required(columns[i], "key") {
				return r, false
			}
			left[c.Source] = true
			right[c.Target] = true
			if c.Key {
				keys++
			}
		}
		return r, keys > 0 && keys <= 32
	}
	if !ValidID(r.JobID) || strings.ContainsAny(r.JobID, "\x00\r\n") || r.Offset < 0 || r.CellOffset < 0 {
		return r, false
	}
	if kind == "data.page" {
		if _, ok := f["limit"]; !ok {
			r.Limit = 100
		}
		if _, ok := f["maxBytes"]; !ok {
			r.MaxBytes = 262144
		}
		return r, r.Limit >= 1 && r.Limit <= 1000 && r.MaxBytes >= 4096 && r.MaxBytes <= 1<<20
	}
	if kind == "data.value" {
		if _, ok := f["maxBytes"]; !ok {
			r.MaxBytes = 65536
		}
		return r, ValidID(r.ValueRef) && r.MaxBytes >= 1 && r.MaxBytes <= 1<<20
	}
	return r, true
}
