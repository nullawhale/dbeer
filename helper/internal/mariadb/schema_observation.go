package mariadb

import (
	"context"
	"crypto/sha256"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	"encoding/hex"
	"encoding/json"
	wire "github.com/go-mysql-org/go-mysql/mysql"
	"sort"
	"time"
)

// Observation fingerprints selected native metadata, never a global catalog or
// an installation. Its readonly service connection remains independent of tabs.
func (s *Session) ObserveSchema(ctx context.Context, c protocol.Command) protocol.Response {
	failure := func(category, message string) protocol.Response {
		r := protocol.ErrorResponse(c, category, message)
		r.Connected, r.TransactionStatus = !s.closed.Load(), s.TransactionStatus()
		return r
	}
	if c.SchemaObservation == nil || !c.SchemaObservation.Valid() {
		return failure("validation", "Invalid native schema observation request.")
	}
	if c.SchemaObservation.Action != "poll" {
		return failure("capability", "MariaDB schema observation uses native metadata fingerprints and requires no installation.")
	}
	if s.TransactionStatus() != "idle" {
		return failure("busy", "Native schema observation requires an idle readonly service connection.")
	}
	if _, ok := ctx.Deadline(); !ok {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, ExecuteTimeout)
		defer cancel()
	}
	targets := append([]protocol.SchemaObservationTable(nil), c.SchemaObservation.Tables...)
	sort.Slice(targets, func(i, j int) bool {
		if targets[i].Schema != targets[j].Schema {
			return targets[i].Schema < targets[j].Schema
		}
		return targets[i].Name < targets[j].Name
	})
	for _, target := range targets {
		if !sc.ValidName(target.Schema) || !sc.ValidName(target.Name) {
			return failure("validation", "Native observation target exceeds identifier bounds.")
		}
	}
	observation := protocol.SchemaObservation{Engine: "mariadb", Action: "poll", Tables: c.SchemaObservation.Tables, Mode: "fingerprint", Complete: true, Notices: []string{"Selected native metadata is rechecked within bounded best-effort observations; this is not an atomic global schema snapshot."}}
	var reader *mariaSchemaCapture
	var observed error
	response := s.executeWith(ctx, c, func(_ *collector, _ *wire.Result) error {
		limits := sc.Limits{Nodes: 100, Members: 25000, Bytes: 16 << 20, Scalar: 65536}
		sink := sc.NewCollector(ctx, limits)
		r := &mariaSchemaCapture{s: s, ctx: ctx, spec: sc.CaptureSpec{Limits: limits}, sink: sink, definitions: map[string]string{}}
		reader = r
		run := func() error {
			if s.TransactionStatus() != "idle" {
				return sc.ErrInvalid
			}
			state, e := r.tracked("SELECT VERSION(),CURRENT_USER(),CURRENT_ROLE(),@@sql_mode,@@explicit_defaults_for_timestamp,@@character_set_client,@@character_set_connection,@@character_set_results,@@tx_read_only,@@check_constraint_checks")
			if e != nil {
				return e
			}
			if len(state) != 1 || len(state[0]) != 10 || mariaText(state[0], 0) != s.serverVersion || s.serverIdentity == "" || mariaText(state[0], 8) != "1" {
				return sc.ErrInvalid
			}
			for _, i := range []int{5, 6, 7} {
				if mariaText(state[0], i) != "utf8mb4" {
					return sc.ErrInvalid
				}
			}
			r.sqlMode = mariaText(state[0], 3)
			r.explicitTimestamp = mariaText(state[0], 4) == "1"
			for _, target := range targets {
				rows, e := r.tracked("SELECT TABLE_NAME,ENGINE,TABLE_COLLATION,CREATE_OPTIONS,TABLE_COMMENT,TABLE_TYPE FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? AND TABLE_TYPE IN ('BASE TABLE','SYSTEM VERSIONED')", target.Schema, target.Name)
				if e != nil {
					return e
				}
				if len(rows) != 1 || len(rows[0]) != 6 || mariaText(rows[0], 0) != target.Name {
					return sc.ErrInvalid
				}
				if e = r.table(sc.Ref{Kind: "table", Schema: target.Schema, Name: target.Name}, rows[0]); e != nil {
					return e
				}
			}
			for _, read := range r.reads {
				rows, e := r.read(read.sql, read.show, read.args...)
				if e != nil {
					return e
				}
				digest := mariaRowsDigest(rows)
				if read.indexOnly {
					if len(rows) != 1 || len(rows[0]) < 2 || rows[0][1] == nil {
						return sc.ErrInvalid
					}
					digest = mariaDefinitionIndexDigest(*rows[0][1], r.sqlMode)
				}
				if digest != read.digest {
					observation.Complete = false
				}
			}
			if e := r.nativeDefaultsFresh(); e != nil {
				observation.Complete = false
			}
			if e := r.nativePeriodsFresh(); e != nil {
				observation.Complete = false
			}
			for _, issue := range sink.Capture.Issues {
				if issue.BlocksEquality {
					observation.Complete = false
				}
			}
			if !observation.Complete {
				observation.Notices = append(observation.Notices, "Native metadata changed or contains properties without complete lossless witnesses. Build explicitly and review the affected table.")
				return nil
			}
			witnesses := []string{}
			for _, read := range r.reads {
				witnesses = append(witnesses, read.digest)
			}
			for _, read := range r.fieldReads {
				witnesses = append(witnesses, read.digest)
			}
			raw, e := json.Marshal(struct {
				Identity  string
				Tables    []sc.Table
				Witnesses []string
			}{s.serverIdentity, sink.Capture.Tables, witnesses})
			if e != nil || len(raw) > limits.Bytes {
				return sc.ErrLimit
			}
			digest := sha256.Sum256(raw)
			observation.Revision = hex.EncodeToString(digest[:])
			return nil
		}
		observed = run()
		if r.wireError != nil {
			return r.wireError
		}
		if observed != nil {
			return &adapter.ConnectionError{Category: "metadata", Message: "Native schema observation requires complete metadata and an already readonly utf8mb4 service context."}
		}
		return nil
	})
	if response.Type == "error" {
		response.Message = "Native MariaDB schema observation is unavailable in the current readonly context or metadata scope."
		response.ErrorPosition = 0
		return response
	}
	if observed != nil || reader == nil {
		return failure("metadata", "Native schema observation is incomplete.")
	}
	observation.ObservedAt = time.Now().UTC().Format(time.RFC3339Nano)
	return protocol.Response{Type: "monitor.schema.result", RequestID: c.RequestID, SessionID: c.SessionID, QueryID: c.QueryID, SchemaObservation: &observation, Connected: !s.closed.Load(), TransactionStatus: s.TransactionStatus()}
}
