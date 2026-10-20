package protocol

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"testing"
)

func TestSharedCommandFixtures(t *testing.T) {
	file, err := os.Open("../../../protocol/fixtures/commands.ndjson")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	reader := NewReader(file)
	count := 0
	for {
		command, err := reader.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatalf("fixture %d: %v", count+1, err)
		}
		if !ValidID(command.RequestID) {
			t.Fatal("fixture has invalid request identifier")
		}
		count++
	}
	if count != 10 {
		t.Fatalf("expected one fixture per command, got %d", count)
	}
}

func TestCompletionCatalogRequestValidation(t *testing.T) {
	for _, request := range []CatalogRequest{{Kind: "completion"}, {Kind: "completion", Schema: `quoted' schema`, Page: 1}} {
		if !request.Valid() {
			t.Fatal("valid metadata batch rejected")
		}
	}
	for _, request := range []CatalogRequest{
		{Kind: "completion", Page: -1}, {Kind: "completion", Object: "table"},
		{Kind: "completion", Search: "prefix"}, {Kind: "completion", ObjectKind: "table"},
		{Kind: "completion", Sort: []CatalogSort{{Column: "name", Direction: "asc"}}},
		{Kind: "schemas", Page: 1}, {Kind: "objects", Schema: "public", ObjectKind: "table", Page: 1},
	} {
		if request.Valid() {
			t.Fatal("invalid metadata batch accepted")
		}
	}
}

func TestSharedResponseFixturesRoundTrip(t *testing.T) {
	file, err := os.Open("../../../protocol/fixtures/responses.ndjson")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	count := 0
	for scanner.Scan() {
		var response Response
		if err := json.Unmarshal(scanner.Bytes(), &response); err != nil {
			t.Fatal(err)
		}
		encoded, err := json.Marshal(response)
		if err != nil {
			t.Fatal(err)
		}
		var before, after any
		if json.Unmarshal(scanner.Bytes(), &before) != nil || json.Unmarshal(encoded, &after) != nil {
			t.Fatal("cannot decode response fixture")
		}
		beforeJSON, _ := json.Marshal(before)
		afterJSON, _ := json.Marshal(after)
		if !bytes.Equal(beforeJSON, afterJSON) {
			t.Fatalf("response fixture did not round-trip: before %s after %s", beforeJSON, afterJSON)
		}
		count++
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	if count < 8 {
		t.Fatalf("missing response fixtures: %d", count)
	}
}

func TestInvalidCommands(t *testing.T) {
	tests := []string{
		`null`, `[]`, `{}`, `{"type":"shutdown"}`, `{"type":"shutdown","requestId":null}`,
		`{"type":"shutdown","requestId":""}`, `{"type":"shutdown","requestId":5}`,
		`{"type":"shutdown","requestId":"r1","password":"secret"}`,
		`{"type":"shutdown","requestId":"r1","requestId":"r2"}`,
		`{"type":"hello","requestId":"r1","protocolVersion":null}`,
		`{"type":"hello","requestId":"r1","protocolVersion":1.1}`,
		`{"type":"hello","requestId":"r1"}`,
		`{"type":"execute","requestId":"r1","sessionId":"s1","queryId":"q1"}`,
		`{"type":"execute","requestId":"r1","sessionId":"s1","queryId":"q1","sql":null}`,
		`{"type":"cancel","requestId":"r1","sessionId":"s1","queryId":""}`,
		`{"type":"disconnect","requestId":"r1","sessionId":""}`,
		`{"type":"unrecognized-secret","requestId":"r1","password":"secret"}`,
		`{"type":"shutdown","requestId":"` + strings.Repeat("a", MaxIDBytes+1) + `"}`,
		string([]byte{'{', '"', 0xff, '"', ':', '1', '}'}),
	}
	for _, input := range tests {
		t.Run(fmt.Sprintf("%q", input[:min(len(input), 70)]), func(t *testing.T) {
			_, err := ParseCommand([]byte(input))
			var invalid *ProtocolError
			if !errors.As(err, &invalid) || strings.Contains(err.Error(), "secret") {
				t.Fatalf("expected safe protocol error, got %v", err)
			}
		})
	}
}

func TestIDLimitsAreUTF8ByteCounts(t *testing.T) {
	if !ValidID(strings.Repeat("é", 64)) || ValidID(strings.Repeat("é", 65)) {
		t.Fatal("IDs must be limited by UTF-8 bytes")
	}
}

func TestDatabaseEngineMigrationAndValidation(t *testing.T) {
	for _, engine := range []string{"", "postgresql", "mysql"} {
		connection := Connection{Engine: engine, Host: "localhost", Port: 5432, Database: "db", User: "user", Password: "", SSLMode: "verify-full"}
		frame, err := json.Marshal(Command{Type: "connect", RequestID: "engine", Connection: &connection})
		if err != nil {
			t.Fatal(err)
		}
		command, err := ParseCommand(frame)
		if err != nil || command.Connection.DatabaseEngine() != connection.DatabaseEngine() {
			t.Fatal("engine did not round-trip or legacy engine lost PostgreSQL semantics")
		}
	}
	for _, engine := range []string{`"sqlite"`, `null`, `3`, `true`} {
		frame := `{"type":"connect","requestId":"bad-engine","connection":{"engine":` + engine + `,"host":"localhost","port":5432,"database":"db","user":"user","password":"","sslMode":"disable"}}`
		if _, err := ParseCommand([]byte(frame)); err == nil {
			t.Fatal("unsupported or malformed database engine was accepted")
		}
	}
}

type chunkedReader struct {
	input []byte
	size  int
}

func (reader *chunkedReader) Read(output []byte) (int, error) {
	if len(reader.input) == 0 {
		return 0, io.EOF
	}
	count := min(len(output), reader.size, len(reader.input))
	copy(output, reader.input[:count])
	reader.input = reader.input[count:]
	return count, nil
}

func TestFramesAcrossArbitraryReadBoundaries(t *testing.T) {
	input := []byte("{\"type\":\"hello\",\"requestId\":\"κόσμος\",\"protocolVersion\":4}\n{\"type\":\"shutdown\",\"requestId\":\"s1\"}\n")
	for _, size := range []int{1, 2, 7, len(input)} {
		reader := NewReader(&chunkedReader{input: input, size: size})
		for _, expected := range []string{"hello", "shutdown"} {
			command, err := reader.Read()
			if err != nil || command.Type != expected {
				t.Fatalf("chunk size %d: command %+v, error %v", size, command, err)
			}
		}
		if _, err := reader.Read(); !errors.Is(err, io.EOF) {
			t.Fatalf("chunk size %d: expected EOF, got %v", size, err)
		}
	}
}

func TestFrameSizeLimitAndRecovery(t *testing.T) {
	prefix := `{"type":"execute","requestId":"r1","sessionId":"s1","queryId":"q1","sql":"`
	suffix := `"}`
	frame := prefix + strings.Repeat(" ", MaxFrameBytes-len(prefix)-len(suffix)) + suffix
	reader := NewReader(strings.NewReader(frame + "\n" + frame + " \n{\"type\":\"shutdown\",\"requestId\":\"s1\"}\n"))
	if command, err := reader.Read(); err != nil || command.Type != "execute" {
		t.Fatalf("exactly maximum-sized frame must succeed: %v", err)
	}
	if _, err := reader.Read(); err == nil || !strings.Contains(err.Error(), "size limit") {
		t.Fatalf("oversized frame must fail: %v", err)
	}
	if command, err := reader.Read(); err != nil || command.Type != "shutdown" {
		t.Fatalf("reader must resume at next frame: %v", err)
	}
}

func TestUnterminatedFrameDoesNotExecute(t *testing.T) {
	reader := NewReader(strings.NewReader(`{"type":"shutdown","requestId":"s1"}`))
	if _, err := reader.Read(); err == nil || !strings.Contains(err.Error(), "newline") {
		t.Fatalf("expected incomplete frame error, got %v", err)
	}
	if _, err := reader.Read(); !errors.Is(err, io.EOF) {
		t.Fatalf("expected EOF, got %v", err)
	}
}

func TestConcurrentWriterPreservesWholeFrames(t *testing.T) {
	var output bytes.Buffer
	writer := NewWriter(&output)
	var group sync.WaitGroup
	for index := range 100 {
		group.Go(func() {
			if err := writer.Write(Response{Type: "shutdown.ack", RequestID: fmt.Sprintf("r%d", index)}); err != nil {
				t.Error(err)
			}
		})
	}
	group.Wait()
	scanner := bufio.NewScanner(&output)
	seen := make(map[string]bool)
	for scanner.Scan() {
		var response Response
		if err := json.Unmarshal(scanner.Bytes(), &response); err != nil {
			t.Fatal(err)
		}
		if seen[response.RequestID] {
			t.Fatal("duplicate response")
		}
		seen[response.RequestID] = true
	}
	if scanner.Err() != nil || len(seen) != 100 {
		t.Fatalf("expected 100 complete frames, got %d: %v", len(seen), scanner.Err())
	}
}

func TestResultPreservesNullEmptyAndDuplicateColumns(t *testing.T) {
	empty, literal := "", "NULL"
	response := Response{Type: "query.result", RequestID: "r1", SessionID: "s1", QueryID: "q1",
		Columns: []Column{{Index: 0, Name: "x", TypeOID: 25}, {Index: 1, Name: "x", TypeOID: 25}, {Index: 2, Name: "x", TypeOID: 25}},
		Rows:    [][]*string{{nil, &empty, &literal}}, TransactionStatus: "idle"}
	frame, err := json.Marshal(response)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(frame, []byte(`"rows":[[null,"","NULL"]]`)) || !bytes.Contains(frame, []byte(`"truncated":false`)) || !bytes.Contains(frame, []byte(`"rowCount":0`)) {
		t.Fatalf("result lost required values: %s", frame)
	}
}
