package mcpbridge

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	"github.com/google/uuid"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestSDKNativeCommandPreservesArgumentBytesAndRecursiveReply(t *testing.T) {
	commands := make(chan request, 4)
	client := connectTestServer(t, func(context.Context) (net.Conn, error) {
		local, native := net.Pipe()
		t.Cleanup(func() { _ = native.Close() })
		go func() {
			decoder, encoder := json.NewDecoder(native), json.NewEncoder(native)
			for {
				var command request
				if decoder.Decode(&command) != nil {
					return
				}
				commands <- command
				reply := response{ID: command.ID, OK: true, QueryID: command.QueryID}
				if command.Method == "command" {
					var result Result
					if json.Unmarshal([]byte(`{"columns":[{"name":"reply","type":"native"}],"rows":[["display"]],"commandTag":"NATIVE","rowCount":1,"truncated":false,"nativeValues":[[{"kind":"object","entries":[{"key":{"kind":"text","value":"duplicate"},"value":{"kind":"integer","value":"9007199254740993"}},{"key":{"kind":"text","value":"duplicate"},"value":{"kind":"binary","value":"AP8="}}]}]]}`), &result) != nil {
						return
					}
					reply.Results = []Result{result}
				}
				if encoder.Encode(reply) != nil {
					return
				}
			}
		}()
		return local, nil
	})
	profile, query := uuid.NewString(), uuid.NewString()
	command := protocol.NativeCommand{Name: "ECHO", Arguments: []protocol.NativeCommandArgument{{Kind: "text", Value: ""}, {Kind: "binary", Value: "AP8="}, {Kind: "text", Value: "é e\u0301 two words\x00"}}}
	r, err := client.CallTool(testContext(t), &mcp.CallToolParams{Name: "dbeer_command", Arguments: map[string]any{"profileId": profile, "queryId": query, "command": command}})
	if err != nil || r.IsError {
		t.Fatal("native tool failed", err, r)
	}
	if (<-commands).Method != "hello" {
		t.Fatal("approval not lazy at actual invocation")
	}
	forwarded := <-commands
	a, _ := json.Marshal(command)
	b, _ := json.Marshal(forwarded.NativeCommand)
	if forwarded.Method != "command" || forwarded.QueryID != query || forwarded.ProfileID != profile || string(a) != string(b) {
		t.Fatal("exact command changed")
	}
	encoded, _ := json.Marshal(r.StructuredContent)
	for _, s := range []string{`"nativeValues"`, `"9007199254740993"`, `"AP8="`, `"duplicate"`, query} {
		if !strings.Contains(string(encoded), s) {
			t.Fatal("native reply evidence lost")
		}
	}
}

func TestSDKInvalidNativeCommandsDoNotRequestApproval(t *testing.T) {
	var dials atomic.Int32
	client := connectTestServer(t, func(context.Context) (net.Conn, error) { dials.Add(1); return nil, errors.New("unreachable") })
	for _, command := range []string{
		`{"name":"ECHO WORD","arguments":[]}`,
		`{"name":"ECHO","arguments":[{"kind":"binary","value":"AB=="}]}`,
		`{"name":"ECHO","arguments":[{"kind":"text","value":"\ud800"}]}`,
		`{"name":"ECHO","arguments":[{"kind":"text","value":"a","value":"b"}]}`,
	} {
		raw := json.RawMessage(`{"profileId":"` + uuid.NewString() + `","queryId":"` + uuid.NewString() + `","command":` + command + `}`)
		result, err := client.CallTool(testContext(t), &mcp.CallToolParams{Name: "dbeer_command", Arguments: raw})
		if err == nil && !result.IsError {
			t.Fatal("invalid command accepted")
		}
	}
	if dials.Load() != 0 {
		t.Fatal("invalid command requested profile approval")
	}
}

func TestNativeCommandBridgeCancellationUsesExistingPriorityControl(t *testing.T) {
	local, native := net.Pipe()
	defer native.Close()
	b := newBridge(local)
	defer b.close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := b.call(ctx, request{Method: "command", QueryID: "native-operation", NativeCommand: &protocol.NativeCommand{Name: "READ", Arguments: []protocol.NativeCommandArgument{}}})
		done <- err
	}()
	decoder := json.NewDecoder(native)
	var command request
	if decoder.Decode(&command) != nil || command.Method != "command" {
		t.Fatal("command not sent")
	}
	cancel()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("cancelled command succeeded")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("command cancellation blocked")
	}
	_ = native.SetReadDeadline(time.Now().Add(2 * time.Second))
	if decoder.Decode(&command) != nil || command.Method != "cancel" || command.QueryID != "native-operation" {
		t.Fatal("native command did not use targeted cancellation")
	}
}
