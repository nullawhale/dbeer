package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"unicode/utf8"
)

type MariaDBOptimizerObservation struct {
	IndexConditionPushdown bool   `json:"indexConditionPushdown"`
	NativeSwitch           string `json:"nativeSwitch"`
}
type MariaDBOptimizerVariant struct {
	ExpectedNativeSwitch   string `json:"expectedNativeSwitch"`
	IndexConditionPushdown bool   `json:"indexConditionPushdown"`
}

func MariaDBIndexConditionPushdown(native string) (bool, bool) {
	if native == "" || len(native) > 4096 || !utf8.ValidString(native) || strings.ContainsAny(native, "\x00\r\n") {
		return false, false
	}
	seen := false
	value := false
	for _, part := range strings.Split(native, ",") {
		name, setting, ok := strings.Cut(part, "=")
		if !ok || name == "" || setting == "" {
			return false, false
		}
		if name != "index_condition_pushdown" {
			continue
		}
		if seen || setting != "on" && setting != "off" {
			return false, false
		}
		seen = true
		value = setting == "on"
	}
	return value, seen
}
func (r MariaDBOptimizerObservation) Valid() bool {
	value, ok := MariaDBIndexConditionPushdown(r.NativeSwitch)
	return ok && value == r.IndexConditionPushdown
}
func (r MariaDBOptimizerVariant) Valid() bool {
	value, ok := MariaDBIndexConditionPushdown(r.ExpectedNativeSwitch)
	return ok && value != r.IndexConditionPushdown
}
func (r *MariaDBOptimizerObservation) UnmarshalJSON(raw []byte) error {
	if fields, ok := changesObject(raw, "indexConditionPushdown|nativeSwitch", "indexConditionPushdown", "nativeSwitch"); !ok || !mariaDBOptimizerBool(fields["indexConditionPushdown"]) {
		return errors.New("Invalid native optimizer observation.")
	}
	type plain MariaDBOptimizerObservation
	var v plain
	if json.Unmarshal(raw, &v) != nil || !MariaDBOptimizerObservation(v).Valid() {
		return errors.New("Invalid native optimizer observation.")
	}
	*r = MariaDBOptimizerObservation(v)
	return nil
}
func (r *MariaDBOptimizerVariant) UnmarshalJSON(raw []byte) error {
	if fields, ok := changesObject(raw, "expectedNativeSwitch|indexConditionPushdown", "expectedNativeSwitch", "indexConditionPushdown"); !ok || !mariaDBOptimizerBool(fields["indexConditionPushdown"]) {
		return errors.New("Invalid native optimizer variant.")
	}
	type plain MariaDBOptimizerVariant
	var v plain
	if json.Unmarshal(raw, &v) != nil || !MariaDBOptimizerVariant(v).Valid() {
		return errors.New("Invalid native optimizer variant.")
	}
	*r = MariaDBOptimizerVariant(v)
	return nil
}

func mariaDBOptimizerBool(raw json.RawMessage) bool {
	v := bytes.TrimSpace(raw)
	return bytes.Equal(v, []byte("true")) || bytes.Equal(v, []byte("false"))
}
