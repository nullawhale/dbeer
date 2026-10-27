package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

func runMessages(t *testing.T, input string) []protocol.Response {
	t.Helper()
	var output bytes.Buffer
	if err := run(strings.NewReader(input), &output); err != nil {
		t.Fatal(err)
	}
	var responses []protocol.Response
	decoder := json.NewDecoder(&output)
	for {
		var response protocol.Response
		if err := decoder.Decode(&response); errors.Is(err, io.EOF) {
			return responses
		} else if err != nil {
			t.Fatal(err)
		}
		responses = append(responses, response)
	}
}

func TestHandshakeAndShutdown(t *testing.T) {
	responses := runMessages(t, "{\"type\":\"hello\",\"requestId\":\"h1\",\"protocolVersion\":5}\n{\"type\":\"shutdown\",\"requestId\":\"s1\"}\n{\"type\":\"shutdown\",\"requestId\":\"ignored\"}\n")
	if len(responses) != 2 || responses[0].Type != "hello.ack" || responses[0].RequestID != "h1" || responses[0].ProtocolVersion != protocol.Version || responses[1].Type != "shutdown.ack" || responses[1].RequestID != "s1" {
		t.Fatalf("unexpected handshake/shutdown responses: %+v", responses)
	}
}

func TestShutdownWithoutHandshake(t *testing.T) {
	responses := runMessages(t, "{\"type\":\"shutdown\",\"requestId\":\"shutdown-1\"}\n")
	if len(responses) != 1 || responses[0].Type != "shutdown.ack" {
		t.Fatalf("unexpected shutdown response: %+v", responses)
	}
}

func TestEOFExitsQuietly(t *testing.T) {
	if responses := runMessages(t, ""); len(responses) != 0 {
		t.Fatal("EOF must not produce protocol output")
	}
}

func TestMalformedFrameIsSafeAndNextFrameWorks(t *testing.T) {
	const secret = "secret-password"
	var output bytes.Buffer
	if err := run(strings.NewReader(secret+"\n{\"type\":\"shutdown\",\"requestId\":\"s1\"}\n"), &output); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(output.String(), secret) {
		t.Fatal("invalid input must not be echoed")
	}
	responses := runMessages(t, secret+"\n{\"type\":\"shutdown\",\"requestId\":\"s1\"}\n")
	if len(responses) != 2 || responses[0].Category != "protocol" || responses[0].RequestID != "" || responses[1].Type != "shutdown.ack" {
		t.Fatalf("unexpected error recovery: %+v", responses)
	}
}

func TestVersionAndHandshakeRequired(t *testing.T) {
	responses := runMessages(t, "{\"type\":\"disconnect\",\"requestId\":\"r1\",\"sessionId\":\"s1\"}\n{\"type\":\"hello\",\"requestId\":\"r2\",\"protocolVersion\":1}\n{\"type\":\"hello\",\"requestId\":\"r3\",\"protocolVersion\":5}\n")
	if len(responses) != 3 || responses[0].Category != "protocol" || !strings.Contains(responses[0].Message, "handshake") || !strings.Contains(responses[1].Message, "version") || responses[2].Type != "hello.ack" {
		t.Fatalf("unexpected version handling: %+v", responses)
	}
}

func TestIdentifiersCannotBeReused(t *testing.T) {
	responses := runMessages(t, "{\"type\":\"hello\",\"requestId\":\"r1\",\"protocolVersion\":5}\n{\"type\":\"hello\",\"requestId\":\"r1\",\"protocolVersion\":5}\n{\"type\":\"execute\",\"requestId\":\"r2\",\"sessionId\":\"s1\",\"queryId\":\"q1\",\"sql\":\"select 1\"}\n{\"type\":\"execute\",\"requestId\":\"r3\",\"sessionId\":\"s1\",\"queryId\":\"q1\",\"sql\":\"select 1\"}\n{\"type\":\"shutdown\",\"requestId\":\"shutdown\"}\n")
	queryRejected := false
	for _, response := range responses {
		if response.RequestID == "r3" && strings.Contains(response.Message, "already been used") {
			queryRejected = true
		}
	}
	if len(responses) != 5 || !strings.Contains(responses[1].Message, "already been used") || !queryRejected {
		t.Fatalf("unexpected duplicate ID handling: %+v", responses)
	}
}

func TestExecuteWithoutSessionHasOneSafeTerminalResponse(t *testing.T) {
	responses := runMessages(t, "{\"type\":\"hello\",\"requestId\":\"r1\",\"protocolVersion\":5}\n{\"type\":\"execute\",\"requestId\":\"r2\",\"sessionId\":\"s1\",\"queryId\":\"q1\",\"sql\":\"secret-password\"}\n{\"type\":\"shutdown\",\"requestId\":\"r3\"}\n")
	if len(responses) != 3 || responses[1].Category != "connection" || responses[1].Connected || strings.Contains(responses[1].Message, "secret-password") {
		t.Fatalf("unexpected unavailable response: %+v", responses)
	}
}

func TestBurstCommandsDrainResponsesWithoutDeadlock(t *testing.T) {
	var input strings.Builder
	input.WriteString("{\"type\":\"hello\",\"requestId\":\"hello\",\"protocolVersion\":5}\n")
	for index := range 200 {
		fmt.Fprintf(&input, "{\"type\":\"disconnect\",\"requestId\":\"r%d\",\"sessionId\":\"absent\"}\n", index)
	}
	input.WriteString("{\"type\":\"shutdown\",\"requestId\":\"shutdown\"}\n")
	done := make(chan error, 1)
	var output bytes.Buffer
	go func() { done <- run(strings.NewReader(input.String()), &output) }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("command dispatch and response backpressure deadlocked")
	}
	decoder := json.NewDecoder(&output)
	count := 0
	for decoder.More() {
		var response protocol.Response
		if decoder.Decode(&response) != nil {
			t.Fatal("invalid response")
		}
		count++
	}
	if count != 202 {
		t.Fatalf("expected one terminal response per command, got %d", count)
	}
}
