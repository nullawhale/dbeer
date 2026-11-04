package postgres

import (
	"context"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

func TestPostgresTransferCommitKeepsUnknownCompletionDistinctFromKnownRollback(t *testing.T) {
	for _, err := range []error{context.Canceled, context.DeadlineExceeded, errors.New("disposable transport failure"), &pgconn.PgError{Severity: "ERROR", Code: "40003"}, &pgconn.PgError{Severity: "PANIC", Code: "XX000"}, &pgconn.PgError{Severity: "localized diagnostic", SeverityUnlocalized: "FATAL", Code: "XX000"}, &pgconn.PgError{Severity: "ERROR", Code: "08006"}, &pgconn.PgError{Severity: "ERROR", Code: "57P01"}} {
		if !transferCommitOutcomeUnknown(err) {
			t.Fatal("uncertain COMMIT outcome was classified as a known rollback")
		}
	}
	for _, code := range []string{"40001", "23505", "23514"} {
		if transferCommitOutcomeUnknown(&pgconn.PgError{Severity: "ERROR", Code: code}) {
			t.Fatal("an authoritative server rejection was classified as uncertain")
		}
	}
}
