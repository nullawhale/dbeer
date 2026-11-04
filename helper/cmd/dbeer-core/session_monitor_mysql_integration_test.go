package main

import (
	"encoding/json"
	"io"
	"os"
	"slices"
	"strconv"
	"testing"
	"time"

	"dbeer/helper/internal/mysql"
	"dbeer/helper/internal/protocol"
)

// Exercise real MySQL through the same strict parsing, manager, framing and
// serialization path used by the native client, not only the adapter method.
func TestMySQLMonitorRealClosedProtocolLifecycle(t *testing.T) {
	port, err := strconv.Atoi(os.Getenv("DBEER_TEST_MYSQL_PORT"))
	if err != nil || port < 1 {
		if os.Getenv("DBEER_REQUIRE_MYSQL") == "1" {
			t.Fatal("required disposable MySQL fixture is missing")
		}
		t.Skip("DBEER_TEST_MYSQL_PORT is not configured")
	}
	host := os.Getenv("DBEER_TEST_MYSQL_HOST")
	if host == "" {
		host = "localhost"
	}
	mode := os.Getenv("DBEER_TEST_MYSQL_SSLMODE")
	if mode == "" {
		mode = "disable"
	}
	connection := protocol.Connection{Engine: "mysql", SessionPurpose: "monitor", Host: host, Port: port,
		Database: os.Getenv("DBEER_TEST_MYSQL_DATABASE"), User: os.Getenv("DBEER_TEST_MYSQL_USER"),
		Password: os.Getenv("DBEER_TEST_MYSQL_PASSWORD"), SSLMode: mode, SSLRootCert: os.Getenv("DBEER_TEST_MYSQL_CA_FILE")}
	if os.Getenv("DBEER_TEST_MYSQL_MONITOR_PRIVILEGES") == "1" {
		connection.User, connection.Password = os.Getenv("DBEER_TEST_MYSQL_MONITOR_USER"), os.Getenv("DBEER_TEST_MYSQL_MONITOR_PASSWORD")
	}
	input, writer := io.Pipe()
	reader, output := io.Pipe()
	defer input.Close()
	defer writer.Close()
	defer reader.Close()
	defer output.Close()
	done := make(chan error, 1)
	go func() { done <- runWithFactory(input, output, mysql.Open) }()
	responses := make(chan protocol.Response, 8)
	go func() {
		defer close(responses)
		decoder := json.NewDecoder(reader)
		for {
			var response protocol.Response
			if decoder.Decode(&response) != nil {
				return
			}
			responses <- response
		}
	}()
	encoder := json.NewEncoder(writer)
	send := func(command protocol.Command) {
		t.Helper()
		if encoder.Encode(command) != nil {
			t.Fatal("cannot send live MySQL monitor command")
		}
	}
	receive := func() protocol.Response {
		t.Helper()
		select {
		case response, ok := <-responses:
			if !ok {
				t.Fatal("live MySQL monitor protocol closed without its terminal response")
			}
			return response
		case <-time.After(8 * time.Second):
			t.Fatal("live MySQL monitor protocol did not respond promptly")
			return protocol.Response{}
		}
	}
	send(protocol.Command{Type: "hello", RequestID: "live-mysql-hello", ProtocolVersion: protocol.Version})
	if reply := receive(); reply.Type != "hello.ack" || !slices.Contains(reply.Capabilities, protocol.SessionMonitorCapability) {
		t.Fatal("live helper did not advertise monitor capability")
	}
	send(protocol.Command{Type: "connect", RequestID: "live-mysql-connect", Connection: &connection})
	connected := receive()
	if connected.Type != "connect.result" || connected.Engine != "mysql" || connected.TransactionStatus != "idle" || !slices.Contains(connected.Capabilities, protocol.SessionMonitorCapability) {
		t.Fatalf("live MySQL monitor connection failed: type=%s category=%s SQLSTATE=%s", connected.Type, connected.Category, connected.SQLState)
	}
	for index := range 2 {
		id := "live-mysql-snapshot-" + strconv.Itoa(index)
		command := protocol.Command{Type: "monitor.snapshot", RequestID: id, SessionID: connected.SessionID, QueryID: id}
		send(command)
		started, terminal := receive(), receive()
		if started.Type != "query.started" || terminal.Type != "monitor.result" || !terminal.Connected || terminal.TransactionStatus != "idle" ||
			terminal.Monitor == nil || terminal.Monitor.Engine != "mysql" || !terminal.Monitor.Valid() ||
			terminal.RequestID != id || terminal.QueryID != id || terminal.SessionID != connected.SessionID {
			t.Fatalf("live MySQL monitor result did not survive its full protocol boundary: type=%s category=%s connected=%t", terminal.Type, terminal.Category, terminal.Connected)
		}
	}
	send(protocol.Command{Type: "disconnect", RequestID: "live-mysql-disconnect", SessionID: connected.SessionID})
	if reply := receive(); reply.Type != "disconnect.ack" {
		t.Fatal("live MySQL monitor did not release its physical connection")
	}
	send(protocol.Command{Type: "shutdown", RequestID: "live-mysql-shutdown"})
	if reply := receive(); reply.Type != "shutdown.ack" {
		t.Fatal("live MySQL monitor helper did not acknowledge shutdown")
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal("live MySQL monitor helper did not exit cleanly")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("live MySQL monitor helper did not finish shutdown")
	}
}
