package cassandra

import (
	"context"
	"errors"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
	gocql "github.com/apache/cassandra-gocql-driver/v2"
)

type requestFailure int

func (e requestFailure) Code() int     { return int(e) }
func (requestFailure) Message() string { return "secret SQL credentials and results" }
func (e requestFailure) Error() string { return e.Message() }
func TestCassandraUnknownWriteOutcomesAndSafeErrors(t *testing.T) {
	for _, test := range []struct {
		name                 string
		err                  error
		write, sent, unknown bool
	}{
		{"network before send", errors.New("secret SQL credentials and results"), true, false, false},
		{"network after send", errors.New("secret SQL credentials and results"), true, true, true},
		{"read network", errors.New("secret SQL credentials and results"), false, true, false},
		{"write timeout", requestFailure(gocql.ErrCodeWriteTimeout), true, true, true},
		{"CAS unknown", requestFailure(gocql.ErrCodeCASWriteUnknown), true, true, true},
		{"syntax rejection", requestFailure(gocql.ErrCodeSyntax), true, true, false},
		{"unavailable rejection", requestFailure(gocql.ErrCodeUnavailable), true, true, false},
		{"access denied", requestFailure(gocql.ErrCodeUnauthorized), true, true, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			response := safeError(protocol.Command{}, context.Background(), test.err, test.write, test.sent)
			if response.OutcomeUnknown != test.unknown {
				t.Fatalf("unknown=%v want=%v", response.OutcomeUnknown, test.unknown)
			}
			if strings.Contains(response.Message, "secret") || response.SQLState != "" || response.TransactionStatus != "unsupported" {
				t.Fatalf("unsafe error: %#v", response)
			}
		})
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if response := safeError(protocol.Command{}, ctx, ctx.Err(), true, true); response.Category != "cancelled" || !response.OutcomeUnknown {
		t.Fatal("Stop incorrectly confirmed a sent write's outcome")
	}
	if response := safeError(protocol.Command{}, ctx, ctx.Err(), true, false); response.OutcomeUnknown {
		t.Fatal("Stop before send invented an unknown outcome")
	}
}
