package protocol

import (
	"encoding/json"
	"os"
	"testing"
)

func TestMariaDBOptimizerObservationAndVariantAreClosed(t *testing.T) {
	native := "index_merge=on,index_condition_pushdown=on,future_native_flag=off"
	if !(MariaDBOptimizerObservation{true, native}).Valid() || !(MariaDBOptimizerVariant{native, false}).Valid() || (MariaDBOptimizerVariant{native, true}).Valid() {
		t.Fatal("native observation or non-noop boundary changed")
	}
	for _, raw := range []string{`{"indexConditionPushdown":null,"nativeSwitch":"index_condition_pushdown=off"}`, `{"nativeSwitch":"index_condition_pushdown=on"}`, `{"indexConditionPushdown":"true","nativeSwitch":"index_condition_pushdown=on"}`, `{"indexConditionPushdown":true,"nativeSwitch":null}`, `{"indexConditionPushdown":false,"nativeSwitch":"index_condition_pushdown=on"}`, `{"indexConditionPushdown":true,"nativeSwitch":"index_condition_pushdown=on,index_condition_pushdown=on"}`, `{"indexConditionPushdown":true,"nativeSwitch":"index_condition_pushdown=on","future":true}`} {
		var observation MariaDBOptimizerObservation
		if json.Unmarshal([]byte(raw), &observation) == nil {
			t.Fatal("malformed/unknown native optimizer observation admitted")
		}
	}
}

func TestMariaDBOptimizerRequestSameSQLAndStrictOptionalAuthority(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/tuning-v1/contract.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct{ ValidationRequest TuningValidationRequest }
	if json.Unmarshal(data, &f) != nil {
		t.Fatal("invalid existing request fixture")
	}
	r := f.ValidationRequest
	r.Variant = r.Original
	r.MariaDBOptimizer = &MariaDBOptimizerVariant{ExpectedNativeSwitch: "index_merge=on,index_condition_pushdown=on,future_native_flag=off", IndexConditionPushdown: false}
	if !r.Valid() {
		t.Fatal("exact native optimizer request rejected")
	}
	raw, _ := json.Marshal(r)
	if _, ok := parseTuning(raw, "tuning.validate"); !ok {
		t.Fatal("typed optimizer request rejected by command boundary")
	}
	for _, mutate := range []func(map[string]any){
		func(m map[string]any) { m["mariaDBOptimizer"] = nil },
		func(m map[string]any) { m["mariaDBOptimizer"].(map[string]any)["indexConditionPushdown"] = nil },
		func(m map[string]any) { m["mariaDBOptimizer"].(map[string]any)["indexConditionPushdown"] = true },
		func(m map[string]any) { m["mariaDBOptimizer"].(map[string]any)["future"] = true },
		func(m map[string]any) {
			m["variant"].(map[string]any)["sql"] = "SELECT id FROM public.items WHERE id = 99"
		},
	} {
		var changed map[string]any
		if json.Unmarshal(raw, &changed) != nil {
			t.Fatal("request clone failed")
		}
		mutate(changed)
		bad, _ := json.Marshal(changed)
		if _, ok := parseTuning(bad, "tuning.validate"); ok {
			t.Fatal("malformed, no-op or changed-query optimizer authority admitted")
		}
	}
	r.MariaDBOptimizer = nil
	if r.Valid() {
		t.Fatal("unchanged ordinary query became a valid rewrite")
	}
}
