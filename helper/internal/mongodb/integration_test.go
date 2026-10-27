package mongodb

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/exportfile"
	"dbeer/helper/internal/protocol"
	"go.mongodb.org/mongo-driver/v2/bson"
)

func integrationConnection(t *testing.T) protocol.Connection {
	t.Helper()
	host := os.Getenv("DBEER_TEST_MONGODB_HOST")
	if host == "" {
		if os.Getenv("DBEER_REQUIRE_MONGODB") == "1" {
			t.Fatal("MongoDB integration is required but unconfigured")
		}
		t.Skip("MongoDB integration requires DBEER_TEST_MONGODB_HOST")
	}
	port, err := strconv.Atoi(os.Getenv("DBEER_TEST_MONGODB_PORT"))
	if err != nil {
		t.Fatal("MongoDB integration port is invalid")
	}
	c := protocol.Connection{Engine: "mongodb", Host: host, Port: port, User: os.Getenv("DBEER_TEST_MONGODB_USER"), Password: os.Getenv("DBEER_TEST_MONGODB_PASSWORD"), SSLMode: os.Getenv("DBEER_TEST_MONGODB_SSLMODE"), MongoDB: &protocol.MongoDBSettings{AuthSource: "admin", DirectConnection: true}}
	c.MongoDB.ReplicaSet = os.Getenv("DBEER_TEST_MONGODB_REPLICA_SET")
	if c.SSLMode == "" {
		c.SSLMode = "disable"
	}
	if c.SSLMode != "disable" {
		c.SSLRootCert = os.Getenv("DBEER_TEST_MONGODB_CA")
	}
	return c
}

func integrationSession(t *testing.T) *Session {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	physical, err := Open(ctx, integrationConnection(t))
	if err != nil {
		t.Fatal("MongoDB fixture connection failed")
	}
	s := physical.(*Session)
	s.database = fmt.Sprintf("dbeer_test_%d", time.Now().UnixNano())
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = s.client.Database(s.database).Drop(ctx)
		s.Close()
	})
	return s
}

func query(t *testing.T, s *Session, text string) protocol.Response {
	t.Helper()
	r := s.Execute(context.Background(), protocol.Command{Type: "execute", RequestID: "test", SessionID: "session", QueryID: "query", SQL: text})
	if r.Type != "query.result" {
		t.Fatalf("MongoDB fixture request failed: %s", r.Category)
	}
	return r
}

func TestMongoDBIntegrationCatalogFindAggregateAndCursor(t *testing.T) {
	s := integrationSession(t)
	ctx := context.Background()
	docs := make([]any, 450)
	for i := range docs {
		docs[i] = bson.D{{Key: "_id", Value: int32(i)}, {Key: "name", Value: "item"}, {Key: "nested", Value: bson.D{{Key: "price", Value: int64(9007199254740993)}}}}
	}
	if _, err := s.client.Database(s.database).Collection("items").InsertMany(ctx, docs); err != nil {
		t.Fatal("fixture insert failed")
	}
	if err := s.client.Database(s.database).CreateView(ctx, "items_view", "items", bson.A{}); err != nil {
		t.Fatal("view fixture setup failed")
	}
	completion := protocol.CatalogRequest{Kind: "completion", Schema: s.database}
	metadata := s.Execute(ctx, protocol.Command{Type: "catalog", Catalog: &completion})
	if metadata.Type != "query.result" || len(metadata.Rows) != 2 {
		t.Fatal("internal MongoDB namespaces prevented collection/view completion")
	}
	viewFound := false
	for _, row := range metadata.Rows {
		if row[0] == nil || row[1] == nil || row[3] == nil {
			t.Fatal("completion metadata is incomplete")
		}
		if strings.HasPrefix(*row[0], "system.") {
			t.Fatal("internal namespaces leaked into completion")
		}
		if *row[0] == "items_view" {
			viewFound = *row[1] == "view" && strings.Contains(*row[3], "nested.price")
		}
	}
	if !viewFound {
		t.Fatal("MongoDB view completion lost its kind or sampled fields")
	}
	for _, request := range []protocol.CatalogRequest{{Kind: "schemas"}, {Kind: "objects", Schema: s.database, ObjectKind: "table"}, {Kind: "columns", Schema: s.database, Object: "items", ObjectKind: "table"}, {Kind: "completion", Schema: s.database}, {Kind: "indexes", Schema: s.database, Object: "items", ObjectKind: "table"}} {
		r := s.Execute(ctx, protocol.Command{Type: "catalog", Catalog: &request})
		if r.Type != "query.result" || len(r.Rows) == 0 {
			t.Fatal("MongoDB catalog operation failed")
		}
	}
	r := query(t, s, `{"collection":"items","find":{"_id":{"$gte":448}},"sort":{"_id":-1}}`)
	if len(r.Rows) != 2 || !strings.Contains(*r.Rows[0][0], `"$numberLong":"9007199254740993"`) {
		t.Fatal("find lost BSON types or filtering")
	}
	r = query(t, s, `{"collection":"items","aggregate":[{"$group":{"_id":null,"n":{"$sum":1}}}]}`)
	if len(r.Rows) != 1 || !strings.Contains(*r.Rows[0][0], `"450"`) {
		t.Fatal("aggregation failed")
	}
	request := protocol.CatalogRequest{Kind: "browse", Schema: s.database, Object: "items", ObjectKind: "table"}
	total := 0
	for page := 0; page < 3; page++ {
		r = s.Execute(ctx, protocol.Command{Type: "catalog", Catalog: &request})
		if r.Type != "query.result" || len(r.Rows) == 0 {
			t.Fatal("cursor page failed")
		}
		total += len(r.Rows)
		request.Cursor = r.NextCursor
	}
	if total != 450 || request.Cursor != "" {
		t.Fatal("cursor pagination omitted or repeated documents")
	}
	request.Cursor = "invalid"
	if r = s.Execute(ctx, protocol.Command{Type: "catalog", Catalog: &request}); r.Category != "cursor" {
		t.Fatal("unknown cursor accepted")
	}
	r = query(t, s, `{"collection":"items","aggregate":[{"$match":{"_id":1}},{"$out":"output"}]}`)
	if r.OutcomeUnknown {
		t.Fatal("acknowledged output marked unknown")
	}
	count, err := s.client.Database(s.database).Collection("output").CountDocuments(ctx, bson.D{})
	if err != nil || count != 1 {
		t.Fatal("output stage did not run")
	}
}

func TestMongoDBIntegrationCancellationAndSessionRecovery(t *testing.T) {
	s := integrationSession(t)
	// The server may finish the injected blocked request after client Stop.
	// Keep the global failCommand fixture alive until that request has exited.
	t.Cleanup(func() { time.Sleep(2100 * time.Millisecond) })
	// Block only the next aggregation in this disposable fixture. Stop must close
	// its socket without waiting for server completion or retrying the operation.
	if err := s.client.Database("admin").RunCommand(context.Background(), bson.D{{Key: "configureFailPoint", Value: "failCommand"}, {Key: "mode", Value: bson.D{{Key: "times", Value: 1}}}, {Key: "data", Value: bson.D{{Key: "failCommands", Value: bson.A{"aggregate"}}, {Key: "blockConnection", Value: true}, {Key: "blockTimeMS", Value: 2000}}}}).Err(); err != nil {
		t.Fatal("cancellation failpoint setup failed")
	}
	ctx, cancel := context.WithCancel(context.Background())
	timer := time.AfterFunc(100*time.Millisecond, cancel)
	defer timer.Stop()
	defer cancel()
	start := time.Now()
	r := s.Execute(ctx, protocol.Command{Type: "execute", SQL: `{"collection":"items","aggregate":[{"$match":{}}]}`})
	if r.Category != "cancelled" || r.OutcomeUnknown || time.Since(start) > time.Second {
		t.Fatal("MongoDB cancellation was delayed or misclassified")
	}
	query(t, s, `{"collection":"items","find":{}}`)
}

func TestMongoDBIntegrationVerifiedTLSAndAuthentication(t *testing.T) {
	c := integrationConnection(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	bad := c
	if c.User != "" {
		bad.Password = "invalid-fixture-password"
		if s, err := Open(ctx, bad); err == nil {
			s.Close()
			t.Fatal("invalid credentials accepted")
		}
	}
	if c.SSLMode != "verify-full" {
		return
	}
	bad = c
	bad.SSLRootCert = os.Getenv("DBEER_TEST_MONGODB_UNTRUSTED_CA")
	if s, err := Open(ctx, bad); err == nil {
		s.Close()
		t.Fatal("untrusted CA accepted")
	}
	ctx2, cancel2 := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel2()
	bad = c
	bad.Host = "127.0.0.1"
	if s, err := Open(ctx2, bad); err == nil {
		s.Close()
		t.Fatal("TLS hostname mismatch accepted")
	}
}

func TestMongoDBIntegrationFullExportBeyondDisplayLimit(t *testing.T) {
	s := integrationSession(t)
	documents := make([]any, 1105)
	for i := range documents {
		documents[i] = bson.D{{Key: "_id", Value: int64(i)}, {Key: "value", Value: int64(9007199254740993)}}
	}
	if _, err := s.client.Database(s.database).Collection("items").InsertMany(context.Background(), documents); err != nil {
		t.Fatal("export fixture setup failed")
	}
	request := protocol.ExportRequest{Path: t.TempDir() + "/result.json", Format: "json"}
	writer, err := exportfile.New(request)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Abort()
	r := s.ExecuteWithSink(context.Background(), protocol.Command{Type: "execute", SQL: `{"collection":"items","find":{}}`, Export: &request}, writer)
	if r.Type != "query.result" || r.RowCount != 1105 || r.DisplayedRowCount != 1000 || !r.Truncated {
		t.Fatal("full export used the interactive row limit")
	}
	if err := writer.Commit(); err != nil {
		t.Fatal("MongoDB export publication failed")
	}
	data, err := os.ReadFile(request.Path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(data), `$numberLong`) != 2210 {
		t.Fatal("MongoDB export lost documents or BSON types")
	}
}

type blockedSink struct {
	ctx     context.Context
	started chan struct{}
}

type failedSink struct{}

func (failedSink) Begin(int, []protocol.Column) error { return fmt.Errorf("fixture delivery failure") }
func (failedSink) Row(int, []*string) error           { return nil }
func (failedSink) End(int, protocol.ResultSet) error  { return nil }

func TestMongoDBIntegrationAcknowledgedOutputDeliveryFailure(t *testing.T) {
	s := integrationSession(t)
	r := s.ExecuteWithSink(context.Background(), protocol.Command{Type: "execute", SQL: `{"collection":"items","aggregate":[{"$out":"output"}]}`}, failedSink{})
	if r.Type != "error" || !r.SQLCompleted || r.OutcomeUnknown || r.Category != "result" {
		t.Fatal("acknowledged output was misrepresented after a delivery failure")
	}
}

func (*blockedSink) Begin(int, []protocol.Column) error { return nil }
func (s *blockedSink) Row(int, []*string) error         { close(s.started); <-s.ctx.Done(); return s.ctx.Err() }
func (*blockedSink) End(int, protocol.ResultSet) error  { return nil }

func TestMongoDBIntegrationStopUnderBackpressureAndIndependentSessions(t *testing.T) {
	s := integrationSession(t)
	other := integrationSession(t)
	if _, err := s.client.Database(s.database).Collection("items").InsertOne(context.Background(), bson.D{{Key: "_id", Value: 1}}); err != nil {
		t.Fatal("stream fixture setup failed")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sink := &blockedSink{ctx: ctx, started: make(chan struct{})}
	finished := make(chan protocol.Response, 1)
	go func() {
		finished <- s.ExecuteWithSink(ctx, protocol.Command{Type: "execute", SQL: `{"collection":"items","find":{}}`}, sink)
	}()
	select {
	case <-sink.started:
	case <-time.After(3 * time.Second):
		t.Fatal("stream did not reach backpressure")
	}
	query(t, other, `{"collection":"items","find":{}}`)
	cancel()
	select {
	case result := <-finished:
		if result.Category != "cancelled" || result.OutcomeUnknown {
			t.Fatal("blocked stream cancellation misreported")
		}
	case <-time.After(time.Second):
		t.Fatal("blocked consumer prevented Stop")
	}
	query(t, s, `{"collection":"items","find":{}}`)
}

func TestMongoDBIntegrationInterruptedOutputDisclosesUncertainOutcome(t *testing.T) {
	s := integrationSession(t)
	t.Cleanup(func() { time.Sleep(1600 * time.Millisecond) })
	if err := s.client.Database("admin").RunCommand(context.Background(), bson.D{{Key: "configureFailPoint", Value: "failCommand"}, {Key: "mode", Value: bson.D{{Key: "times", Value: 1}}}, {Key: "data", Value: bson.D{{Key: "failCommands", Value: bson.A{"aggregate"}}, {Key: "blockConnection", Value: true}, {Key: "blockTimeMS", Value: 1500}}}}).Err(); err != nil {
		t.Fatal("output interruption fixture setup failed")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	r := s.Execute(ctx, protocol.Command{Type: "execute", SQL: `{"collection":"items","aggregate":[{"$out":"output"}]}`})
	if !r.OutcomeUnknown || r.Category != "timeout" {
		t.Fatal("interrupted output pipeline hid its uncertain outcome")
	}
}

func TestMongoDBIntegrationWriteConcernFailureRemainsUncertain(t *testing.T) {
	s := integrationSession(t)
	command := bson.D{{Key: "configureFailPoint", Value: "failCommand"}, {Key: "mode", Value: bson.D{{Key: "times", Value: 1}}},
		{Key: "data", Value: bson.D{{Key: "failCommands", Value: bson.A{"aggregate"}}, {Key: "writeConcernError", Value: bson.D{{Key: "code", Value: 64}, {Key: "errmsg", Value: "fixture write acknowledgement unavailable"}}}}}}
	if err := s.client.Database("admin").RunCommand(context.Background(), command).Err(); err != nil {
		t.Fatal("write concern fixture setup failed")
	}
	r := s.Execute(context.Background(), protocol.Command{Type: "execute", SQL: `{"collection":"items","aggregate":[{"$out":"output"}]}`})
	if r.Type != "error" || !r.OutcomeUnknown || r.SQLCompleted {
		t.Fatalf("write concern flags: type=%s category=%s unknown=%t completed=%t", r.Type, r.Category, r.OutcomeUnknown, r.SQLCompleted)
	}
}
