package protocol

import (
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"
)

func TestNativeCommandSharedContract(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/native-commands-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Capability     string
		Valid, Invalid []json.RawMessage
		InvalidJSON    []string
	}
	if json.Unmarshal(data, &fixture) != nil || fixture.Capability != NativeCommandsCapability {
		t.Fatal("fixture")
	}
	for i, raw := range fixture.Valid {
		var command, copied NativeCommand
		if err := json.Unmarshal(raw, &command); err != nil {
			t.Fatalf("valid %d: %v", i, err)
		}
		encoded, _ := json.Marshal(command)
		if json.Unmarshal(encoded, &copied) != nil || !reflect.DeepEqual(command, copied) {
			t.Fatal("exact command changed")
		}
	}
	for _, raw := range fixture.InvalidJSON {
		fixture.Invalid = append(fixture.Invalid, json.RawMessage(raw))
	}
	for i, raw := range fixture.Invalid {
		var command NativeCommand
		if json.Unmarshal(raw, &command) == nil {
			t.Fatalf("invalid case %d accepted", i)
		}
	}
	for _, command := range []NativeCommand{
		{Name: "READ", Arguments: []NativeCommandArgument{{Kind: "text", Value: strings.Repeat("x", MaxNativeCommandBytes)}}},
		{Name: "READ", Arguments: []NativeCommandArgument{{Kind: "text", Value: strings.Repeat("\x00", MaxNativeCommandBytes/6)}}},
		{Name: "READ", Arguments: make([]NativeCommandArgument, 1025)},
	} {
		if command.Valid() {
			t.Fatal("aggregate bound bypassed")
		}
	}
}

func TestNativeCommandExecuteAndAssessmentClosedShapes(t *testing.T) {
	valid := `{"type":"command.execute","requestId":"r","sessionId":"s","queryId":"q","nativeCommand":{"name":"ECHO","arguments":[{"kind":"binary","value":"AP8="}]},"resultValues":"nativeV1","authorization":"grant"}`
	if command, failure := ParseCommand([]byte(valid)); failure != nil || command.NativeCommand == nil {
		t.Fatal("command rejected", failure)
	}
	for _, raw := range []string{
		strings.Replace(valid, `,"resultValues":"nativeV1"`, "", 1),
		strings.Replace(valid, `"nativeV1"`, `"text"`, 1),
		strings.Replace(valid, `"authorization":"grant"`, `"sql":"SELECT 1"`, 1),
		strings.Replace(valid, `"authorization":"grant"`, `"stream":true`, 1),
	} {
		if _, failure := ParseCommand([]byte(raw)); failure == nil {
			t.Fatal("invalid command accepted")
		}
	}
	assessment := `{"type":"operation.assess","requestId":"a","sessionId":"s","queryId":"assessment","operations":[{"type":"command.execute","queryId":"q","nativeCommand":{"name":"ECHO","arguments":[]}}]}`
	if _, failure := ParseCommand([]byte(assessment)); failure != nil {
		t.Fatal("assessment rejected", failure)
	}
	if _, failure := ParseCommand([]byte(strings.Replace(assessment, `"queryId":"q",`, "", 1))); failure == nil {
		t.Fatal("unbound command accepted")
	}
}
