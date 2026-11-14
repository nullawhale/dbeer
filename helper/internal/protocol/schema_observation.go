package protocol

import (
	"bytes"
	"encoding/json"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const SchemaObservationCapability = "schemaObservationV1"

type SchemaObservationTable struct {
	Schema string `json:"schema"`
	Name   string `json:"name"`
}

type SchemaObservationRequest struct {
	Action string                   `json:"action"`
	Tables []SchemaObservationTable `json:"tables"`
}

func (r SchemaObservationRequest) Valid() bool {
	if r.Action != "poll" && r.Action != "previewInstall" && r.Action != "previewRemove" {
		return false
	}
	if r.Tables == nil || len(r.Tables) > 100 || r.Action == "poll" && len(r.Tables) == 0 || r.Action != "poll" && len(r.Tables) != 0 {
		return false
	}
	seen := map[SchemaObservationTable]bool{}
	for _, table := range r.Tables {
		for _, name := range []string{table.Schema, table.Name} {
			if name == "" || len(name) > 1024 || !utf8.ValidString(name) || strings.ContainsRune(name, 0) {
				return false
			}
		}
		if seen[table] {
			return false
		}
		seen[table] = true
	}
	return true
}

func parseSchemaObservation(raw json.RawMessage) (*SchemaObservationRequest, bool) {
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil || len(fields) != 2 || fields["action"] == nil || fields["tables"] == nil {
		return nil, false
	}
	for _, value := range fields {
		if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return nil, false
		}
	}
	var request SchemaObservationRequest
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil || !request.Valid() {
		return nil, false
	}
	var tables []map[string]json.RawMessage
	if json.Unmarshal(fields["tables"], &tables) != nil {
		return nil, false
	}
	for _, table := range tables {
		if len(table) != 2 || table["schema"] == nil || table["name"] == nil {
			return nil, false
		}
	}
	return &request, true
}

type SchemaObservation struct {
	Engine     string                   `json:"engine"`
	Action     string                   `json:"action"`
	Tables     []SchemaObservationTable `json:"tables"`
	Mode       string                   `json:"mode"`
	Revision   string                   `json:"revision"`
	ObservedAt string                   `json:"observedAt"`
	Installed  bool                     `json:"installed"`
	CanInstall bool                     `json:"canInstall"`
	CanRemove  bool                     `json:"canRemove"`
	Complete   bool                     `json:"complete"`
	Notices    []string                 `json:"notices"`
	SQL        string                   `json:"sql,omitempty"`
}

func (r SchemaObservation) Valid() bool {
	if r.Engine != "postgresql" && r.Engine != "mysql" && r.Engine != "mariadb" || !(SchemaObservationRequest{Action: r.Action, Tables: r.Tables}).Valid() || len(r.Notices) > 16 || r.Notices == nil {
		return false
	}
	if _, err := time.Parse(time.RFC3339Nano, r.ObservedAt); err != nil || !monitorTimestamp.MatchString(r.ObservedAt) {
		return false
	}
	for _, notice := range r.Notices {
		if notice == "" || len(notice) > 1024 || !utf8.ValidString(notice) || strings.ContainsRune(notice, 0) {
			return false
		}
	}
	if !r.Complete && len(r.Notices) == 0 || len(r.SQL) > 16384 || strings.ContainsRune(r.SQL, 0) || !utf8.ValidString(r.SQL) {
		return false
	}
	if r.Action != "poll" {
		return r.Engine == "postgresql" && r.Mode == "notifications" && r.Revision == "" && r.SQL != ""
	}
	if r.SQL != "" {
		return false
	}
	if r.Engine == "postgresql" {
		value, err := strconv.ParseUint(r.Revision, 10, 64)
		return r.Mode == "notifications" && err == nil && strconv.FormatUint(value, 10) == r.Revision
	}
	if r.Mode != "fingerprint" || r.Installed || r.CanInstall || r.CanRemove {
		return false
	}
	if !r.Complete {
		return r.Revision == ""
	}
	if len(r.Revision) != 64 {
		return false
	}
	for _, c := range r.Revision {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
