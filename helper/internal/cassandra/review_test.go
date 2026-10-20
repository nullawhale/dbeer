package cassandra

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/exportfile"
	"dbeer/helper/internal/protocol"
	gocql "github.com/apache/cassandra-gocql-driver/v2"
)

func TestCassandraAcknowledgedDeliveryErrorsPreserveKnownCompletion(t *testing.T) {
	session := &Session{keyspace: "ks"}
	for _, export := range []bool{false, true} {
		command := protocol.Command{Type: "execute", RequestID: "ack", SQL: "UPDATE t SET value='safe' WHERE id=1"}
		if export {
			command.Export = &protocol.ExportRequest{Path: "/tmp/fixture.csv", Format: "csv"}
		}
		response := session.deliveryFailure(command, context.Background(), exportfile.ErrNullCollision)
		if response.OutcomeUnknown || !response.SQLCompleted || !response.Connected || response.TransactionStatus != "unsupported" {
			t.Fatalf("known acknowledgement changed: %#v", response)
		}
		if export && (response.Category != "export" || response.ExportPublication != "notPublished" || !strings.Contains(response.Message, "CSV NULL marker")) {
			t.Fatal("concrete export failure lost")
		}
		if !export && (response.Category != "result" || response.ExportPublication != "") {
			t.Fatal("nonexport failure invented publication state")
		}
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		cancelled := session.deliveryFailure(command, ctx, ctx.Err())
		if cancelled.Category != "cancelled" || cancelled.OutcomeUnknown || !cancelled.SQLCompleted {
			t.Fatal("Stop after acknowledgement became uncertain")
		}
	}
	observer := &attemptObserver{}
	observer.ObserveQuery(context.Background(), gocql.ObservedQuery{Host: &gocql.HostInfo{}, Err: nil})
	if !observer.sent.Load() || !observer.acknowledged.Load() {
		t.Fatal("successful driver request did not record acknowledgement")
	}
	observer = &attemptObserver{}
	observer.ObserveQuery(context.Background(), gocql.ObservedQuery{Host: &gocql.HostInfo{}, Err: errors.New("response lost")})
	if observer.acknowledged.Load() || !safeError(protocol.Command{}, context.Background(), errors.New("response lost"), true, observer.sent.Load()).OutcomeUnknown {
		t.Fatal("real lost acknowledgement no longer uncertain")
	}
}
func TestCassandraPartialDeliveryFailureDoesNotClaimWholeScriptCompletion(t *testing.T) {
	session := &Session{}
	failure := session.deliveryFailure(protocol.Command{Export: &protocol.ExportRequest{}}, context.Background(), errors.New("sink failure"))
	current := protocol.ResultSet{Columns: []protocol.Column{}, Rows: [][]*string{}, CommandTag: "UPDATE"}
	partial := session.completedPrefixFailure(failure, nil, current, 0, 2, time.Now())
	if partial.SQLCompleted || partial.OutcomeUnknown || partial.ExportPublication != "" || len(partial.ResultSets) != 1 {
		t.Fatal("confirmed prefix was confused with whole-script completion")
	}
	last := session.completedPrefixFailure(failure, nil, current, 0, 1, time.Now())
	if !last.SQLCompleted || len(last.ResultSets) != 1 || last.ExportPublication != "notPublished" {
		t.Fatal("completed final statement lost acknowledgement")
	}
}
func TestCassandraRepeatedWideEmptyResultsHaveSharedMetadataAndFrameBudget(t *testing.T) {
	columns := make([]protocol.Column, 512)
	for i := range columns {
		columns[i] = protocol.Column{Index: i, Name: strings.Repeat("column_\"<>&\n", 64), Engine: "cassandra", NativeType: "frozen<map<text, list<decimal>>>"}
	}
	budget := &displayBudget{}
	response := (&Session{}).response(protocol.Command{RequestID: "wide", SessionID: "wide", QueryID: "wide"})
	for range 1024 {
		if budget.retainColumns(columns) {
			response.ResultSets = append(response.ResultSets, protocol.ResultSet{Columns: columns, Rows: [][]*string{}, CommandTag: "SELECT"})
		}
	}
	if !budget.metadataOmitted || len(response.ResultSets) == 0 || len(response.ResultSets) >= 1024 {
		t.Fatal("metadata was not bounded across statements")
	}
	response.Columns = response.ResultSets[0].Columns
	response.Rows = response.ResultSets[0].Rows
	response.Truncated = true
	response.DisplayNotice = metadataLimitNotice
	encoded, err := json.Marshal(response)
	if err != nil || len(encoded) >= protocol.MaxFrameBytes || budget.bytes > retainedDataBytes {
		t.Fatalf("bounded response grew beyond frame: bytes=%d budget=%d err=%v", len(encoded), budget.bytes, err)
	}
	if budget.retainColumns([]protocol.Column{{Name: "tiny"}}) {
		t.Fatal("omitted result prefix resumed and changed streamed result indices")
	}
}
func TestCassandraScientificDecimalFilterRoundTripsExactWireValues(t *testing.T) {
	info := native(gocql.TypeDecimal)
	for _, test := range []struct {
		scale       int32
		coefficient []byte
	}{{2147483647, []byte{1}}, {-2147483648, []byte{1}}, {2147483647, []byte{255}}, {-2147483648, []byte{0}}, {5000, []byte{123}}, {-5000, []byte{255}}, {8, []byte{1, 2, 3}}} {
		wire := make([]byte, 4+len(test.coefficient))
		binary.BigEndian.PutUint32(wire, uint32(test.scale))
		copy(wire[4:], test.coefficient)
		text, err := renderValue(info, wire, false)
		if err != nil {
			t.Fatal(err)
		}
		roundtrip, err := (textParameter{Value: *text}).MarshalCQL(info)
		if err != nil || !bytes.Equal(wire, roundtrip) {
			t.Fatalf("decimal wire round trip failed for %s: err=%v", *text, err)
		}
		if len(roundtrip) > 16 {
			t.Fatal("decimal exponent expanded zeros")
		}
	}
	for input, want := range map[string]string{"1E3": "1E3", "-1.25e2": "-125", "+.5E-2": "0.005", "1.": "1", ".25": "0.25"} {
		value, err := parseDecimal(input)
		if err != nil {
			t.Fatalf("valid decimal %s rejected", input)
		}
		// Comparing ordinary forms can safely use bounded inf.Dec arithmetic/string.
		if input == "1E3" {
			if value.UnscaledBig().String() != "1" || value.Scale() != -3 {
				t.Fatal("positive exponent normalized by allocating zeros")
			}
		} else if value.String() != want {
			t.Fatalf("%s = %s, want %s", input, value.String(), want)
		}
	}
	for _, invalid := range []string{"", ".", "1e", "1e2e3", "1e2147483649", "1e-2147483648", "1e9223372036854775807", "1e-9223372036854775808", "NaN", "1_000", "1.2.3", strings.Repeat("1", 1024*1024+1)} {
		if _, err := parseDecimal(invalid); err == nil {
			t.Fatalf("invalid exact decimal accepted: %.40s", invalid)
		}
	}
}

func TestCassandraAcknowledgedDDLRemainsKnownWhenAgreementContextEnds(t *testing.T) {
	// In the pinned driver, conn.go's schema-change response branch deliberately
	// logs an agreement failure and returns the successful Iter: DDL is already
	// acknowledged. A cancellation during its later delivery must stay known.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	observer := &attemptObserver{}
	observer.ObserveQuery(ctx, gocql.ObservedQuery{Host: &gocql.HostInfo{}, Err: nil})
	if !observer.acknowledged.Load() {
		t.Fatal("confirmed DDL lost acknowledgement")
	}
	session := &Session{}
	response := session.deliveryFailure(protocol.Command{Type: "execute", SQL: "CREATE TABLE t(id int PRIMARY KEY)"}, ctx, ctx.Err())
	if response.OutcomeUnknown || !response.SQLCompleted || response.Category != "cancelled" {
		t.Fatal("schema agreement cancellation turned acknowledged DDL into an unknown write")
	}
}
