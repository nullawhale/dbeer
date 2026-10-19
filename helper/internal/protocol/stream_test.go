package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestStreamingExportAndBrowseCommandsValidateWithoutEchoingInput(t *testing.T) {
	for _, frame := range []string{
		`{"type":"execute","requestId":"e","sessionId":"s","queryId":"q","sql":"SELECT 1","stream":true,"export":{"path":"/fixture/result.json","format":"json"}}`,
		`{"type":"execute","requestId":"e","sessionId":"s","queryId":"q","sql":"SELECT 1","export":{"path":"/fixture/result.csv","format":"csv","nullMarker":"NULL"}}`,
		`{"type":"stream.ack","requestId":"a","sessionId":"s","queryId":"q","sequence":2}`,
		`{"type":"catalog","requestId":"c","sessionId":"s","queryId":"q","stream":true,"catalog":{"kind":"browse","schema":"schema","object":"table","objectKind":"table","page":2,"sort":[{"column":"x","direction":"desc"}],"filters":[{"column":"x","operator":"contains","value":"%_secret-input"},{"column":"y","operator":"isNull"}]}}`,
	} {
		command, err := ParseCommand([]byte(frame))
		if err != nil {
			t.Fatalf("valid streaming command rejected: %v", err)
		}
		encoded, err := json.Marshal(command)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = ParseCommand(encoded); err != nil {
			t.Fatal("streaming command failed round trip")
		}
	}
	for _, frame := range []string{
		`{"type":"stream.ack","requestId":"a","sessionId":"s","queryId":"q","sequence":0}`,
		`{"type":"stream.ack","requestId":"a","sessionId":"s","queryId":"q","sequence":1,"sql":"secret-input"}`,
		`{"type":"execute","requestId":"e","sessionId":"s","queryId":"q","sql":"secret-input","stream":null}`,
		`{"type":"execute","requestId":"e","sessionId":"s","queryId":"q","sql":"secret-input","export":null}`,
		`{"type":"execute","requestId":"e","sessionId":"s","queryId":"q","sql":"secret-input","export":{"path":"relative","format":"json"}}`,
		`{"type":"execute","requestId":"e","sessionId":"s","queryId":"q","sql":"secret-input","export":{"path":"/fixture/result","format":"xml"}}`,
		`{"type":"execute","requestId":"e","sessionId":"s","queryId":"q","sql":"secret-input","export":{"path":"/fixture/result","format":"json","extra":"secret-input"}}`,
	} {
		_, err := ParseCommand([]byte(frame))
		if err == nil || strings.Contains(err.Error(), "secret-input") {
			t.Fatal("invalid stream command was accepted or input was echoed")
		}
	}
}

func TestInvalidBrowsePagingAndFilterShapes(t *testing.T) {
	for _, extra := range []string{
		`"page":-1`, `"page":1000001`, `"page":null`, `"sort":null`, `"filters":null`,
		`"sort":[{"column":"x","direction":"secret-input"}]`,
		`"sort":[{"column":"x","direction":"asc","extra":"secret-input"}]`,
		`"filters":[{"column":"x","operator":"eq"}]`,
		`"filters":[{"column":"x","operator":"isNull","value":"secret-input"}]`,
		`"filters":[{"column":"x","operator":"eq","value":"ok","extra":"secret-input"}]`,
	} {
		frame := `{"type":"catalog","requestId":"c","sessionId":"s","queryId":"q","catalog":{"kind":"browse","schema":"schema","object":"table","objectKind":"table",` + extra + `}}`
		_, err := ParseCommand([]byte(frame))
		if err == nil || strings.Contains(err.Error(), "secret-input") {
			t.Fatal("invalid paging request was accepted or input was echoed")
		}
	}
}
