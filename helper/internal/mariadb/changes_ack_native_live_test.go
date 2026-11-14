package mariadb

import (
	"context"
	"io"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	"github.com/go-mysql-org/go-mysql/packet"
)

type rowNativePacketTap struct {
	net.Conn
	lockPrepared bool
	lockStarted  chan struct{}
	watchSQL     string
	watchCount   int32
	watched      atomic.Int32
	once         sync.Once
	loseCommit   bool
	armed        atomic.Bool
	commits      atomic.Int32
}

func (tap *rowNativePacketTap) Write(data []byte) (int, error) {
	if len(data) >= 5 && data[3] == 0 {
		switch data[4] {
		case 22:
			sql := string(data[5:])
			tap.lockPrepared = strings.Contains(sql, " FOR UPDATE") && strings.Contains(sql, " WHERE ")
			if tap.watchSQL != "" {
				tap.lockPrepared = strings.Contains(sql, tap.watchSQL)
			}
		case 23:
			if tap.lockPrepared && tap.lockStarted != nil {
				count := tap.watched.Add(1)
				if tap.watchCount == 0 || count == tap.watchCount {
					tap.once.Do(func() { close(tap.lockStarted) })
				}
			}
			tap.lockPrepared = false
		case 3:
			if string(data[5:]) == "COMMIT AND NO CHAIN NO RELEASE" {
				tap.commits.Add(1)
				tap.armed.Store(tap.loseCommit)
			}
		}
	}
	return tap.Conn.Write(data)
}
func (tap *rowNativePacketTap) Read(data []byte) (int, error) {
	n, err := tap.Conn.Read(data)
	if n > 0 && tap.armed.Swap(false) {
		tap.Conn.Close()
		return 0, io.ErrUnexpectedEOF
	}
	return n, err
}

func TestMariaDBRowsNativeLiveCancellationStopsBeforeRecovery(t *testing.T) {
	s, holder := dataIntegrationSession(t), dataIntegrationSession(t)
	name, qualified := rowFixture(t, holder, "(id INT PRIMARY KEY,n INT NOT NULL) ENGINE=InnoDB")
	dataRun(t, holder, "INSERT INTO "+qualified+" VALUES(1,0)")
	request := rowRequest(t, s, name, 1)
	request.Changes[0].Values = []protocol.ColumnAssignment{{Column: "n", Value: rowCell("1")}}
	before := rowState(t, s)
	dataRun(t, holder, "BEGIN")
	dataRun(t, holder, "SELECT * FROM "+qualified+" WHERE id=1 FOR UPDATE")
	t.Cleanup(func() { dataRun(t, holder, "ROLLBACK") })
	tap := &rowNativePacketTap{Conn: s.work.client.Conn.Conn, lockStarted: make(chan struct{})}
	s.work.client.Conn = packet.NewConn(tap)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan protocol.Response, 1)
	go func() { done <- s.ExecuteChanges(ctx, protocol.Command{Type: "changes.apply", Changes: &request}) }()
	select {
	case <-tap.lockStarted:
	case <-time.After(4 * time.Second):
		t.Fatal("native row-lock statement did not dispatch")
	}
	control, err := s.openControl(context.Background())
	if err != nil {
		t.Fatal("native row cancellation observer could not connect")
	}
	defer control.transport.Close()
	active := false
	for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); {
		result, err := control.client.Execute("SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE ID=? AND COMMAND IN ('Query','Execute')", s.connectionID)
		if err != nil {
			t.Fatal("native row cancellation observer failed")
		}
		count, _ := result.GetInt(0, 0)
		result.Close()
		if count == 1 {
			active = true
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !active {
		t.Fatal("native prepared row-lock execution did not become active")
	}
	cancel()
	select {
	case r := <-done:
		if r.Type != "error" || r.Category != "cancelled" || r.OutcomeUnknown || !r.Connected || s.TransactionStatus() != "idle" {
			t.Fatal("native row cancellation did not establish an acknowledged rollback")
		}
	case <-time.After(8 * time.Second):
		t.Fatal("native row cancellation did not finish")
	}
	dataRun(t, holder, "ROLLBACK")
	if rowState(t, s) != before || *dataRun(t, s, "SELECT n FROM "+qualified).Rows[0][0] != "0" {
		t.Fatal("cancelled row batch changed data or session settings")
	}
	// Cancellation at an already acknowledged row-lock boundary must not hit
	// recovery or a later unrelated statement on this physical owner.
	request = rowRequest(t, s, name, 1)
	request.Changes[0].Values = []protocol.ColumnAssignment{{Column: "n", Value: rowCell("2")}}
	lateCtx, lateCancel := context.WithCancel(context.Background())
	s.afterRowLock = func(int) { lateCancel() }
	r := s.ExecuteChanges(lateCtx, protocol.Command{Type: "changes.apply", Changes: &request})
	s.afterRowLock = nil
	if r.Category != "cancelled" || r.OutcomeUnknown || s.TransactionStatus() != "idle" {
		t.Fatal("late native cancellation raced rollback")
	}
	dataRun(t, s, "SELECT SLEEP(0.02)")
	if *dataRun(t, s, "SELECT n FROM "+qualified).Rows[0][0] != "0" || rowState(t, s) != before {
		t.Fatal("late cancellation affected the next query or retained a write")
	}
}

func TestMariaDBRowsNativeLiveCommitOnceAndLostAcknowledgement(t *testing.T) {
	for _, lose := range []bool{false, true} {
		t.Run(map[bool]string{false: "acknowledged", true: "lost"}[lose], func(t *testing.T) {
			s, observer := dataIntegrationSession(t), dataIntegrationSession(t)
			name, qualified := rowFixture(t, observer, "(id INT PRIMARY KEY,n INT NOT NULL) ENGINE=InnoDB")
			dataRun(t, observer, "INSERT INTO "+qualified+" VALUES(1,0)")
			request := rowRequest(t, s, name, 1)
			request.Changes[0].Values = []protocol.ColumnAssignment{{Column: "n", Value: rowCell("1")}}
			tap := &rowNativePacketTap{Conn: s.work.client.Conn.Conn, loseCommit: lose}
			s.work.client.Conn = packet.NewConn(tap)
			r := rowApply(t, s, request)
			if tap.commits.Load() != 1 {
				t.Fatal("native row batch did not send exactly one COMMIT")
			}
			if lose {
				if r.Type != "error" || !r.OutcomeUnknown || r.Connected || !s.closed.Load() {
					t.Fatal("lost native row COMMIT acknowledgement was replayed or claimed complete")
				}
			} else if r.Type != "query.result" || r.OutcomeUnknown || s.TransactionStatus() != "idle" {
				t.Fatal("acknowledged native row COMMIT lost its applied outcome")
			}
			if *dataRun(t, observer, "SELECT n FROM "+qualified).Rows[0][0] != "1" {
				t.Fatal("actual native committed row was not observed exactly once")
			}
			if lose {
				again := rowApply(t, s, request)
				if !again.OutcomeUnknown || tap.commits.Load() != 1 {
					t.Fatal("unknown native row outcome retried the retired owner")
				}
			}
		})
	}
}
