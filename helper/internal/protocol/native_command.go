package protocol

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"unicode/utf8"

	"dbeer/helper/internal/jsoncheck"
)

const NativeCommandsCapability = "nativeCommandsV1"
const MaxNativeCommandBytes = 96 * 1024

// Arguments are ordered, including empty arguments; text is never shell-split.
type NativeCommand struct {
	Name      string                  `json:"name"`
	Arguments []NativeCommandArgument `json:"arguments"`
}

type NativeCommandArgument struct {
	Kind  string `json:"kind"`
	Value string `json:"value"`
}

func (command NativeCommand) Valid() bool {
	if len(command.Name) == 0 || len(command.Name) > 64 || command.Arguments == nil || len(command.Arguments) > 1024 {
		return false
	}
	for i, c := range []byte(command.Name) {
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || i > 0 && (c >= '0' && c <= '9' || c == '_' || c == '.' || c == '-')) {
			return false
		}
	}
	bytes := len(command.Name)
	for _, argument := range command.Arguments {
		bytes += len(argument.Value)
		if bytes > MaxNativeCommandBytes || !utf8.ValidString(argument.Value) {
			return false
		}
		switch argument.Kind {
		case "text":
		case "binary":
			decoded, err := base64.StdEncoding.Strict().DecodeString(argument.Value)
			if err != nil || base64.StdEncoding.EncodeToString(decoded) != argument.Value {
				return false
			}
		default:
			return false
		}
	}
	encoded, err := json.Marshal(command)
	return err == nil && len(encoded) <= MaxNativeCommandBytes
}

func (command *NativeCommand) UnmarshalJSON(data []byte) error {
	type wire NativeCommand
	var value wire
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if len(data) > MaxNativeCommandBytes || !jsoncheck.UnicodeValid(data) || !jsoncheck.UniqueObjectKeys(data) || decoder.Decode(&value) != nil || !NativeCommand(value).Valid() {
		return errors.New("Invalid native command.")
	}
	// Required scalar fields cannot disappear through zero-value decoding.
	var fields map[string]json.RawMessage
	_ = json.Unmarshal(data, &fields)
	var args []map[string]json.RawMessage
	_ = json.Unmarshal(fields["arguments"], &args)
	if len(fields) != 2 || fields["name"] == nil || fields["arguments"] == nil {
		return errors.New("Invalid native command.")
	}
	for _, arg := range args {
		if len(arg) != 2 || arg["kind"] == nil || arg["value"] == nil || bytes.Equal(bytes.TrimSpace(arg["value"]), []byte("null")) {
			return errors.New("Invalid native command argument.")
		}
	}
	*command = NativeCommand(value)
	return nil
}
