package mcpbridge

import (
	"context"
	"encoding/json"
	"net"
	"reflect"
	"strings"
	"testing"

	"dbeer/helper/internal/nativevalue"
	"dbeer/helper/internal/sqlitevalue"
	"github.com/google/uuid"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestSDKNativeResultsPreserveRecursiveEvidenceAndEmptyMatrices(t *testing.T) {
	text := "formatted"
	matrix := [][]nativevalue.NativeValue{{{Kind: "object", Entries: []nativevalue.NativeEntry{
		{Key: nativevalue.NativeScalar("text", "e\u0301"), Value: nativevalue.NativeScalar("integer", "9007199254740993")},
		{Key: nativevalue.NativeScalar("text", "e\u0301"), Value: nativevalue.NativeBinary([]byte{0, 255})},
	}}}}
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
				reply := response{ID: command.ID, OK: true}
				if command.Method == "query" {
					if command.SQL == "empty" {
						empty := [][]nativevalue.NativeValue{}
						sqlite := [][]sqlitevalue.Value{}
						reply.Results = []Result{{Columns: []Column{}, Rows: [][]*string{}, NativeValues: &empty, SQLiteValues: &sqlite, CommandTag: "SELECT", Truncated: true}}
					} else {
						reply.Results = []Result{{Columns: []Column{{Name: "document", Type: "BSON document"}}, Rows: [][]*string{{&text}}, NativeValues: &matrix, CommandTag: "FIND", RowCount: 1}}
					}
				}
				if encoder.Encode(reply) != nil {
					return
				}
			}
		}()
		return local, nil
	})
	for _, sql := range []string{"native", "empty"} {
		reply, err := client.CallTool(testContext(t), &mcp.CallToolParams{Name: "dbeer_query", Arguments: map[string]any{"profileId": uuid.NewString(), "queryId": uuid.NewString(), "sql": sql}})
		if err != nil || reply.IsError {
			t.Fatal("native SDK result could not be returned")
		}
		data, err := json.Marshal(reply.StructuredContent)
		if err != nil {
			t.Fatal(err)
		}
		var output toolOutput
		if json.Unmarshal(data, &output) != nil || len(output.Results) != 1 || output.Results[0].NativeValues == nil {
			t.Fatal("MCP discarded native result evidence")
		}
		if sql == "native" && !reflect.DeepEqual(*output.Results[0].NativeValues, matrix) {
			t.Fatal("MCP changed kinds, exact payload, duplicate keys or entry order")
		}
		if sql == "empty" && (!strings.Contains(string(data), `"nativeValues":[]`) || !strings.Contains(string(data), `"sqliteValues":[]`)) {
			t.Fatal("MCP omitted an explicit empty typed matrix")
		}
	}
}

func TestMCPResultRejectsMalformedNativeMatricesAndConflictingSQLiteStorage(t *testing.T) {
	valid := `{"columns":[{"name":"v","type":"text"}],"rows":[["display"]],"nativeValues":[[{"kind":"text","value":"exact"}]],"commandTag":"SELECT","rowCount":1,"truncated":false}`
	for _, bad := range []string{
		strings.Replace(valid, `"nativeValues":[[{"kind":"text","value":"exact"}]]`, `"nativeValues":[]`, 1),
		strings.Replace(valid, `"nativeValues":[[{"kind":"text","value":"exact"}]]`, `"nativeValues":null`, 1),
		strings.Replace(valid, `"kind":"text"`, `"kind":"future"`, 1),
		strings.Replace(valid, `"value":"exact"`, `"value":"\ud800"`, 1),
		strings.Replace(valid, `"kind":"text"`, `"kind":"text","kind":"text"`, 1),
		strings.Replace(valid, `"kind":"text","value":"exact"`, `"kind":"integer","value":"1","engine":"sqlite","nativeType":"integer"`, 1),
		strings.Replace(valid, `"nativeValues":[[{"kind":"text","value":"exact"}]]`, `"nativeValues":[[{"kind":"integer","value":"1","engine":"sqlite","nativeType":"integer"}]],"sqliteValues":[[{"type":"integer","value":"2"}]]`, 1),
	} {
		var value Result
		if json.Unmarshal([]byte(bad), &value) == nil {
			t.Fatal("malformed or conflicting native evidence accepted")
		}
	}
	var value Result
	if json.Unmarshal([]byte(valid), &value) != nil || value.NativeValues == nil {
		t.Fatal("valid native row rejected")
	}
	legacy := `{"columns":[{"name":"v","type":"text"}],"rows":[["exact"]],"commandTag":"SELECT","rowCount":1,"truncated":false}`
	if json.Unmarshal([]byte(legacy), &value) != nil || value.NativeValues != nil {
		t.Fatal("legacy MCP SQL ABI changed")
	}
}
