package postgres

import (
	"context"
	"errors"
	"reflect"
	"testing"

	"dbeer/helper/internal/tableedit"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type pgSequenceStateTestTx struct {
	pgx.Tx
	commands []string
	queries  int
	probeErr error
	value    string
	fail     string
}

func (tx *pgSequenceStateTestTx) Exec(_ context.Context, sql string, _ ...any) (pgconn.CommandTag, error) {
	tx.commands = append(tx.commands, sql)
	if sql == tx.fail {
		return pgconn.CommandTag{}, errors.New("control failed")
	}
	return pgconn.CommandTag{}, nil
}

func (tx *pgSequenceStateTestTx) QueryRow(_ context.Context, _ string, _ ...any) pgx.Row {
	tx.queries++
	if tx.queries == 1 {
		return pgSequenceStateTestRow{oid: 123, backend: 456}
	}
	return pgSequenceStateTestRow{value: tx.value, err: tx.probeErr}
}

type pgSequenceStateTestRow struct {
	oid, backend uint32
	value        string
	err          error
}

func (row pgSequenceStateTestRow) Scan(dest ...any) error {
	if row.err != nil {
		return row.err
	}
	if len(dest) == 2 {
		*dest[0].(*uint32), *dest[1].(*uint32) = row.oid, row.backend
	} else {
		*dest[0].(*string) = row.value
	}
	return nil
}

func TestStructureAdvancedSequenceSessionProbeClosesSavepoint(t *testing.T) {
	const name = "dbeer_advanced_sequence_observation"
	for _, tc := range []struct {
		name     string
		probeErr error
		value    string
		fail     string
		want     pgAdvancedSequenceSession
		wantErr  bool
		commands []string
	}{
		{name: "warm exact bigint", value: "9007199254740993", want: pgAdvancedSequenceSession{OID: 123, BackendPID: 456, Defined: true, Value: "9007199254740993"}},
		{name: "cold undefined", probeErr: &pgconn.PgError{Code: "55000"}, want: pgAdvancedSequenceSession{OID: 123, BackendPID: 456}},
		{name: "permission is not undefined", probeErr: &pgconn.PgError{Code: "42501"}, wantErr: true},
		{name: "other prerequisite failure", probeErr: &pgconn.PgError{Code: "55006"}, wantErr: true},
		{name: "malformed bigint", value: "09007199254740993", wantErr: true},
		{name: "savepoint failure", fail: "SAVEPOINT " + name, wantErr: true, commands: []string{"SAVEPOINT " + name}},
		{name: "rollback failure", probeErr: &pgconn.PgError{Code: "55000"}, fail: "ROLLBACK TO SAVEPOINT " + name, wantErr: true, commands: []string{"SAVEPOINT " + name, "ROLLBACK TO SAVEPOINT " + name}},
		{name: "release failure", value: "1", fail: "RELEASE SAVEPOINT " + name, wantErr: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tx := &pgSequenceStateTestTx{probeErr: tc.probeErr, value: tc.value, fail: tc.fail}
			state, err := pgAdvancedSessionSequenceState(context.Background(), pgCatalogReader(tx), tableedit.Target{Schema: "test", Table: "counter"})
			if (err != nil) != tc.wantErr || state != tc.want {
				t.Fatal("session observation returned the wrong state or error")
			}
			wantCommands := tc.commands
			if wantCommands == nil {
				wantCommands = []string{"SAVEPOINT " + name}
				if tc.probeErr != nil {
					wantCommands = append(wantCommands, "ROLLBACK TO SAVEPOINT "+name)
				}
				wantCommands = append(wantCommands, "RELEASE SAVEPOINT "+name)
			}
			if !reflect.DeepEqual(tx.commands, wantCommands) {
				t.Fatal("the observation did not close its savepoint correctly")
			}
		})
	}
}

func TestStructureAdvancedSequenceSessionBinding(t *testing.T) {
	state := pgAdvancedSequenceSession{OID: 123, BackendPID: 456}
	for _, tc := range []struct {
		definition map[string]any
		want       bool
	}{
		{map[string]any{"class": map[string]any{"oid": float64(123)}}, true},
		{map[string]any{"class": map[string]any{"oid": float64(124)}}, false},
		{map[string]any{"class": map[string]any{"oid": float64(123.5)}}, false},
		{map[string]any{"class": map[string]any{"oid": "123"}}, true},
		{map[string]any{"class": map[string]any{"oid": "0123"}}, false},
		{map[string]any{"class": map[string]any{"oid": "124"}}, false},
		{nil, false},
	} {
		if pgAdvancedSequenceSessionBound(state, tc.definition) != tc.want {
			t.Fatal("session state accepted a different or malformed sequence identity")
		}
	}
	if pgAdvancedSequenceSessionBound(pgAdvancedSequenceSession{}, map[string]any{"class": map[string]any{"oid": float64(0)}}) {
		t.Fatal("missing session state acquired a catalog binding")
	}
}

func TestStructureAdvancedSequenceSessionPreservation(t *testing.T) {
	before := pgAdvancedSequenceValue{
		Value: "10", Called: true,
		Session:    pgAdvancedSequenceSession{OID: 123, BackendPID: 456, Defined: true, Value: "1"},
		Definition: map[string]any{"class": map[string]any{"oid": float64(123)}},
	}
	if !pgAdvancedSequencePreserved(before, before) {
		t.Fatal("unchanged owning-backend sequence state did not preserve")
	}
	for _, state := range []pgAdvancedSequenceSession{
		{OID: 124, BackendPID: 456, Defined: true, Value: "1"},
		{OID: 123, BackendPID: 457, Defined: true, Value: "1"},
		{OID: 123, BackendPID: 456, Defined: false},
		{OID: 123, BackendPID: 456, Defined: true, Value: "2"},
	} {
		after := before
		after.Session = state
		if pgAdvancedSequencePreserved(before, after) {
			t.Fatal("a changed sequence identity, backend or last returned value preserved")
		}
	}
}

func TestStructureAdvancedSequenceSessionWarmCacheLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	for _, tc := range []struct {
		name, options, first, second string
		cached                       bool
	}{
		{"warm_cache10", "START WITH 9007199254740993 CACHE 10", "9007199254740993", "9007199254740994", true},
		{"warm_cache1", "CACHE 1", "1", "2", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f.exec("CREATE TABLE " + f.table(tc.name) + "(id bigint GENERATED BY DEFAULT AS IDENTITY (" + tc.options + "),payload text)")
			f.exec("ALTER TABLE " + f.table(tc.name) + " ENABLE ROW LEVEL SECURITY")
			f.exec("INSERT INTO " + f.table(tc.name) + "(id,payload) VALUES(42,'retained')")
			target := tableedit.Target{Schema: f.schema, Table: tc.name}
			sequence := tableedit.Target{Schema: f.schema, Table: tc.name + "_id_seq"}
			qualified := pgx.Identifier{sequence.Schema, sequence.Table}.Sanitize()
			var first string
			if f.conn.QueryRow(ctx, `SELECT pg_catalog.nextval($1::pg_catalog.regclass)::pg_catalog.text`, qualified).Scan(&first) != nil || first != tc.first {
				t.Fatal("fixture could not warm the owning backend's sequence cache")
			}
			b, err := (&Session{conn: f.conn}).StructureLoad(ctx, target)
			if err != nil || b.Advanced == nil {
				t.Fatal("fixture could not capture advanced table metadata")
			}
			tx, err := f.conn.Begin(ctx)
			if err != nil {
				t.Fatal("fixture could not start the owning transaction")
			}
			defer tx.Rollback(ctx)
			if _, err = tx.Exec(ctx, "LOCK TABLE ONLY "+f.table(tc.name)+" IN ACCESS EXCLUSIVE MODE"); err != nil {
				t.Fatal("fixture could not lock the owned table")
			}
			proof, err := pgAdvancedDataCapture(ctx, tx, b, tableedit.Condition{Operation: tableedit.Operation{Kind: "backfill"}})
			if err != nil || proof == nil || len(proof.Sequences) != 1 {
				t.Fatal("fixture could not capture exact owned sequence state")
			}
			before := proof.Sequences[sequence]
			if !before.Session.Defined || before.Session.Value != tc.first || before.Session.BackendPID != f.conn.PgConn().PID() {
				t.Fatal("warm exact session sequence state was not retained")
			}
			if proof.Verify(ctx, tx) != nil {
				t.Fatal("unchanged warm cached sequence did not preserve")
			}
			var second string
			if tx.QueryRow(ctx, `SELECT pg_catalog.nextval($1::pg_catalog.regclass)::pg_catalog.text`, qualified).Scan(&second) != nil || second != tc.second {
				t.Fatal("fixture could not consume one owning-backend sequence value")
			}
			after, err := pgAdvancedReadSequence(ctx, tx, sequence)
			if err != nil || (before.Value == after.Value) != tc.cached || before.Called != after.Called {
				t.Fatal("fixture did not exercise the expected persistent sequence tuple")
			}
			if pgAdvancedSequencePreserved(before, after) || proof.Verify(ctx, tx) == nil {
				t.Fatal("owning-backend cached consumption was accepted as preservation")
			}
			if tx.Rollback(ctx) != nil {
				t.Fatal("fixture rollback failed")
			}
			var retained string
			if f.conn.QueryRow(ctx, `SELECT pg_catalog.currval($1::pg_catalog.regclass)::pg_catalog.text`, qualified).Scan(&retained) != nil || retained != tc.second {
				t.Fatal("fixture incorrectly treated sequence consumption as rolled back")
			}
		})
	}
}

func TestStructureAdvancedSequenceSessionColdAndPrivilegeLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	f.exec("CREATE TABLE " + f.table("cold") + "(id bigint GENERATED BY DEFAULT AS IDENTITY(CACHE 10),payload text)")
	f.exec("CREATE FUNCTION " + f.table("currval") + "(pg_catalog.regclass) RETURNS pg_catalog.int8 LANGUAGE sql AS 'SELECT 888::pg_catalog.int8'")
	target := tableedit.Target{Schema: f.schema, Table: "cold_id_seq"}
	if _, err := pgAdvancedSessionSequenceState(ctx, f.conn, target); err == nil || f.conn.PgConn().TxStatus() != 'I' {
		t.Fatal("a bare connection started or acquired an Apply-only sequence observation")
	}
	role := f.schema + "_restricted"
	f.exec("CREATE ROLE " + pgx.Identifier{role}.Sanitize() + " NOLOGIN")
	t.Cleanup(func() { f.exec("DROP ROLE " + pgx.Identifier{role}.Sanitize()) })
	tx, err := f.conn.Begin(ctx)
	if err != nil {
		t.Fatal("fixture could not start the owning transaction")
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, "SET LOCAL search_path="+pgx.Identifier{f.schema}.Sanitize()+",pg_catalog"); err != nil {
		t.Fatal("fixture could not select its shadow-function search path")
	}
	var searchPath string
	if tx.QueryRow(ctx, "SHOW search_path").Scan(&searchPath) != nil {
		t.Fatal("fixture could not observe its search path")
	}
	for i := 0; i < 3; i++ {
		state, err := pgAdvancedSessionSequenceState(ctx, pgCatalogReader(tx), target)
		if err != nil || state.Defined || state.Value != "" || state.OID == 0 {
			t.Fatal("cold currval was not represented as undefined")
		}
	}
	var value string
	var called bool
	if tx.QueryRow(ctx, "SELECT last_value::pg_catalog.text,is_called FROM "+f.table(target.Table)).Scan(&value, &called) != nil || value != "1" || called {
		t.Fatal("cold observation advanced or changed the persistent sequence tuple")
	}
	if _, err = tx.Exec(ctx, "SET LOCAL ROLE "+pgx.Identifier{role}.Sanitize()); err != nil {
		t.Fatal("fixture could not select its restricted role")
	}
	if _, err = pgAdvancedSessionSequenceState(ctx, tx, target); err == nil {
		t.Fatal("a sequence privilege denial was accepted as undefined currval")
	}
	var usable bool
	if tx.QueryRow(ctx, "SELECT true").Scan(&usable) != nil || !usable {
		t.Fatal("a handled currval failure poisoned the owning transaction")
	}
	var afterPath, afterRole string
	if tx.QueryRow(ctx, "SHOW search_path").Scan(&afterPath) != nil || afterPath != searchPath || tx.QueryRow(ctx, "SELECT current_user").Scan(&afterRole) != nil || afterRole != role {
		t.Fatal("sequence observation changed the caller's search path or role")
	}
}

func TestStructureAdvancedSequenceSessionOtherBackendScopeLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	f.exec("CREATE SEQUENCE " + f.table("external_cache") + " CACHE 10")
	target := tableedit.Target{Schema: f.schema, Table: "external_cache"}
	qualified := pgx.Identifier{target.Schema, target.Table}.Sanitize()
	if _, err := f.observer.Exec(ctx, `SELECT pg_catalog.nextval($1::pg_catalog.regclass)`, qualified); err != nil {
		t.Fatal("fixture could not warm its other backend's cache")
	}
	tx, err := f.conn.Begin(ctx)
	if err != nil {
		t.Fatal("fixture could not start the owning transaction")
	}
	defer tx.Rollback(ctx)
	before, err := pgAdvancedReadSequence(ctx, tx, target)
	if err != nil || before.Session.Defined {
		t.Fatal("fixture could not observe its own cold sequence session")
	}
	if _, err = f.observer.Exec(ctx, `SELECT pg_catalog.nextval($1::pg_catalog.regclass)`, qualified); err != nil {
		t.Fatal("fixture could not consume its other backend's private cached value")
	}
	after, err := pgAdvancedReadSequence(ctx, tx, target)
	// Other backends' private cache positions are deliberately outside this proof.
	if err != nil || !pgAdvancedSequencePreserved(before, after) {
		t.Fatal("the sequence observation claimed a global private-cache guarantee")
	}
}
