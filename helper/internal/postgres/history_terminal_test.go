package postgres

import (
	"context"
	"fmt"
	"net"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgproto3"
)

func TestPostgresCopyRejectionDoesNotSendDatabaseSQL(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	_ = server.SetDeadline(time.Now().Add(3 * time.Second))
	serverResult := make(chan error, 1)
	go func() {
		backend := pgproto3.NewBackend(server, server)
		if _, err := backend.ReceiveStartupMessage(); err != nil {
			serverResult <- err
			return
		}
		backend.Send(&pgproto3.AuthenticationOk{})
		backend.Send(&pgproto3.ReadyForQuery{TxStatus: 'I'})
		if err := backend.Flush(); err != nil {
			serverResult <- err
			return
		}
		message, err := backend.Receive()
		if err == nil {
			if _, closing := message.(*pgproto3.Terminate); !closing {
				err = fmt.Errorf("locally rejected COPY sent database message %T", message)
			}
		}
		serverResult <- err
	}()
	config, err := pgx.ParseConfig("host=127.0.0.1 port=5432 user=fixture dbname=fixture sslmode=disable")
	if err != nil {
		t.Fatal(err)
	}
	config.DialFunc = func(context.Context, string, string) (net.Conn, error) { return client, nil }
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	conn, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	session := &Session{conn: conn}
	for _, sql := range []string{"COPY demo FROM STDIN", "/* fixture */ COPY (SELECT 1) TO STDOUT"} {
		command := protocol.Command{Type: "execute", SQL: sql}
		for _, response := range []protocol.Response{
			session.Execute(ctx, command), session.ExecuteWithSink(ctx, command, nil),
		} {
			if response.Type != "error" || !response.SQLNotExecuted || response.OutcomeUnknown || !response.Connected {
				t.Fatal("local COPY rejection was confused with executed SQL")
			}
		}
	}
	cancelled, stop := context.WithCancel(ctx)
	stop()
	response := session.ExecuteWithSink(cancelled, protocol.Command{Type: "execute", SQL: "SELECT 1"}, nil)
	if response.Category != "cancelled" || !response.SQLNotExecuted || response.OutcomeUnknown {
		t.Fatal("SQL cancelled before sending was confused with executed SQL")
	}
	if err := conn.Close(ctx); err != nil {
		t.Fatal(err)
	}
	if err := <-serverResult; err != nil {
		t.Fatal(err)
	}
}
