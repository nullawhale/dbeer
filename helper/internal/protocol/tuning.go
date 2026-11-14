package protocol

import (
	"bytes"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"reflect"
)

const TuningCapability = "tuningV1"
const MaxTuningRows = 10000
const MaxTuningBytes = 4 << 20
const MaxTuningTimeoutMS = 30000

type TuningInspectRequest struct {
	Version int              `json:"version"`
	Source  ExplainRequest   `json:"source"`
	Capture ExplainResult    `json:"capture"`
	Target  tableedit.Target `json:"target"`
}
type TuningValidationRequest struct {
	Version             int                      `json:"version"`
	Original            ExplainRequest           `json:"original"`
	Variant             ExplainRequest           `json:"variant"`
	Target              tableedit.Target         `json:"target"`
	MetadataFingerprint string                   `json:"metadataFingerprint"`
	MaxRows             int                      `json:"maxRows"`
	MaxBytes            int                      `json:"maxBytes"`
	TimeoutMS           int                      `json:"timeoutMs"`
	Comparison          string                   `json:"comparison"`
	MariaDBOptimizer    *MariaDBOptimizerVariant `json:"mariaDBOptimizer,omitempty"`
}
type TuningSettingObservationRequest struct {
	Version int            `json:"version"`
	Context ExplainContext `json:"context"`
	Name    string         `json:"name"`
}

func (r TuningSettingObservationRequest) Valid() bool {
	return r.Version == 1 && r.Context.Valid() && r.Context.TransactionStatus == "transaction" && r.Name == "work_mem"
}

type TuningSettingObservation struct {
	Version    int    `json:"version"`
	Name       string `json:"name"`
	WorkMemKiB int    `json:"workMemKiB"`
	Scope      string `json:"scope"`
}

func (r TuningSettingObservation) Valid() bool {
	return r.Version == 1 && r.Name == "work_mem" && r.WorkMemKiB >= 64 && r.WorkMemKiB <= 1048576 && r.Scope == "currentTransaction"
}

type TuningSettingRequest struct {
	Version          int            `json:"version"`
	Context          ExplainContext `json:"context"`
	Name             string         `json:"name"`
	ExpectedValueKiB int            `json:"expectedValueKiB"`
	ValueKiB         int            `json:"valueKiB"`
}

func tuningSource(r ExplainRequest) bool {
	return r.Valid() && r.Context != nil && r.WriteIntent == nil && (r.Context.TransactionStatus == "idle" || r.Context.TransactionStatus == "transaction")
}
func (r TuningInspectRequest) Valid() bool {
	return r.Version == 1 && tuningSource(r.Source) && r.Source.Context.TransactionStatus == "idle" && r.Capture.Valid() && r.Capture.Mode == r.Source.Mode && reflect.DeepEqual(r.Capture.Options, r.Source.Options) && r.Target.Valid() && !r.Target.Create && !r.Target.Reconcile
}
func (r TuningValidationRequest) Valid() bool {
	if r.Version != 1 || !tuningSource(r.Original) || !tuningSource(r.Variant) || r.Original.Context.TransactionStatus != "idle" || r.Variant.Context.TransactionStatus != "idle" || r.Original.Mode != "plan" || r.Variant.Mode != "plan" || r.Original.PlanKind == "generic" || r.Variant.PlanKind == "generic" || !r.Target.Valid() || r.Target.Create || r.Target.Reconcile || !tableedit.IsDigest(r.MetadataFingerprint) || r.MaxRows < 1 || r.MaxRows > MaxTuningRows || r.MaxBytes < 1024 || r.MaxBytes > MaxTuningBytes || r.TimeoutMS < 100 || r.TimeoutMS > MaxTuningTimeoutMS || r.Comparison != "multiset" || !(len(r.Original.Parameters) == 0 && len(r.Variant.Parameters) == 0 || reflect.DeepEqual(r.Original.Parameters, r.Variant.Parameters)) || !reflect.DeepEqual(r.Original.Options, r.Variant.Options) || r.Original.PlanKind != r.Variant.PlanKind {
		return false
	}
	if r.MariaDBOptimizer == nil && r.Original.SQL == r.Variant.SQL || r.MariaDBOptimizer != nil && (!r.MariaDBOptimizer.Valid() || r.Original.SQL != r.Variant.SQL) {
		return false
	}
	a, b := *r.Original.Context, *r.Variant.Context
	a.RangeLength, b.RangeLength = 0, 0
	return a == b
}
func (r TuningSettingRequest) Valid() bool {
	return r.Version == 1 && r.Context.Valid() && r.Context.TransactionStatus == "transaction" && r.Name == "work_mem" && r.ExpectedValueKiB >= 64 && r.ExpectedValueKiB <= 1048576 && r.ValueKiB >= 64 && r.ValueKiB <= 1048576 && r.ValueKiB != r.ExpectedValueKiB
}

type TuningIndexAdvice struct {
	ID          string              `json:"id"`
	NodeID      string              `json:"nodeId"`
	Explanation string              `json:"explanation"`
	Evidence    []string            `json:"evidence"`
	Limitations []string            `json:"limitations"`
	Edit        tableedit.IndexEdit `json:"edit"`
}
type TuningVariant struct {
	ID          string         `json:"id"`
	Kind        string         `json:"kind"`
	Explanation string         `json:"explanation"`
	Validation  string         `json:"validation"`
	Request     ExplainRequest `json:"request"`
}
type TuningInspection struct {
	Version             int                          `json:"version"`
	Engine              string                       `json:"engine"`
	ServerVersion       string                       `json:"serverVersion"`
	EvidenceOrigin      string                       `json:"evidenceOrigin"`
	MetadataFingerprint string                       `json:"metadataFingerprint"`
	Target              tableedit.Target             `json:"target"`
	Indexes             []TuningIndexAdvice          `json:"indexes"`
	Variants            []TuningVariant              `json:"variants"`
	Limitations         []string                     `json:"limitations"`
	WorkMemKiB          *int                         `json:"workMemKiB,omitempty"`
	MariaDBOptimizer    *MariaDBOptimizerObservation `json:"mariaDBOptimizer,omitempty"`
}
type TuningValidation struct {
	Version       int      `json:"version"`
	State         string   `json:"state"`
	Comparison    string   `json:"comparison"`
	OriginalRows  int      `json:"originalRows"`
	VariantRows   int      `json:"variantRows"`
	ComparedBytes int      `json:"comparedBytes"`
	Complete      bool     `json:"complete"`
	Scope         string   `json:"scope"`
	Limitations   []string `json:"limitations"`
}
type TuningSettingPreview struct {
	SQL        string   `json:"sql"`
	RestoreSQL string   `json:"restoreSQL"`
	Scope      string   `json:"scope"`
	Risks      []string `json:"risks"`
}
type TuningSettingResult struct {
	Version      int                  `json:"version"`
	State        string               `json:"state"`
	BeforeKiB    int                  `json:"beforeKiB"`
	RequestedKiB int                  `json:"requestedKiB"`
	Restore      TuningSettingRequest `json:"restore"`
	Limitations  []string             `json:"limitations"`
}

// Only requests are execution authority. Inspection/validation evidence is never
// parsed as an operation and must not retain grants in portable artifacts.
func parseTuning(raw json.RawMessage, kind string) (any, bool) {
	var allowed string
	var requiredKeys []string
	var dst any
	switch kind {
	case "tuning.setting.observe":
		allowed = "version|context|name"
		requiredKeys = []string{"version", "context", "name"}
		dst = &TuningSettingObservationRequest{}
	case "tuning.inspect":
		allowed = "version|source|capture|target"
		requiredKeys = []string{"version", "source", "capture", "target"}
		dst = &TuningInspectRequest{}
	case "tuning.validate":
		allowed = "version|original|variant|target|metadataFingerprint|maxRows|maxBytes|timeoutMs|comparison|mariaDBOptimizer"
		requiredKeys = []string{"version", "original", "variant", "target", "metadataFingerprint", "maxRows", "maxBytes", "timeoutMs", "comparison"}
		dst = &TuningValidationRequest{}
	case "tuning.setting":
		allowed = "version|context|name|expectedValueKiB|valueKiB"
		requiredKeys = []string{"version", "context", "name", "expectedValueKiB", "valueKiB"}
		dst = &TuningSettingRequest{}
	default:
		return nil, false
	}
	fields, ok := changesObject(raw, allowed, requiredKeys...)
	if !ok || !JSONUnicodeValid(raw) {
		return nil, false
	}
	for _, k := range requiredKeys {
		if bytes.Equal(bytes.TrimSpace(fields[k]), []byte("null")) {
			return nil, false
		}
	}
	if v, exists := fields["mariaDBOptimizer"]; exists && bytes.Equal(bytes.TrimSpace(v), []byte("null")) {
		return nil, false
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(dst) != nil {
		return nil, false
	}
	for _, k := range []string{"source", "original", "variant"} {
		if v, exists := fields[k]; exists {
			p, valid := parseExplain(v)
			if !valid {
				return nil, false
			}
			switch r := dst.(type) {
			case *TuningInspectRequest:
				r.Source = *p
			case *TuningValidationRequest:
				if k == "original" {
					r.Original = *p
				} else {
					r.Variant = *p
				}
			}
		}
	}
	if v, exists := fields["target"]; exists {
		if _, ok := changesObject(v, "schema|table|create", "schema", "table", "create"); !ok {
			return nil, false
		}
		if !structureNoNull(v) {
			return nil, false
		}
	}
	if v, exists := fields["context"]; exists {
		if _, ok := changesObject(v, "documentId|targetDocumentId|rangeLocation|rangeLength|profileId|sessionId|transactionStatus", "documentId", "targetDocumentId", "rangeLocation", "rangeLength", "profileId", "sessionId", "transactionStatus"); !ok || !structureNoNull(v) {
			return nil, false
		}
	}
	switch r := dst.(type) {
	case *TuningSettingObservationRequest:
		return r, r.Valid()
	case *TuningInspectRequest:
		return r, r.Valid()
	case *TuningValidationRequest:
		return r, r.Valid()
	case *TuningSettingRequest:
		return r, r.Valid()
	}
	return nil, false
}

func tuningText(s string) bool { return s != "" && len(s) <= 4096 }
func tuningTexts(a []string) bool {
	if len(a) < 1 || len(a) > 16 {
		return false
	}
	for _, s := range a {
		if !tuningText(s) {
			return false
		}
	}
	return true
}
func (r TuningInspection) Valid() bool {
	if r.Version != 1 || (r.Engine != "postgresql" && r.Engine != "mysql" && r.Engine != "mariadb") || len(r.ServerVersion) > 256 || r.EvidenceOrigin != "suppliedCapture" || !tableedit.IsDigest(r.MetadataFingerprint) || !r.Target.Valid() || r.Target.Create || r.Target.Reconcile || len(r.Indexes) > 1 || len(r.Variants) > 1 || !tuningTexts(r.Limitations) || r.WorkMemKiB != nil && (r.Engine != "postgresql" || *r.WorkMemKiB < 64 || *r.WorkMemKiB > 1048576) {
		return false
	}
	if r.MariaDBOptimizer != nil && (r.Engine != "mariadb" || !r.MariaDBOptimizer.Valid()) {
		return false
	}
	for _, x := range r.Indexes {
		if !ValidID(x.ID) || !ValidID(x.NodeID) || !tuningText(x.Explanation) || !tuningTexts(x.Evidence) || !tuningTexts(x.Limitations) || x.Edit.Action != "add" || x.Edit.Unique || len(x.Edit.Columns) != 0 || !tableedit.Identifier(x.Edit.Name) || x.Edit.Definition == nil || !x.Edit.Definition.Valid() || x.Edit.Definition.Method != "btree" || len(x.Edit.Definition.Terms) != 1 || x.Edit.Definition.Terms[0].Column == nil || x.Edit.Definition.Terms[0].Expression != nil {
			return false
		}
	}
	for _, x := range r.Variants {
		if !ValidID(x.ID) || x.Kind != "sameColumnOrToIn" || !tuningText(x.Explanation) || x.Validation != "unvalidated" || !tuningSource(x.Request) || x.Request.Mode != "plan" {
			return false
		}
	}
	return true
}
func (r TuningValidation) Valid() bool {
	return r.Version == 1 && (r.State == "inconclusive" || r.State == "observedEqual" || r.State == "observedDifferent") && r.Comparison == "multiset" && r.OriginalRows >= 0 && r.OriginalRows <= MaxTuningRows && r.VariantRows >= 0 && r.VariantRows <= MaxTuningRows && r.ComparedBytes >= 0 && r.ComparedBytes <= MaxTuningBytes && r.Complete == (r.State != "inconclusive") && r.Scope == "sequentialCurrentSession" && tuningTexts(r.Limitations)
}
func (r TuningSettingResult) Valid() bool {
	return r.Version == 1 && r.State == "applied" && r.Restore.Valid() && r.BeforeKiB == r.Restore.ValueKiB && r.RequestedKiB == r.Restore.ExpectedValueKiB && tuningTexts(r.Limitations)
}
