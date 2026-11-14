package mariadb

import (
	"context"
	"fmt"
	"io"
	"net"
	"strings"
	"sync/atomic"
	"testing"
	"time"
	"unicode/utf16"

	"dbeer/helper/internal/protocol"
	"github.com/go-mysql-org/go-mysql/packet"
)

func nativeExplainRequest(s *Session, sql, mode string, write bool) protocol.ExplainRequest {
	r := protocol.ExplainRequest{SQL: sql, Mode: mode}
	if write && mode == "analyze" {
		r.Context = &protocol.ExplainContext{DocumentID: "source", TargetDocumentID: "target", ProfileID: "profile", SessionID: "owner", RangeLength: len(utf16.Encode([]rune(sql))), TransactionStatus: s.TransactionStatus()}
		r.WriteIntent = &protocol.ExplainWriteIntent{Disposition: "currentSession", ExpectedTransactionStatus: s.TransactionStatus()}
	}
	return r
}

func runNativeExplain(t *testing.T, s *Session, request protocol.ExplainRequest) protocol.Response {
	t.Helper()
	prepared, err := s.PrepareExplain(request)
	if err != nil {
		t.Fatal("native Explain preparation failed")
	}
	r := s.ExecuteExplain(context.Background(), protocol.Command{Type: "explain.run", RequestID: "run", SessionID: "owner", QueryID: "query", Explain: &request, PreparedExplainSQL: prepared.Preview.SQL})
	if r.Type != "explain.result" || r.Explain == nil || !r.SQLCompleted || !r.Explain.Valid() || r.Explain.Status != "tree" {
		t.Fatalf("native Explain failed to normalize: %s/%s status=%v", r.Category, r.SQLState, r.Explain != nil && r.Explain.Status == "rawOnly")
	}
	return r
}

func TestMariaDBExplainNativeLiveFormsMetricsAndParameters(t *testing.T) {
	s := dataIntegrationSession(t)
	dataRun(t, s, "CREATE TEMPORARY TABLE dbeer_explain_native (id INT PRIMARY KEY,n INT NOT NULL) ENGINE=InnoDB")
	dataRun(t, s, "CREATE TEMPORARY TABLE dbeer_explain_join (id INT PRIMARY KEY,n INT NOT NULL) ENGINE=InnoDB")
	dataRun(t, s, "INSERT INTO dbeer_explain_native VALUES(1,0),(2,0),(3,0)")
	dataRun(t, s, "INSERT INTO dbeer_explain_join VALUES(1,0),(2,0),(3,0)")
	for _, sql := range []string{"SELECT * FROM dbeer_explain_native WHERE n=0", "WITH selected AS (SELECT * FROM dbeer_explain_native) SELECT * FROM selected", "SELECT a.id FROM dbeer_explain_native a JOIN dbeer_explain_join b ON a.id=b.id ORDER BY a.n", "SELECT id FROM dbeer_explain_native UNION SELECT id FROM dbeer_explain_join"} {
		for _, mode := range []string{"plan", "analyze"} {
			out := runNativeExplain(t, s, nativeExplainRequest(s, sql, mode, false))
			if mode == "analyze" && out.Explain.Metrics["executionTime"].Basis != "inclusiveTotal" {
				t.Fatal("native elapsed time lost its inclusive total basis")
			}
		}
	}
	for _, sql := range []string{"UPDATE dbeer_explain_native SET n=n+1 WHERE id=1", "DELETE FROM dbeer_explain_native WHERE id=3", "UPDATE dbeer_explain_native a JOIN dbeer_explain_join b ON a.id=b.id SET a.n=a.n+1 WHERE a.id=1", "DELETE a FROM dbeer_explain_native a JOIN dbeer_explain_join b ON a.id=b.id WHERE a.id=2"} {
		plan := runNativeExplain(t, s, nativeExplainRequest(s, sql, "plan", true))
		if plan.Explain.DML == nil || plan.Explain.DML.Execution != "estimated" || *dataRun(t, s, "SELECT SUM(n) FROM dbeer_explain_native").Rows[0][0] != "0" {
			t.Fatal("estimated native DML executed a target write")
		}
	}
	request := nativeExplainRequest(s, "UPDATE dbeer_explain_native SET n=n+:delta WHERE id=1", "analyze", true)
	one := "1"
	request.Parameters = []protocol.QueryParameter{{Name: "delta", Type: "integer", Value: &one}}
	out := runNativeExplain(t, s, request)
	if out.Explain.DML == nil || out.Explain.DML.TargetExecution != "executed" || out.Explain.DML.Persistence != "committed" || *dataRun(t, s, "SELECT n FROM dbeer_explain_native WHERE id=1").Rows[0][0] != "1" {
		t.Fatal("bound native DML did not execute once with acknowledged autocommit")
	}
	dataRun(t, s, "BEGIN")
	out = runNativeExplain(t, s, nativeExplainRequest(s, "UPDATE dbeer_explain_native a JOIN dbeer_explain_join b ON a.id=b.id SET a.n=a.n+1 WHERE a.id=1", "analyze", true))
	if out.Explain.DML.Persistence != "transactionPending" || s.TransactionStatus() != "transaction" || *dataRun(t, s, "SELECT n FROM dbeer_explain_native WHERE id=1").Rows[0][0] != "2" {
		t.Fatal("native multi-table Analyze changed the existing transaction boundary")
	}
	dataRun(t, s, "ROLLBACK")
	if *dataRun(t, s, "SELECT n FROM dbeer_explain_native WHERE id=1").Rows[0][0] != "1" {
		t.Fatal("native Analyze committed the existing transaction")
	}
	for _, sql := range []string{"DELETE FROM dbeer_explain_native WHERE id=3", "DELETE a FROM dbeer_explain_native a JOIN dbeer_explain_join b ON a.id=b.id WHERE a.id=2"} {
		out = runNativeExplain(t, s, nativeExplainRequest(s, sql, "analyze", true))
		if out.Explain.DML.Persistence != "committed" {
			t.Fatal("native Delete Analyze acknowledgement was not retained")
		}
	}
	if *dataRun(t, s, "SELECT COUNT(*) FROM dbeer_explain_native").Rows[0][0] != "1" {
		t.Fatal("native Delete Analyze did not execute its targets")
	}
}

func TestMariaDBExplainNativeLiveRefusalCancellationAndReuse(t *testing.T) {
	s := dataIntegrationSession(t)
	for _, sql := range []string{"INSERT INTO owned VALUES(1)", "REPLACE INTO owned VALUES(1)", "SELECT 1; SELECT 2", "EXPLAIN SELECT 1", "SELECT 1 /*M! INTO OUTFILE 'unused' */"} {
		if _, err := s.PrepareExplain(protocol.ExplainRequest{SQL: sql, Mode: "plan"}); err == nil {
			t.Fatal("unsupported native Explain form was admitted")
		}
	}
	request := nativeExplainRequest(s, "SELECT 1", "plan", false)
	prepared, err := s.PrepareExplain(request)
	if err != nil {
		t.Fatal("native read preparation failed")
	}
	r := s.ExecuteExplain(context.Background(), protocol.Command{Type: "explain.run", Explain: &request, PreparedExplainSQL: prepared.Preview.SQL + " "})
	if r.Type != "error" || !r.SQLNotExecuted || r.OutcomeUnknown {
		t.Fatal("stale native prefix review authorized execution")
	}
	request = nativeExplainRequest(s, "SELECT SLEEP(10)", "analyze", false)
	prepared, err = s.PrepareExplain(request)
	if err != nil {
		t.Fatal("native cancellation fixture preparation failed")
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan protocol.Response, 1)
	go func() {
		done <- s.ExecuteExplain(ctx, protocol.Command{Type: "explain.run", Explain: &request, PreparedExplainSQL: prepared.Preview.SQL})
	}()
	dataWaitRunning(t, s)
	cancel()
	select {
	case r = <-done:
		if r.Type != "error" || r.Category != "cancelled" || !r.Connected || r.ExplainDML != nil {
			t.Fatal("native cancellation did not retain read-only context and reusable owner")
		}
	case <-time.After(8 * time.Second):
		t.Fatal("native Explain cancellation did not finish")
	}
	dataRun(t, s, "SELECT 1")
}

type explainNativePacketObserver struct {
	net.Conn
	target string
	drop   bool
	writes atomic.Int32
	armed  atomic.Bool
}

func (c *explainNativePacketObserver) Write(data []byte) (int, error) {
	if len(data) >= 5 && data[3] == 0 && data[4] == 3 && string(data[5:]) == c.target {
		c.writes.Add(1)
		c.armed.Store(c.drop)
	}
	return c.Conn.Write(data)
}

func (c *explainNativePacketObserver) Read(data []byte) (int, error) {
	n, err := c.Conn.Read(data)
	if n > 0 && c.armed.Swap(false) {
		c.Conn.Close()
		return 0, io.ErrUnexpectedEOF
	}
	return n, err
}

func TestMariaDBExplainNativeLiveSingleDispatchAndLostAcknowledgement(t *testing.T) {
	for _, loseAcknowledgement := range []bool{false, true} {
		t.Run(fmt.Sprintf("lost=%t", loseAcknowledgement), func(t *testing.T) {
			s, observer := dataIntegrationSession(t), dataIntegrationSession(t)
			qualified := QuoteIdentifier(dataIntegrationSettings(t).Database) + "." + QuoteIdentifier(fmt.Sprintf("dbeer_explain_ack_%d", s.connectionID))
			dataRun(t, observer, "CREATE TABLE "+qualified+" (n INT NOT NULL) ENGINE=InnoDB")
			t.Cleanup(func() {
				observer.Execute(context.Background(), protocol.Command{SQL: "DROP TABLE IF EXISTS " + qualified})
			})
			dataRun(t, observer, "INSERT INTO "+qualified+" VALUES(0)")
			r := nativeExplainRequest(s, "UPDATE "+qualified+" SET n=n+1", "analyze", true)
			prepared, err := s.PrepareExplain(r)
			if err != nil {
				t.Fatal("native acknowledgement fixture preparation failed")
			}
			tap := &explainNativePacketObserver{Conn: s.work.client.Conn.Conn, target: prepared.Preview.SQL, drop: loseAcknowledgement}
			s.work.client.Conn = packet.NewConn(tap)
			response := s.ExecuteExplain(context.Background(), protocol.Command{Type: "explain.run", Explain: &r, PreparedExplainSQL: prepared.Preview.SQL})
			if tap.writes.Load() != 1 {
				t.Fatal("native Analyze target was not dispatched exactly once")
			}
			if loseAcknowledgement {
				if response.Type != "error" || !response.OutcomeUnknown || response.ExplainDML == nil || response.ExplainDML.Persistence != "unknown" || response.Connected {
					t.Fatal("lost native Analyze acknowledgement was falsely completed or retried")
				}
			} else if response.Type != "explain.result" || response.Explain == nil || response.Explain.DML.Persistence != "committed" {
				t.Fatal("acknowledged native Analyze lost its applied result")
			}
			deadline := time.Now().Add(3 * time.Second)
			for {
				value := dataRun(t, observer, "SELECT n FROM "+qualified)
				if *value.Rows[0][0] == "1" {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("the actual single native write was not observed after response loss")
				}
				time.Sleep(10 * time.Millisecond)
			}
			if strings.Contains(response.Message, qualified) {
				t.Fatal("native transport failure disclosed SQL content")
			}
		})
	}
}
