package protocol

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

const DatabaseToolsCapability = "databaseToolsV1"

type DatabaseToolsRequest struct {
	Connection    *Connection `json:"connection,omitempty"`
	Operation     string      `json:"operation,omitempty"`
	Format        string      `json:"format,omitempty"`
	Path          string      `json:"path,omitempty"`
	ToolPath      string      `json:"toolPath,omitempty"`
	PlanID        string      `json:"planId,omitempty"`
	ApprovalToken string      `json:"approvalToken,omitempty"`
	Confirmed     bool        `json:"confirmed,omitempty"`
	JobID         string      `json:"jobId,omitempty"`
}

type DatabaseToolsReply struct {
	PlanID               string   `json:"planId,omitempty"`
	ApprovalToken        string   `json:"approvalToken,omitempty"`
	JobID                string   `json:"jobId,omitempty"`
	State                string   `json:"state"`
	Phase                string   `json:"phase"`
	Engine               string   `json:"engine,omitempty"`
	Operation            string   `json:"operation,omitempty"`
	Format               string   `json:"format,omitempty"`
	Database             string   `json:"database,omitempty"`
	Path                 string   `json:"path,omitempty"`
	ToolName             string   `json:"toolName,omitempty"`
	ToolVersion          string   `json:"toolVersion,omitempty"`
	ServerVersion        string   `json:"serverVersion,omitempty"`
	Message              string   `json:"message,omitempty"`
	RequiresConfirmation bool     `json:"requiresConfirmation"`
	OutputPublished      bool     `json:"outputPublished"`
	Warnings             []string `json:"warnings"`
	BytesProcessed       *int64   `json:"bytesProcessed,omitempty"`
	TotalBytes           *int64   `json:"totalBytes,omitempty"`
	ExitCode             *int     `json:"exitCode,omitempty"`
}

func databaseToolsText(value string, limit int) bool {
	return len(value) <= limit && utf8.ValidString(value) && !strings.ContainsRune(value, 0)
}

func (r DatabaseToolsRequest) Valid(kind string) bool {
	switch kind {
	case "dbtools.preview":
		if r.Connection == nil || !r.Connection.Valid() || r.Connection.SessionPurpose != "" ||
			r.Connection.DatabaseEngine() != "postgresql" && r.Connection.DatabaseEngine() != "mysql" && r.Connection.DatabaseEngine() != "mariadb" ||
			r.Operation != "dump" && r.Operation != "restore" ||
			r.Format != "sql" && r.Format != "custom" && r.Format != "tar" ||
			(r.Connection.DatabaseEngine() == "mysql" || r.Connection.DatabaseEngine() == "mariadb") && r.Format != "sql" ||
			!filepath.IsAbs(r.Path) || !filepath.IsAbs(r.ToolPath) ||
			!databaseToolsText(r.Path, 4096) || !databaseToolsText(r.ToolPath, 4096) ||
			r.PlanID != "" || r.ApprovalToken != "" || r.JobID != "" || r.Confirmed {
			return false
		}
		for _, value := range []string{r.Connection.Host, r.Connection.Database, r.Connection.User, r.Connection.SSLRootCert} {
			if !databaseToolsText(value, 4096) {
				return false
			}
		}
		return databaseToolsText(r.Connection.Password, 65536)
	case "dbtools.start":
		return ValidID(r.PlanID) && ValidID(r.ApprovalToken) && r.JobID == "" && r.Connection == nil && r.Operation == "" && r.Format == "" && r.Path == "" && r.ToolPath == ""
	case "dbtools.status", "dbtools.cancel":
		return ValidID(r.JobID) && r.PlanID == "" && r.ApprovalToken == "" && !r.Confirmed && r.Connection == nil && r.Operation == "" && r.Format == "" && r.Path == "" && r.ToolPath == ""
	case "dbtools.close":
		return (ValidID(r.JobID) && r.PlanID == "" || ValidID(r.PlanID) && r.JobID == "") && r.ApprovalToken == "" && !r.Confirmed && r.Connection == nil && r.Operation == "" && r.Format == "" && r.Path == "" && r.ToolPath == ""
	}
	return false
}

func parseDatabaseTools(raw json.RawMessage, kind string) (DatabaseToolsRequest, bool) {
	var r DatabaseToolsRequest
	var fields map[string]json.RawMessage
	if !utf8.Valid(raw) || json.Unmarshal(raw, &fields) != nil || fields == nil {
		return r, false
	}
	allowed := map[string]bool{}
	needed := []string{}
	switch kind {
	case "dbtools.preview":
		needed = []string{"connection", "operation", "format", "path", "toolPath"}
	case "dbtools.start":
		needed = []string{"planId", "approvalToken"}
		allowed["confirmed"] = true
	case "dbtools.status", "dbtools.cancel":
		needed = []string{"jobId"}
	case "dbtools.close":
		allowed["planId"], allowed["jobId"] = true, true
	default:
		return r, false
	}
	for _, name := range needed {
		allowed[name] = true
		if !required(fields, name) {
			return r, false
		}
	}
	for name := range fields {
		if !allowed[name] || !required(fields, name) {
			return r, false
		}
	}
	if (kind == "dbtools.status" || kind == "dbtools.cancel") && len(fields) != 1 {
		return r, false
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(&r) != nil {
		return r, false
	}
	if kind == "dbtools.preview" {
		connection, ok := parseConnection(fields["connection"])
		if !ok {
			return r, false
		}
		r.Connection = &connection
	}
	return r, r.Valid(kind)
}

func (r DatabaseToolsReply) Valid(kind string) bool {
	if kind != "dbtools.preview.result" && kind != "dbtools.start.result" && kind != "dbtools.status.result" && kind != "dbtools.cancel.result" && kind != "dbtools.close.result" || r.Warnings == nil || len(r.Warnings) > 16 ||
		!databaseToolsText(r.Message, 2048) || !databaseToolsText(r.Path, 4096) || !databaseToolsText(r.Database, 4096) ||
		!databaseToolsText(r.ToolVersion, 256) || !databaseToolsText(r.ServerVersion, 256) || !databaseToolsText(r.ToolName, 256) {
		return false
	}
	for _, warning := range r.Warnings {
		if warning == "" || !databaseToolsText(warning, 1024) {
			return false
		}
	}
	if r.BytesProcessed != nil && *r.BytesProcessed < 0 || r.TotalBytes != nil && *r.TotalBytes < 0 || r.BytesProcessed != nil && r.TotalBytes != nil && *r.BytesProcessed > *r.TotalBytes {
		return false
	}
	if r.ExitCode != nil && (*r.ExitCode < 0 || *r.ExitCode > 255) {
		return false
	}
	if r.OutputPublished && (r.State != "completed" || r.Operation != "dump") {
		return false
	}
	switch r.State {
	case "prepared":
		return kind == "dbtools.preview.result" && r.Phase == "ready" && ValidID(r.PlanID) && ValidID(r.ApprovalToken) && r.JobID == "" && r.validSummary()
	case "running", "completed", "failed", "cancelled", "partial", "outcomeUnknown":
		return (kind == "dbtools.start.result" || kind == "dbtools.status.result" || kind == "dbtools.cancel.result") && ValidID(r.JobID) && r.PlanID == "" && r.ApprovalToken == "" && r.validSummary() && (r.State == "running" || r.Phase == r.State)
	case "closed":
		return kind == "dbtools.close.result" && r.Phase == "closed" && (ValidID(r.PlanID) != ValidID(r.JobID)) && r.ApprovalToken == ""
	}
	return false
}

func (r DatabaseToolsReply) validSummary() bool {
	if r.Engine != "postgresql" && r.Engine != "mysql" && r.Engine != "mariadb" || r.Operation != "dump" && r.Operation != "restore" ||
		r.Format != "sql" && r.Format != "custom" && r.Format != "tar" || (r.Engine == "mysql" || r.Engine == "mariadb") && r.Format != "sql" ||
		r.Database == "" || !filepath.IsAbs(r.Path) || r.ToolName == "" || r.ToolVersion == "" || r.ServerVersion == "" ||
		r.RequiresConfirmation != (r.Operation == "restore") {
		return false
	}
	name := "pg_dump"
	if r.Engine == "mariadb" {
		name = "mariadb-dump"
		if r.Operation == "restore" {
			name = "mariadb"
		}
	} else if r.Engine == "mysql" {
		name = "mysqldump"
		if r.Operation == "restore" {
			name = "mysql"
		}
	} else if r.Operation == "restore" {
		name = "pg_restore"
		if r.Format == "sql" {
			name = "psql"
		}
	}
	if r.ToolName != name {
		return false
	}
	switch r.Phase {
	case "ready", "starting", "dumping", "restoring", "publishing", "completed", "failed", "cancelled", "partial", "outcomeUnknown":
		return true
	}
	return false
}
