package postgres

import (
	"context"
	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgproto3"
	"net"
	"testing"
	"time"
)

// CommandComplete precedes ReadyForQuery. Losing the latter cannot prove that
// the implicit transaction committed, even when the plan row was captured.
func TestExplainDMLPostgresLostReadyForQueryNeverClaimsCommit(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	_ = server.SetDeadline(time.Now().Add(5 * time.Second))
	executions := make(chan int, 1)
	go func() {
		count := 0
		defer func() { executions <- count }()
		backend := pgproto3.NewBackend(server, server)
		if _, err := backend.ReceiveStartupMessage(); err != nil {
			return
		}
		backend.Send(&pgproto3.AuthenticationOk{})
		backend.Send(&pgproto3.ParameterStatus{Name: "server_version", Value: "17.6"})
		backend.Send(&pgproto3.ReadyForQuery{TxStatus: 'I'})
		if backend.Flush() != nil {
			return
		}
		fields := []pgproto3.FieldDescription{{Name: []byte("QUERY PLAN"), DataTypeOID: 114, DataTypeSize: -1, TypeModifier: -1}}
		for {
			message, err := backend.Receive()
			if err != nil {
				return
			}
			switch message.(type) {
			case *pgproto3.Parse:
				backend.Send(&pgproto3.ParseComplete{})
			case *pgproto3.Describe:
				if message.(*pgproto3.Describe).ObjectType == 'S' {
					backend.Send(&pgproto3.ParameterDescription{})
				}
				backend.Send(&pgproto3.RowDescription{Fields: fields})
			case *pgproto3.Bind:
				backend.Send(&pgproto3.BindComplete{})
			case *pgproto3.Execute:
				count++
				backend.Send(&pgproto3.DataRow{Values: [][]byte{[]byte(`[{"Plan":{"Node Type":"ModifyTable","Operation":"Update","Actual Rows":0,"Actual Loops":1}}]`)}})
				backend.Send(&pgproto3.CommandComplete{CommandTag: []byte("EXPLAIN")})
				_ = backend.Flush()
				_ = server.Close()
				return
			case *pgproto3.Sync:
				backend.Send(&pgproto3.ReadyForQuery{TxStatus: 'I'})
			}
			if backend.Flush() != nil {
				return
			}
		}
	}()
	config, err := pgx.ParseConfig("host=127.0.0.1 port=5432 user=fixture dbname=fixture sslmode=disable")
	if err != nil {
		t.Fatal(err)
	}
	config.DialFunc = func(context.Context, string, string) (net.Conn, error) { return client, nil }
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		t.Fatal("cannot open synthetic DML transport")
	}
	s := &Session{conn: conn, explainIdentity: "PostgreSQL 17.6"}
	sql := "UPDATE sample SET value=2"
	r := protocol.ExplainRequest{SQL: sql, Mode: "analyze", Context: &protocol.ExplainContext{DocumentID: "doc", TargetDocumentID: "doc", ProfileID: "profile", SessionID: "session", RangeLength: len(sql), TransactionStatus: "idle"}, WriteIntent: &protocol.ExplainWriteIntent{Disposition: "currentSession", ExpectedTransactionStatus: "idle"}}
	p, err := s.PrepareExplain(r)
	if err != nil {
		t.Fatal("synthetic DML preparation failed")
	}
	out := s.ExecuteExplain(ctx, protocol.Command{Type: "explain.run", RequestID: "r", SessionID: "session", QueryID: "q", Explain: &r, PreparedExplainSQL: p.Preview.SQL})
	if out.Type != "error" || out.Connected || !out.OutcomeUnknown || out.SQLCompleted || out.ExplainDML == nil || out.ExplainDML.Execution != "unknown" || out.ExplainDML.Persistence != "unknown" {
		t.Fatal("lost terminal acknowledgement claimed DML completion or commit")
	}
	if <-executions != 1 {
		t.Fatal("DML Analyze was replayed")
	}
}
