package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"strconv"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
)

func TestPostgresBackpressureControlWithSixteenRealSessions(t *testing.T) {
	dsn := os.Getenv("DBEER_TEST_DSN")
	if dsn == "" {
		t.Skip("DBEER_TEST_DSN is not configured")
	}
	config, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal("invalid PostgreSQL integration configuration")
	}
	mode, ca := "disable", ""
	if parsed, err := url.Parse(dsn); err == nil && parsed.Scheme != "" {
		if value := parsed.Query().Get("sslmode"); value != "" {
			mode = value
		}
		ca = parsed.Query().Get("sslrootcert")
	} else if config.TLSConfig != nil {
		t.Fatal("TLS integration configuration requires URL syntax")
	}
	settings := protocol.Connection{Host: config.Host, Port: int(config.Port), Database: config.Database, User: config.User, Password: config.Password, SSLMode: mode, SSLRootCert: ca}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	observer, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		t.Fatal("cannot connect PostgreSQL backpressure observer")
	}
	defer observer.Close(context.Background())
	for _, shutdown := range []bool{false, true} {
		t.Run(fmt.Sprint("shutdown=", shutdown), func(t *testing.T) {
			input, inputWriter := io.Pipe()
			outputReader, output := io.Pipe()
			defer input.Close()
			defer inputWriter.Close()
			defer outputReader.Close()
			defer output.Close()
			done := make(chan error, 1)
			go func() { done <- run(input, output) }()
			encoder := json.NewEncoder(inputWriter)
			decoder := json.NewDecoder(outputReader)
			encode := func(command protocol.Command) {
				t.Helper()
				if encoder.Encode(command) != nil {
					t.Fatal("cannot write PostgreSQL backpressure command")
				}
			}
			rpc := func(command protocol.Command) protocol.Response {
				t.Helper()
				encode(command)
				var response protocol.Response
				if decoder.Decode(&response) != nil || response.RequestID != command.RequestID {
					t.Fatal("PostgreSQL backpressure setup lost a reply")
				}
				return response
			}
			rpc(protocol.Command{Type: "hello", RequestID: "hello", ProtocolVersion: protocol.Version})
			var sessions []string
			var pids []int32
			for index := range 16 {
				response := rpc(protocol.Command{Type: "connect", RequestID: fmt.Sprint("connect-", index), Connection: &settings})
				if response.Type != "connect.result" {
					t.Fatal("cannot open real backpressure session")
				}
				sessions = append(sessions, response.SessionID)
				command := protocol.Command{Type: "execute", RequestID: fmt.Sprint("pid-", index), SessionID: response.SessionID, QueryID: fmt.Sprint("pid-query-", index), SQL: "SELECT pg_backend_pid()"}
				if rpc(command).Type != "query.started" {
					t.Fatal("backend PID query did not start")
				}
				var result protocol.Response
				if decoder.Decode(&result) != nil || result.Type != "query.result" || len(result.Rows) != 1 {
					t.Fatal("cannot identify real backpressure backend")
				}
				pid, err := strconv.ParseInt(*result.Rows[0][0], 10, 32)
				if err != nil {
					t.Fatal("invalid real backpressure PID")
				}
				pids = append(pids, int32(pid))
			}
			// Permanently stop consuming stdout after setup. Sixteen executions each
			// need a start and an acknowledged metadata chunk, filling the data path.
			for index, id := range sessions {
				encode(protocol.Command{Type: "execute", RequestID: fmt.Sprint("run-", index), SessionID: id, QueryID: fmt.Sprint("sleep-", index), SQL: "SELECT pg_sleep(20)", Stream: true})
			}
			wait := func(predicate func() bool) {
				t.Helper()
				deadline := time.Now().Add(4 * time.Second)
				for !predicate() {
					if time.Now().After(deadline) {
						t.Fatal("PostgreSQL did not reach its expected backpressure state")
					}
					time.Sleep(10 * time.Millisecond)
				}
			}
			state := func(pid int32, expected string) bool {
				var found bool
				// Session preparation also briefly reports active. Establish that
				// both user sleeps actually started before testing Stop isolation.
				if observer.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE pid=$1 AND state=$2 AND ($2 <> 'active' OR wait_event='PgSleep'))", pid, expected).Scan(&found) != nil {
					t.Fatal("cannot inspect real backpressure backend")
				}
				return found
			}
			wait(func() bool { return state(pids[0], "active") && state(pids[1], "active") })
			encode(protocol.Command{Type: "cancel", RequestID: "stop-first", SessionID: sessions[0], QueryID: "sleep-0"})
			wait(func() bool { return state(pids[0], "idle") })
			if !state(pids[1], "active") {
				t.Fatal("Stop under backpressure affected another real SQL session")
			}
			if shutdown {
				encode(protocol.Command{Type: "shutdown", RequestID: "shutdown"})
			} else {
				_ = inputWriter.Close()
			}
			select {
			case err := <-done:
				if err != nil {
					t.Fatal("real backpressure cleanup failed")
				}
			case <-time.After(8 * time.Second):
				t.Fatal("real helper failed to exit with a stalled consumer")
			}
			var remaining int
			if observer.QueryRow(ctx, "SELECT count(*) FROM pg_stat_activity WHERE pid=ANY($1::integer[])", pids).Scan(&remaining) != nil || remaining != 0 {
				t.Fatal("stalled-consumer cleanup left PostgreSQL backends open")
			}
		})
	}
}
