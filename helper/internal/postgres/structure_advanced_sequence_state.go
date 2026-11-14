package postgres

import (
	"context"
	"errors"
	"strconv"
	"time"

	"dbeer/helper/internal/tableedit"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// This Apply-only observation complements the persistent sequence tuple with
// the owning backend's last returned value; other backends' caches are private.
// Equal final observations do not count transient or deliberately restored calls.
type pgAdvancedSequenceSession struct {
	OID        uint32
	BackendPID uint32
	Defined    bool
	Value      string
}

func pgAdvancedSessionSequenceState(ctx context.Context, q structureReader, target tableedit.Target) (pgAdvancedSequenceSession, error) {
	var state pgAdvancedSequenceSession
	if !target.Valid() || target.Create {
		return state, tableedit.ErrUnsupported
	}
	if wrapped, ok := q.(pgStructureCatalogReader); ok {
		q = wrapped.structureReader
	}
	tx, ok := q.(pgx.Tx)
	if !ok {
		return state, tableedit.ErrUnsupported
	}
	// The structure operation owns this transaction and its savepoint namespace.
	const savepoint = "dbeer_advanced_sequence_observation"
	if _, err := tx.Exec(ctx, "SAVEPOINT "+savepoint); err != nil {
		return state, tableedit.ErrUnsupported
	}
	reader := pgCatalogReader(tx)
	probed := false
	err := reader.QueryRow(ctx, `SELECT c.oid,pg_catalog.pg_backend_pid() FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relname=$2 AND c.relkind='S'`, target.Schema, target.Table).Scan(&state.OID, &state.BackendPID)
	if err == nil && state.OID != 0 && state.BackendPID != 0 {
		probed = true
		err = reader.QueryRow(ctx, `SELECT pg_catalog.currval($1::pg_catalog.regclass)::pg_catalog.text`, state.OID).Scan(&state.Value)
	} else if err == nil {
		err = tableedit.ErrUnsupported
	}
	// currval's expected undefined error must never poison the owning transaction.
	// Explicit RELEASE also removes a rolled-back savepoint; pgx.Tx.Rollback alone
	// leaves its server savepoint live after closing the nested transaction wrapper.
	cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), time.Second)
	defer cancel()
	if err != nil {
		if _, rollbackErr := tx.Exec(cleanup, "ROLLBACK TO SAVEPOINT "+savepoint); rollbackErr != nil {
			return pgAdvancedSequenceSession{}, tableedit.ErrUnsupported
		}
	}
	if _, releaseErr := tx.Exec(cleanup, "RELEASE SAVEPOINT "+savepoint); releaseErr != nil {
		return pgAdvancedSequenceSession{}, tableedit.ErrUnsupported
	}
	if ctx.Err() != nil {
		return pgAdvancedSequenceSession{}, ctx.Err()
	}
	if err != nil {
		var server *pgconn.PgError
		if probed && errors.As(err, &server) && server.Code == "55000" {
			state.Value = ""
			return state, nil
		}
		return pgAdvancedSequenceSession{}, tableedit.ErrUnsupported
	}
	value, parseErr := strconv.ParseInt(state.Value, 10, 64)
	if parseErr != nil || strconv.FormatInt(value, 10) != state.Value {
		return pgAdvancedSequenceSession{}, tableedit.ErrUnsupported
	}
	state.Defined = true
	return state, nil
}

// currval locks this exact OID for the top transaction before tuple observation.
func pgAdvancedSequenceSessionBound(state pgAdvancedSequenceSession, definition map[string]any) bool {
	class, ok := definition["class"].(map[string]any)
	if !ok || state.OID == 0 || state.BackendPID == 0 {
		return false
	}
	switch oid := class["oid"].(type) {
	case string:
		parsed, err := strconv.ParseUint(oid, 10, 32)
		return err == nil && strconv.FormatUint(parsed, 10) == oid && parsed == uint64(state.OID)
	case float64:
		// Catalog OIDs fit exactly in float64; counters/configuration never do.
		return oid == float64(state.OID)
	}
	return false
}
