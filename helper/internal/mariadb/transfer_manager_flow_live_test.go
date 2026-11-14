package mariadb

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	dt "dbeer/helper/internal/datatransfer"
	"dbeer/helper/internal/protocol"
)

func flowWaitManager(t *testing.T, m *dt.Manager, id string) protocol.TransferReply {
	t.Helper()
	for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); {
		r := m.Handle(protocol.Command{Type: "transfer.status", RequestID: "status", Transfer: &protocol.TransferRequest{JobID: id}})
		if r.Transfer == nil {
			t.Fatal("normal transfer job disappeared")
		}
		if r.Transfer.State != "running" && r.Transfer.State != "pending" {
			return *r.Transfer
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("normal transfer job did not terminalize")
	return protocol.TransferReply{}
}
func TestMariaDBFlowNativeManagerReviewCaptureApplyOneUse(t *testing.T) {
	observer := dataIntegrationSession(t)
	settings := dataIntegrationSettings(t)
	source, q := rowFixture(t, observer, "(id BIGINT UNSIGNED PRIMARY KEY,n DECIMAL(65,38),j LONGTEXT,b BLOB) ENGINE=InnoDB")
	exact := "9007199254740993.12345678901234567890123456789012345678"
	j := "{ \"k\":1,\"k\":2 }"
	dataRun(t, observer, "INSERT INTO "+q+" VALUES(18446744073709551615,"+exact+",'"+j+"',x'00ff'),(2,1,'',x''),(3,NULL,'NULL',NULL)")
	target := fmt.Sprintf("g1_flow_manager_%d", time.Now().UnixNano())
	targetQ := QuoteIdentifier(settings.Database) + "." + QuoteIdentifier(target)
	t.Cleanup(func() { dataRun(t, observer, "DROP TABLE IF EXISTS "+targetQ) })
	var ownerIDs []uint32
	manager, e := dt.New(func(ctx context.Context, c protocol.Connection) (adapter.Session, error) {
		session, e := Open(ctx, c)
		if e == nil {
			ownerIDs = append(ownerIDs, session.(*Session).connectionID)
		}
		return session, e
	}, dt.Options{Root: t.TempDir()})
	if e != nil {
		t.Fatal("private normal transfer Manager failed")
	}
	defer manager.Close()
	from := &protocol.TransferEndpoint{Connection: settings, Schema: settings.Database, Table: source}
	to := &protocol.TransferEndpoint{Connection: settings, Schema: settings.Database, Table: target}
	describe := manager.Handle(protocol.Command{Type: "transfer.describe", RequestID: "describe", Transfer: &protocol.TransferRequest{Mode: "table", Source: from, Target: to}})
	if describe.Transfer == nil {
		t.Fatal("normal source describe admission failed")
	}
	description := flowWaitManager(t, manager, describe.Transfer.JobID)
	if description.State != "described" || description.SourceDigest == "" || len(description.Columns) != 4 {
		t.Fatalf("normal source describe failed: state=%s", description.State)
	}
	manager.Handle(protocol.Command{Type: "transfer.close", RequestID: "close-description", Transfer: &protocol.TransferRequest{JobID: description.JobID}})
	request := protocol.TransferRequest{Mode: "table", Source: from, Target: to, Columns: description.Columns, SourceDigest: description.SourceDigest}
	preview := manager.Handle(protocol.Command{Type: "transfer.preview", RequestID: "preview", Transfer: &request})
	if preview.Transfer == nil {
		t.Fatal("normal transfer preview admission failed")
	}
	ready := flowWaitManager(t, manager, preview.Transfer.JobID)
	if ready.State != "ready" || ready.RowsRead != 3 || ready.TableCreated || !strings.Contains(ready.SQL, "DECIMAL(65,38)") {
		t.Fatalf("normal transfer review failed: state=%s", ready.State)
	}
	if *dataRun(t, observer, "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='"+settings.Database+"' AND TABLE_NAME='"+target+"'").Rows[0][0] != "0" {
		t.Fatal("Preview created the target")
	}
	// Preview retains all source rows; later source changes cannot silently replan.
	dataRun(t, observer, "UPDATE "+q+" SET j='changed after review' WHERE id=18446744073709551615")
	apply := protocol.TransferRequest{JobID: ready.JobID, PlanDigest: ready.PlanDigest, Confirmed: true}
	if r := manager.Handle(protocol.Command{Type: "transfer.apply", RequestID: "apply", Transfer: &apply}); r.Transfer == nil {
		t.Fatal("reviewed normal transfer apply refused")
	}
	done := flowWaitManager(t, manager, ready.JobID)
	if done.State != "completed" || done.RowsWritten != 3 || !done.TableCreated || done.OutcomeUnknown {
		t.Fatalf("normal transfer failed: state=%s", done.State)
	}
	actual := dataRun(t, observer, "SELECT CAST(id AS CHAR),CAST(n AS CHAR),j,HEX(b) FROM "+targetQ+" ORDER BY id")
	if len(actual.Rows) != 3 || *actual.Rows[2][0] != "18446744073709551615" || *actual.Rows[2][1] != exact || *actual.Rows[2][2] != j || *actual.Rows[2][3] != "00FF" || *actual.Rows[0][2] != "" || *actual.Rows[0][3] != "" || *actual.Rows[1][2] != "NULL" || actual.Rows[1][3] != nil {
		t.Fatal("normal transfer lost retained exact values or reread mutable source")
	}
	if r := manager.Handle(protocol.Command{Type: "transfer.apply", RequestID: "replay", Transfer: &apply}); r.Type != "error" {
		t.Fatal("normal transfer one-use plan was replayed")
	}
	seen := map[uint32]bool{}
	for _, id := range ownerIDs {
		if seen[id] || id == observer.connectionID {
			t.Fatal("normal transfer reused a physical source/target/SQL owner")
		}
		seen[id] = true
	}
	if len(seen) < 4 {
		t.Fatal("normal transfer owner lifecycle was not reached")
	}
}
