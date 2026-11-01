package protocol

import (
	"bytes"
	"encoding/json"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const QueryParametersCapability = "queryParametersV1"
const MaxQueryParameters = 128
const MaxQueryParameterBytes = 1024 * 1024

// Value is always encoded, including explicit SQL NULL. Definitions deliberately
// do not carry SQL fragments: every value is sent through driver binding.
type QueryParameter struct {
	Name  string  `json:"name"`
	Type  string  `json:"type"`
	Value *string `json:"value"`
}

var parameterInteger = regexp.MustCompile(`^[+-]?[0-9]+$`)
var parameterDecimal = regexp.MustCompile(`^[+-]?[0-9]+(\.[0-9]+)?$`)
var parameterDate = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}$`)
var parameterTimestamp = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?$`)

func QueryParameterNameValid(name string) bool {
	if len(name) == 0 || len(name) > 64 {
		return false
	}
	for i := range name {
		c := name[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_' || i > 0 && c >= '0' && c <= '9') {
			return false
		}
	}
	return true
}

func (parameter QueryParameter) Valid() bool {
	if !QueryParameterNameValid(parameter.Name) {
		return false
	}
	switch parameter.Type {
	case "text", "integer", "decimal", "boolean", "date", "timestamp":
	default:
		return false
	}
	if parameter.Value == nil {
		return true
	}
	value := *parameter.Value
	if len(value) > MaxQueryParameterBytes || !utf8.ValidString(value) || strings.ContainsRune(value, 0) {
		return false
	}
	switch parameter.Type {
	case "integer":
		_, err := strconv.ParseInt(value, 10, 64)
		return parameterInteger.MatchString(value) && err == nil
	case "decimal":
		return parameterDecimal.MatchString(value)
	case "boolean":
		return value == "true" || value == "false"
	case "date":
		parsed, err := time.Parse("2006-01-02", value)
		return parameterDate.MatchString(value) && err == nil && parsed.Year() >= 1
	case "timestamp":
		parsed, err := time.Parse("2006-01-02 15:04:05.999999", value)
		return parameterTimestamp.MatchString(value) && err == nil && parsed.Year() >= 1
	}
	return true
}

func QueryParametersValid(parameters []QueryParameter) bool {
	if len(parameters) > MaxQueryParameters {
		return false
	}
	seen, total := map[string]bool{}, 0
	for _, parameter := range parameters {
		if !parameter.Valid() || seen[parameter.Name] {
			return false
		}
		seen[parameter.Name] = true
		if parameter.Value != nil {
			total += len(*parameter.Value)
		}
		if total > MaxQueryParameterBytes {
			return false
		}
	}
	return true
}

func parseQueryParameters(raw json.RawMessage) ([]QueryParameter, bool) {
	var raws []json.RawMessage
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) || json.Unmarshal(raw, &raws) != nil || len(raws) > MaxQueryParameters {
		return nil, false
	}
	parameters := make([]QueryParameter, 0, len(raws))
	for _, item := range raws {
		fields, ok := changesObject(item, "name|type|value", "name", "type")
		if !ok || fields["value"] == nil {
			return nil, false
		}
		var parameter QueryParameter
		if !stringField(fields, "name", &parameter.Name) || !stringField(fields, "type", &parameter.Type) {
			return nil, false
		}
		if !bytes.Equal(bytes.TrimSpace(fields["value"]), []byte("null")) {
			var value string
			if !stringField(fields, "value", &value) {
				return nil, false
			}
			parameter.Value = &value
		}
		parameters = append(parameters, parameter)
	}
	return parameters, QueryParametersValid(parameters)
}
