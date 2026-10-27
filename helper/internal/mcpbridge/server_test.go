package mcpbridge

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func connectTestServer(t *testing.T, dial func(context.Context) (net.Conn, error)) *mcp.ClientSession {
	t.Helper()
	ctx := testContext(t)
	server, holder := newServer(dial)
	clientTransport, serverTransport := mcp.NewInMemoryTransports()
	serverSession, err := server.Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatal(err)
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "1"}, nil)
	clientSession, err := client.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = clientSession.Close(); holder.close(); _ = serverSession.Close() })
	return clientSession
}

func TestSDKToolDiscoveryDoesNotConnectToApplication(t *testing.T) {
	var dials atomic.Int32
	client := connectTestServer(t, func(context.Context) (net.Conn, error) {
		dials.Add(1)
		return nil, errors.New("private transport details")
	})
	tools, err := client.ListTools(testContext(t), nil)
	if err != nil || len(tools.Tools) != 4 || dials.Load() != 0 {
		t.Fatalf("unexpected tool discovery: %v, dials=%d", err, dials.Load())
	}
	for _, tool := range tools.Tools {
		if !strings.HasPrefix(tool.Name, "dbeer_") {
			t.Fatalf("unexpected tool: %s", tool.Name)
		}
	}
	result, err := client.CallTool(testContext(t), &mcp.CallToolParams{Name: "dbeer_connections", Arguments: map[string]any{}})
	if err != nil || !result.IsError {
		t.Fatalf("closed application must be a readable tool failure: %v", err)
	}
	encoded, _ := json.Marshal(result)
	if strings.Contains(string(encoded), "private transport details") || !strings.Contains(string(encoded), "Open DBeer") {
		t.Fatal("raw connection error escaped")
	}
}

func TestSDKApprovalAndExactResultValues(t *testing.T) {
	profileID, queryID := uuid.NewString(), uuid.NewString()
	var dials atomic.Int32
	commands := make(chan request, 8)
	client := connectTestServer(t, func(context.Context) (net.Conn, error) {
		dials.Add(1)
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
				reply := response{ID: command.ID, OK: true}
				if command.Method == "connections" {
					reply.Connections = []Connection{{ID: profileID, Name: "Local", Engine: "postgresql", ReadOnly: true}}
				}
				if command.Method == "query" {
					empty, literalNull, exact, binary := "", "NULL", "12345678901234567890.000000001", "AAH/"
					reply.QueryID = command.QueryID
					reply.Results = []Result{{Columns: []Column{{Name: "null", Type: "text"}, {Name: "empty", Type: "text"}, {Name: "literal", Type: "text"}, {Name: "number", Type: "numeric"}, {Name: "bytes", Type: "bytea", Encoding: "base64"}}, Rows: [][]*string{{nil, &empty, &literalNull, &exact, &binary}}, CommandTag: "SELECT 1", RowCount: 1}}
				}
				if encoder.Encode(reply) != nil {
					return
				}
			}
		}()
		return local, nil
	})
	for _, call := range []*mcp.CallToolParams{
		{Name: "dbeer_connections", Arguments: map[string]any{}},
		{Name: "dbeer_query", Arguments: map[string]any{"profileId": profileID, "queryId": queryID, "sql": "SELECT exact_values"}},
	} {
		result, err := client.CallTool(testContext(t), call)
		if err != nil || result.IsError {
			t.Fatalf("tool failed: %v, %+v", err, result)
		}
		if call.Name == "dbeer_query" {
			encoded, _ := json.Marshal(result.StructuredContent)
			for _, value := range []string{`[null,"","NULL","12345678901234567890.000000001","AAH/"]`, `"encoding":"base64"`, queryID} {
				if !strings.Contains(string(encoded), value) {
					t.Fatalf("exact value lost: %s", encoded)
				}
			}
		}
	}
	if dials.Load() != 1 {
		t.Fatal("tool calls did not retain one approval connection")
	}
	first, second, third := <-commands, <-commands, <-commands
	if first.Method != "hello" || first.ClientName != "test-client" || second.Method != "connections" || third.Method != "query" || third.MaxRows != 100 || third.TimeoutSeconds != 30 {
		t.Fatalf("invalid broker sequence: %+v %+v %+v", first, second, third)
	}
}

func TestSDKEngineCatalogAliasesAndCanonicalRequests(t *testing.T) {
	profileID := uuid.NewString()
	commands := make(chan request, 16)
	canonical := `{"database":"fixture_db","collection":"items","find":{"n":{"$numberLong":"9007199254740993"}},"sort":{"label":1,"n":-1},"limit":100}`
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
				if command.Method == "connections" {
					reply.Connections = []Connection{{ID: profileID, Name: "Document fixture", Engine: "mongodb", ReadOnly: true, QueryLanguage: "mongodb-json", ReadOnlyEnforcement: "local"}}
				}
				if command.Method == "query" || command.Method == "catalog" {
					known, document := false, canonical
					reply.Results = []Result{{Columns: []Column{{Name: "document", Type: "BSON document"}}, Rows: [][]*string{{&document}}, CommandTag: "FIND", RowCount: 1, DisplayNotice: "Fixture fields are sampled, not a schema.", AffectedRowCountKnown: &known}}
				}
				if encoder.Encode(reply) != nil {
					return
				}
			}
		}()
		return local, nil
	})
	connections, err := client.CallTool(testContext(t), &mcp.CallToolParams{Name: "dbeer_connections", Arguments: map[string]any{}})
	if err != nil || connections.IsError {
		t.Fatalf("connections failed: %v", err)
	}
	encoded, _ := json.Marshal(connections.StructuredContent)
	for _, expected := range []string{`"engine":"mongodb"`, `"queryLanguage":"mongodb-json"`, `"readOnlyEnforcement":"local"`} {
		if !strings.Contains(string(encoded), expected) {
			t.Fatalf("connection metadata lost: %s", encoded)
		}
	}
	if first, second := <-commands, <-commands; first.Method != "hello" || second.Method != "connections" {
		t.Fatal("connection did not require native approval")
	}
	for _, kind := range []string{"schemas", "keyspaces", "databases", "tables", "collections", "columns", "fields"} {
		arguments := map[string]any{"profileId": profileID, "kind": kind}
		switch kind {
		case "tables", "collections":
			arguments["schema"] = "fixture_db"
		case "columns", "fields":
			arguments["schema"], arguments["object"] = "fixture_db", "items"
		}
		result, err := client.CallTool(testContext(t), &mcp.CallToolParams{Name: "dbeer_catalog", Arguments: arguments})
		if err != nil || result.IsError {
			t.Fatalf("catalog alias %s rejected: %v", kind, err)
		}
		command := <-commands
		if command.Method != "catalog" || command.Kind != kind || !validUUID(command.QueryID) {
			t.Fatal("catalog alias or correlation changed")
		}
	}
	result, err := client.CallTool(testContext(t), &mcp.CallToolParams{Name: "dbeer_query", Arguments: map[string]any{"profileId": profileID, "queryId": uuid.NewString(), "sql": canonical}})
	if err != nil || result.IsError {
		t.Fatalf("canonical query failed: %v", err)
	}
	command := <-commands
	if command.SQL != canonical {
		t.Fatal("MongoDB JSON request order or exact scalar text was changed")
	}
	encoded, _ = json.Marshal(result.StructuredContent)
	var output toolOutput
	if json.Unmarshal(encoded, &output) != nil || len(output.Results) != 1 || output.Results[0].AffectedRowCountKnown == nil || *output.Results[0].AffectedRowCountKnown || output.Results[0].DisplayNotice == "" || *output.Results[0].Rows[0][0] != canonical {
		t.Fatal("typed SDK output lost canonical documents, sampled notice or explicit unknown affected count")
	}
}

func TestSDKRejectsInvalidToolArgumentsBeforeApproval(t *testing.T) {
	var dials atomic.Int32
	client := connectTestServer(t, func(context.Context) (net.Conn, error) { dials.Add(1); return nil, errUnavailable })
	for _, call := range []*mcp.CallToolParams{
		{Name: "dbeer_query", Arguments: map[string]any{"profileId": uuid.NewString(), "queryId": uuid.NewString(), "sql": "SELECT 1", "maxRows": 1001}},
		{Name: "dbeer_query", Arguments: map[string]any{"profileId": uuid.NewString(), "queryId": uuid.NewString(), "sql": "SELECT 1", "timeoutSeconds": -1}},
		{Name: "dbeer_query", Arguments: map[string]any{"profileId": "unknown", "queryId": uuid.NewString(), "sql": "SELECT 1"}},
		{Name: "dbeer_catalog", Arguments: map[string]any{"profileId": uuid.NewString(), "kind": "arbitrary-file"}},
		{Name: "dbeer_catalog", Arguments: map[string]any{"profileId": uuid.NewString(), "kind": "keyspaces", "schema": "unexpected"}},
		{Name: "dbeer_catalog", Arguments: map[string]any{"profileId": uuid.NewString(), "kind": "databases", "object": "unexpected"}},
		{Name: "dbeer_catalog", Arguments: map[string]any{"profileId": uuid.NewString(), "kind": "collections"}},
		{Name: "dbeer_catalog", Arguments: map[string]any{"profileId": uuid.NewString(), "kind": "fields", "schema": "fixture_db"}},
		{Name: "dbeer_cancel", Arguments: map[string]any{"queryId": "../file"}},
	} {
		result, err := client.CallTool(testContext(t), call)
		if err == nil && !result.IsError {
			t.Fatalf("invalid input accepted: %s", call.Name)
		}
	}
	if dials.Load() != 0 {
		t.Fatal("invalid arguments triggered native approval")
	}
}

func TestSDKConcurrentCancelTargetsPendingQuery(t *testing.T) {
	queryID := uuid.NewString()
	queryStarted := make(chan struct{})
	client := connectTestServer(t, func(context.Context) (net.Conn, error) {
		local, native := net.Pipe()
		t.Cleanup(func() { _ = native.Close() })
		go func() {
			decoder, encoder := json.NewDecoder(native), json.NewEncoder(native)
			var pending request
			for {
				var command request
				if decoder.Decode(&command) != nil {
					return
				}
				switch command.Method {
				case "hello":
					_ = encoder.Encode(response{ID: command.ID, OK: true})
				case "query":
					pending = command
					close(queryStarted)
				case "cancel":
					if command.QueryID != pending.QueryID {
						return
					}
					_ = encoder.Encode(response{ID: command.ID, OK: true, QueryID: command.QueryID})
					_ = encoder.Encode(response{ID: pending.ID, OK: false, Error: "The query was cancelled."})
				}
			}
		}()
		return local, nil
	})
	queryDone := make(chan error, 1)
	go func() {
		result, err := client.CallTool(testContext(t), &mcp.CallToolParams{Name: "dbeer_query", Arguments: map[string]any{"profileId": uuid.NewString(), "queryId": queryID, "sql": "SELECT 1"}})
		if err == nil && !result.IsError {
			err = errors.New("query unexpectedly completed")
		}
		queryDone <- err
	}()
	select {
	case <-queryStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("query did not start")
	}
	result, err := client.CallTool(testContext(t), &mcp.CallToolParams{Name: "dbeer_cancel", Arguments: map[string]any{"queryId": queryID}})
	if err != nil || result.IsError {
		t.Fatalf("concurrent cancel failed: %v", err)
	}
	select {
	case <-queryDone:
	case <-time.After(time.Second):
		t.Fatal("query not cancelled")
	}
}

func TestSDKCancellationReachesNativeUnderBlockedStdout(t *testing.T) {
	queryID := uuid.NewString()
	secondStarted := make(chan struct{})
	cancelled := make(chan string, 1)
	server, holder := newServer(func(context.Context) (net.Conn, error) {
		local, native := net.Pipe()
		t.Cleanup(func() { _ = native.Close() })
		go func() {
			decoder, encoder := json.NewDecoder(native), json.NewEncoder(native)
			queries := 0
			for {
				var command request
				if decoder.Decode(&command) != nil {
					return
				}
				switch command.Method {
				case "hello":
					_ = encoder.Encode(response{ID: command.ID, OK: true})
				case "query":
					queries++
					if queries == 1 {
						large := strings.Repeat("x", 256*1024)
						_ = encoder.Encode(response{ID: command.ID, OK: true, Results: []Result{{Columns: []Column{{Name: "large", Type: "text"}}, Rows: [][]*string{{&large}}, CommandTag: "SELECT 1", RowCount: 1}}})
					} else {
						close(secondStarted)
					}
				case "cancel":
					cancelled <- command.QueryID
					_ = encoder.Encode(response{ID: command.ID, OK: true})
				}
			}
		}()
		return local, nil
	})
	input, inputWriter := io.Pipe()
	outputReader, output := io.Pipe()
	session, err := server.Connect(testContext(t), &mcp.IOTransport{Reader: input, Writer: output, MaxLineLength: MaxRequestBytes}, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = outputReader.Close(); _ = inputWriter.Close(); _ = session.Close(); holder.close() })
	encoder := json.NewEncoder(inputWriter)
	if err := encoder.Encode(map[string]any{"jsonrpc": "2.0", "id": "init", "method": "initialize", "params": map[string]any{"protocolVersion": "2025-06-18", "clientInfo": map[string]any{"name": "test-client", "version": "1"}, "capabilities": map[string]any{}}}); err != nil {
		t.Fatal(err)
	}
	if _, err := bufio.NewReader(outputReader).ReadBytes('\n'); err != nil {
		t.Fatal(err)
	}
	_ = encoder.Encode(map[string]any{"jsonrpc": "2.0", "method": "notifications/initialized"})
	for index, id := range []string{uuid.NewString(), queryID} {
		if err := encoder.Encode(map[string]any{"jsonrpc": "2.0", "id": index + 1, "method": "tools/call", "params": map[string]any{"name": "dbeer_query", "arguments": map[string]any{"profileId": uuid.NewString(), "queryId": id, "sql": "SELECT 1"}}}); err != nil {
			t.Fatal(err)
		}
	}
	select {
	case <-secondStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("second query blocked behind stdout")
	}
	if err := encoder.Encode(map[string]any{"jsonrpc": "2.0", "method": "notifications/cancelled", "params": map[string]any{"requestId": 2}}); err != nil {
		t.Fatal(err)
	}
	select {
	case id := <-cancelled:
		if id != queryID {
			t.Fatal("wrong query cancelled")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("native cancellation blocked behind stdout")
	}
}
