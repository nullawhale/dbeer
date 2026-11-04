package datatransfer

import (
	"errors"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

// Terminal database outcomes remain authoritative after a late cancellation.
func TestTransferReviewCancelRetainsAuthoritativeTerminalOutcome(t *testing.T) {
	for _, state := range []string{"completed", "outcomeUnknown"} {
		t.Run(state, func(t *testing.T) {
			target := &fakeDatabase{}
			if state == "outcomeUnknown" {
				target.failure = errors.New("disposable commit uncertainty")
				target.unknown = true
			}
			m := manager(t, &fakeDatabase{}, target, 0)
			request := protocol.TransferRequest{Mode: "csv", Target: endpoint(), Headers: []string{"id"}, Rows: [][]protocol.CellValue{{text("1")}},
				Columns: []protocol.TransferColumn{{SourceIndex: 0, Name: "id", Type: "integer"}}}
			started := m.Handle(protocol.Command{Type: "transfer.preview", RequestID: "preview", Transfer: &request})
			ready := waitTransfer(t, m, started.Transfer.JobID)
			m.Handle(protocol.Command{Type: "transfer.apply", RequestID: "apply", Transfer: &protocol.TransferRequest{JobID: ready.JobID, PlanDigest: ready.PlanDigest, Confirmed: true}})
			terminal := waitTransfer(t, m, ready.JobID)
			if terminal.State != state {
				t.Fatal("review fixture did not reach its authoritative outcome")
			}
			j := m.jobs[ready.JobID]
			deadline := time.Now().Add(3 * time.Second)
			for {
				j.mu.Lock()
				active := j.active
				j.mu.Unlock()
				if !active {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("review fixture did not finish cleanup")
				}
				time.Sleep(time.Millisecond)
			}
			cancelled := m.Handle(protocol.Command{Type: "transfer.cancel", RequestID: "cancel-terminal", Transfer: &protocol.TransferRequest{JobID: ready.JobID}})
			if cancelled.Transfer == nil || cancelled.Transfer.State != state || !cancelled.Transfer.Valid() || cancelled.Transfer.OutcomeUnknown != terminal.OutcomeUnknown {
				t.Fatal("cancelling a terminal transfer changed or invalidated its database outcome")
			}
		})
	}
}

func TestTransferReviewRealConversionRejectsChangedSignificantDigits(t *testing.T) {
	column := protocol.TransferColumn{SourceIndex: 0, Name: "measurement", Type: "real"}
	for _, value := range []string{"9007199254740993", "0.100000000000000001", "1e-999"} {
		if _, err := Normalize(text(value), column, "postgresql"); err == nil {
			t.Fatal("REAL conversion silently changed significant numeric digits")
		}
	}
	for _, value := range []string{"0.1", "-0", "0.10000000149011612", "5e-324", "1.7976931348623157e308"} {
		if _, err := Normalize(text(value), column, "postgresql"); err != nil {
			t.Fatal("a shortest round-trip floating value was rejected")
		}
	}
}

func TestTransferReviewAllFractionalDecimalAcceptsZero(t *testing.T) {
	column := protocol.TransferColumn{SourceIndex: 0, Name: "fraction", Type: "decimal", Precision: 2, Scale: 2}
	for _, engine := range []string{"postgresql", "mysql"} {
		for _, value := range []string{"0", "0.00", "-0.000", "0.01"} {
			if _, err := Normalize(text(value), column, engine); err != nil {
				t.Fatal("a representable all-fractional decimal value was rejected")
			}
		}
	}
}

func TestTransferReviewTemporalPrecisionAndConvertedYearAreRepresentable(t *testing.T) {
	for _, engine := range []string{"postgresql", "mysql"} {
		for _, kind := range []string{"timestamp", "timestampTZ"} {
			column := protocol.TransferColumn{SourceIndex: 0, Name: "moment", Type: kind}
			value := "2026-01-01 00:00:00.000000001"
			if kind == "timestampTZ" {
				value = "2026-01-01T00:00:00.000000001Z"
			}
			if _, err := Normalize(text(value), column, engine); err == nil {
				t.Fatal("timestamp conversion silently rounded sub-microsecond digits")
			}
		}
	}
	column := protocol.TransferColumn{SourceIndex: 0, Name: "moment", Type: "timestampTZ"}
	for _, engine := range []string{"postgresql", "mysql"} {
		for _, value := range []string{"9999-12-31T23:59:59-01:00", "0001-01-01T00:00:00+01:00"} {
			if _, err := Normalize(text(value), column, engine); err == nil {
				t.Fatal("UTC conversion crossed the portable year boundary")
			}
		}
	}
}
