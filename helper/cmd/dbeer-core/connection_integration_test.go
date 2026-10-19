package main

import (
	"context"
	"encoding/json"
	"io"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
)

// Runs the real protocol dispatcher and real pgx session. Credentials are read
// exclusively from the integration environment and are never printed.
func TestPostgresConnectionLifecycle(t *testing.T) {
	dsn := os.Getenv("DBEER_TEST_DSN")
	if dsn == "" {
		t.Skip("DBEER_TEST_DSN is not configured")
	}
	config, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal("invalid integration connection settings")
	}
	mode := "disable"
	ca := ""
	if parsed, err := url.Parse(dsn); err == nil && parsed.Scheme != "" {
		if value := parsed.Query().Get("sslmode"); value != "" {
			mode = value
		}
		ca = parsed.Query().Get("sslrootcert")
	} else if config.TLSConfig != nil {
		t.Fatal("integration DSN with TLS must use URL syntax")
	}
	connection := protocol.Connection{Host: config.Host, Port: int(config.Port), Database: config.Database, User: config.User, Password: config.Password, SSLMode: mode, SSLRootCert: ca}
	config.RuntimeParams["application_name"] = "DBeer connection test observer"
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	observer, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		t.Fatal("cannot connect integration observer")
	}
	defer observer.Close(context.Background())
	backendPIDs := func() map[int32]bool {
		t.Helper()
		rows, err := observer.Query(ctx, "SELECT pid FROM pg_stat_activity WHERE application_name='DBeer' AND datname=current_database() AND usename=current_user")
		if err != nil {
			t.Fatal("cannot inspect PostgreSQL sessions")
		}
		defer rows.Close()
		pids := make(map[int32]bool)
		for rows.Next() {
			var pid int32
			if rows.Scan(&pid) != nil {
				t.Fatal("cannot decode PostgreSQL session")
			}
			pids[pid] = true
		}
		if rows.Err() != nil {
			t.Fatal("cannot inspect PostgreSQL sessions")
		}
		return pids
	}
	baseline := backendPIDs()
	input, helperInput := io.Pipe()
	helperOutput, output := io.Pipe()
	done := make(chan error, 1)
	go func() { done <- run(input, output); output.Close() }()
	responses := make(chan protocol.Response)
	go func() {
		defer close(responses)
		decoder := json.NewDecoder(helperOutput)
		for {
			var response protocol.Response
			if decoder.Decode(&response) != nil {
				return
			}
			select {
			case responses <- response:
			case <-ctx.Done():
				return
			}
		}
	}()
	defer helperOutput.Close()
	defer input.Close()
	defer helperInput.Close()
	encoder := json.NewEncoder(helperInput)
	roundTrip := func(command protocol.Command) protocol.Response {
		t.Helper()
		if encoder.Encode(command) != nil {
			t.Fatal("cannot write integration command")
		}
		select {
		case response, ok := <-responses:
			if !ok || response.RequestID != command.RequestID {
				t.Fatal("unexpected integration response")
			}
			return response
		case <-ctx.Done():
			t.Fatal("helper protocol did not respond")
		}
		return protocol.Response{}
	}
	if response := roundTrip(protocol.Command{Type: "hello", RequestID: "hello", ProtocolVersion: protocol.Version}); response.Type != "hello.ack" {
		t.Fatal("handshake failed")
	}
	incorrect := connection
	incorrect.Password = "DBeer deliberately incorrect password ' \\"
	response := roundTrip(protocol.Command{Type: "connect", RequestID: "bad-password", Connection: &incorrect})
	if response.Type != "error" || response.Category != "connection" || response.SQLState != "28P01" || strings.Contains(response.Message, incorrect.Password) {
		t.Fatal("authentication failure was not safely reported")
	}
	response = roundTrip(protocol.Command{Type: "connect", RequestID: "connect", Connection: &connection})
	if response.Type != "connect.result" || !protocol.ValidID(response.SessionID) || response.TransactionStatus != "idle" {
		t.Fatal("connection failed")
	}
	session := response.SessionID
	var backendPID int32
	for pid := range backendPIDs() {
		if !baseline[pid] {
			backendPID = pid
		}
	}
	if backendPID == 0 {
		t.Fatal("helper did not establish a physical PostgreSQL session")
	}
	queryTerminal := func(command protocol.Command) protocol.Response {
		t.Helper()
		select {
		case response, ok := <-responses:
			if !ok || response.RequestID != command.RequestID || response.QueryID != command.QueryID || response.SessionID != session || response.Type != "query.result" && response.Type != "error" {
				t.Fatal("execute did not have exactly one correlated terminal reply")
			}
			return response
		case <-ctx.Done():
			t.Fatal("execute did not complete")
		}
		return protocol.Response{}
	}
	query := protocol.Command{Type: "execute", RequestID: "sql-values", SessionID: session, QueryID: "query-values", SQL: "SELECT NULL::text AS x, ''::text AS x, 'NULL'::text AS x, E'κόσμος\\n🌍'::text AS unicode, 9223372036854775807::bigint, 1234567890.1234567890123456789::numeric"}
	if response := roundTrip(query); response.Type != "query.started" || response.QueryID != query.QueryID {
		t.Fatal("execute did not publish query.started over NDJSON")
	}
	response = queryTerminal(query)
	if response.Type != "query.result" || len(response.Columns) != 6 || len(response.Rows) != 1 || response.Rows[0][0] != nil || *response.Rows[0][1] != "" || *response.Rows[0][2] != "NULL" || *response.Rows[0][3] != "κόσμος\n🌍" || *response.Rows[0][4] != "9223372036854775807" || *response.Rows[0][5] != "1234567890.1234567890123456789" {
		t.Fatal("SQL text/null/precision contract did not survive NDJSON")
	}
	query = protocol.Command{Type: "execute", RequestID: "sql-sleep", SessionID: session, QueryID: "query-sleep", SQL: "SELECT pg_sleep(10)"}
	if response := roundTrip(query); response.Type != "query.started" {
		t.Fatal("long query did not start")
	}
	if response := roundTrip(protocol.Command{Type: "cancel", RequestID: "stop", SessionID: session, QueryID: query.QueryID}); response.Type != "cancel.ack" || response.Status != "accepted" {
		t.Fatal("Stop did not receive its separate acknowledgement")
	}
	response = queryTerminal(query)
	if response.Type != "error" || response.Category != "cancelled" || !response.Connected || response.TransactionStatus != "idle" || response.OutcomeUnknown {
		t.Fatal("cancel did not recover a known PostgreSQL session outcome")
	}
	response = roundTrip(protocol.Command{Type: "connect", RequestID: "replace", Connection: &connection})
	if response.Type != "connect.result" || response.SessionID == session {
		t.Fatal("second connect did not create an independent session")
	}
	if result := roundTrip(protocol.Command{Type: "disconnect", RequestID: "disconnect-second", SessionID: response.SessionID}); result.Type != "disconnect.ack" {
		t.Fatal("second session did not disconnect")
	}
	response = roundTrip(protocol.Command{Type: "disconnect", RequestID: "wrong-session", SessionID: "unknown"})
	if response.Type != "error" || response.Connected {
		t.Fatal("unknown session was incorrectly reported as connected")
	}
	response = roundTrip(protocol.Command{Type: "disconnect", RequestID: "disconnect", SessionID: session})
	if response.Type != "disconnect.ack" || response.SessionID != session {
		t.Fatal("disconnect failed")
	}
	assertBackendClosed := func(pid int32) {
		t.Helper()
		deadline := time.Now().Add(2 * time.Second)
		for backendPIDs()[pid] {
			if time.Now().After(deadline) {
				t.Fatal("helper left a PostgreSQL backend open")
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
	assertBackendClosed(backendPID)
	response = roundTrip(protocol.Command{Type: "connect", RequestID: "reconnect", Connection: &connection})
	if response.Type != "connect.result" || response.SessionID == session {
		t.Fatal("new connection did not receive a new session identifier")
	}
	for pid := range backendPIDs() {
		if !baseline[pid] {
			backendPID = pid
		}
	}
	if response := roundTrip(protocol.Command{Type: "shutdown", RequestID: "shutdown"}); response.Type != "shutdown.ack" {
		t.Fatal("shutdown failed")
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal("helper shutdown failed")
		}
	case <-ctx.Done():
		t.Fatal("helper did not exit")
	}
	assertBackendClosed(backendPID)
}
