package protocol

import (
	"encoding/json"
	"os"
	"testing"
)

func TestTuningSharedContractAndClosedRequests(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/tuning-v1/contract.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Version       int
		Capability    string
		Commands      []json.RawMessage
		Inspection    TuningInspection
		Validation    TuningValidation
		SettingResult TuningSettingResult
	}
	if json.Unmarshal(data, &f) != nil || f.Version != 1 || f.Capability != TuningCapability || !f.Inspection.Valid() || !f.Validation.Valid() || !f.SettingResult.Valid() {
		t.Fatal("invalid paired fixture")
	}
	for _, raw := range f.Commands {
		c, err := ParseCommand(raw)
		if err != nil {
			t.Fatalf("valid request %s: %v", raw, err)
		}
		var object map[string]any
		_ = json.Unmarshal(raw, &object)
		key := map[string]string{"tuning.inspect": "tuningInspect", "tuning.validate": "tuningValidation", "tuning.setting": "tuningSetting", "tuning.setting.observe": "tuningSettingObservation"}[c.Type]
		body := object[key].(map[string]any)
		for field := range body {
			for _, kind := range []string{"missing", "null"} {
				var copy map[string]any
				_ = json.Unmarshal(raw, &copy)
				b := copy[key].(map[string]any)
				if kind == "missing" {
					delete(b, field)
				} else {
					b[field] = nil
				}
				bad, _ := json.Marshal(copy)
				if _, err := ParseCommand(bad); err == nil {
					t.Errorf("%s %s.%s accepted", kind, c.Type, field)
				}
			}
		}
		body["unknown"] = true
		bad, _ := json.Marshal(object)
		if _, err := ParseCommand(bad); err == nil {
			t.Fatal("unknown tuning field")
		}
		if c.Type != "tuning.inspect" && c.Type != "tuning.setting.observe" {
			op := map[string]any{"type": c.Type, key: object[key]}
			delete(body, "unknown")
			encoded, _ := json.Marshal([]any{op})
			ops, ok := parseOperations(encoded)
			if !ok || len(ops) != 1 {
				t.Fatal("operation parse")
			}
		}
	}
}
func TestTuningValidationRejectsAuthorityAndLimits(t *testing.T) {
	data, _ := os.ReadFile("../../../protocol/fixtures/tuning-v1/contract.json")
	var f struct{ ValidationRequest TuningValidationRequest }
	_ = json.Unmarshal(data, &f)
	for _, change := range []func(*TuningValidationRequest){func(r *TuningValidationRequest) { r.Version = 2 }, func(r *TuningValidationRequest) { r.MaxRows = 10001 }, func(r *TuningValidationRequest) { r.MaxBytes = 4<<20 + 1 }, func(r *TuningValidationRequest) { r.TimeoutMS = 30001 }, func(r *TuningValidationRequest) { r.Comparison = "ordered" }, func(r *TuningValidationRequest) { r.Original.Context = nil }, func(r *TuningValidationRequest) { r.Variant.Context.SessionID = "stale" }, func(r *TuningValidationRequest) { r.Variant.Context.ProfileID = "stale" }, func(r *TuningValidationRequest) { r.Variant.Context.RangeLocation++ }, func(r *TuningValidationRequest) { r.Variant.Parameters[0].Value = nil }, func(r *TuningValidationRequest) { r.Original.Mode = "analyze" }, func(r *TuningValidationRequest) { r.Variant.PlanKind = "generic" }, func(r *TuningValidationRequest) {
		r.Original.WriteIntent = &ExplainWriteIntent{Disposition: "currentSession", ExpectedTransactionStatus: "idle"}
	}} {
		var copy TuningValidationRequest
		raw, _ := json.Marshal(f.ValidationRequest)
		_ = json.Unmarshal(raw, &copy)
		change(&copy)
		if copy.Valid() {
			t.Fatal("invalid scope/value/authority accepted")
		}
	}
}
