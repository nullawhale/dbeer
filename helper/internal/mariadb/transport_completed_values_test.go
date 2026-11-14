package mariadb

import (
	"context"
	"io"
	"net"
	"reflect"
	"testing"

	"dbeer/helper/internal/protocol"
	"github.com/go-mysql-org/go-mysql/client"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func TestMariaDBCompletedFailureRetainsNativeValues(t *testing.T) {
	for _, native := range []bool{false, true} {
		for _, boundary := range []string{"sourceMetadata", "preparedClose"} {
			name := boundary + "/legacy"
			if native {
				name = boundary + "/native"
			}
			t.Run(name, func(t *testing.T) {
				transport, peer := net.Pipe()
				defer peer.Close()
				s := &Session{work: &connection{client: &client.Conn{}, transport: transport}}
				s.transaction.Store("idle")
				defer s.Close()
				command := protocol.Command{Type: "execute", RequestID: "completed", SessionID: "owner", QueryID: "query"}
				if native {
					command.ResultValues = protocol.NativeResultValuesFormat
				}
				var expectedRows [][]*string
				var expectedNative [][]protocol.NativeValue
				source := mariadbReadOnlySource("captured readonly origin")
				result := s.executeWith(context.Background(), command, func(c *collector, r *wire.Result) error {
					r.Resultset = wire.NewResultset(5)
					r.Fields = []*wire.Field{
						{Name: []byte("amount"), Type: wire.MYSQL_TYPE_NEWDECIMAL, Charset: 63},
						{Name: []byte("bytes"), Type: wire.MYSQL_TYPE_BLOB, Charset: 63},
						{Name: []byte("empty"), Type: wire.MYSQL_TYPE_VAR_STRING, Charset: 45},
						{Name: []byte("text_null"), Type: wire.MYSQL_TYPE_VAR_STRING, Charset: 45},
						{Name: []byte("sql_null"), Type: wire.MYSQL_TYPE_VAR_STRING, Charset: 45},
					}
					if err := c.columns(r); err != nil {
						return err
					}
					values := []wire.FieldValue{
						wire.NewFieldValue(wire.FieldValueTypeString, 0, []byte("12345678901234567890.12345678901234567890123456789012345678")),
						wire.NewFieldValue(wire.FieldValueTypeString, 0, []byte{0, 255, 128}),
						wire.NewFieldValue(wire.FieldValueTypeString, 0, []byte{}),
						wire.NewFieldValue(wire.FieldValueTypeString, 0, []byte("NULL")),
						wire.NewFieldValue(wire.FieldValueTypeNull, 0, nil),
					}
					if err := c.row(values); err != nil {
						return err
					}
					if err := c.row(values); err != nil {
						return err
					}
					expectedRows = c.response.Rows
					expectedNative = c.response.NativeValues
					c.response.StorageTokens = []string{"native-token", "native-token"}
					c.response.Source = source
					if boundary == "sourceMetadata" {
						c.sourceReadCompleted = true
						return io.ErrUnexpectedEOF
					}
					c.statementCleanupFailed = true
					return nil
				})
				if result.Type != "error" || !result.SQLCompleted || result.OutcomeUnknown || result.Connected || s.TransactionStatus() != "unknown" || !s.closed.Load() {
					t.Fatal("completed failure changed acknowledgement or owner retirement")
				}
				if len(result.ResultSets) != 1 {
					t.Fatal("completed SELECT result was discarded")
				}
				set := result.ResultSets[0]
				if !reflect.DeepEqual(set.Rows, expectedRows) || !reflect.DeepEqual(set.NativeValues, expectedNative) || set.RowCount != 2 || set.DisplayedRowCount != 2 || set.CommandTag != "SELECT" || !reflect.DeepEqual(set.StorageTokens, []string{"native-token", "native-token"}) {
					t.Fatal("completed SELECT lost exact values, multiplicity or storage evidence")
				}
				if native && (set.NativeValues == nil || !protocol.NativeMatrixValid(set.NativeValues, len(set.Rows), len(set.Columns))) {
					t.Fatal("completed native matrix missing or malformed")
				}
				if !native && set.NativeValues != nil {
					t.Fatal("legacy completed result acquired an unsolicited native matrix")
				}
				if boundary == "preparedClose" && (result.TransactionStatus != "unknown" || result.AcknowledgedTransactionStatus != "idle" || set.Source != source) {
					t.Fatal("prepared cleanup lost acknowledged transaction status or captured source")
				}
				if boundary == "sourceMetadata" && (set.Source == nil || set.Source.ReadOnlyReason != mariadbSourceUnavailable || !reflect.DeepEqual(result.NativeValues, expectedNative)) {
					t.Fatal("source metadata failure lost readonly origin or primary native matrix")
				}
			})
		}
	}
}
