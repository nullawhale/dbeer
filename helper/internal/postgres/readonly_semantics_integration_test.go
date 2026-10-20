package postgres

import (
	"context"
	"fmt"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

// The classifier assesses SQL structure, not server overload/type resolution.
// This proves the additional server boundary for a hidden persistent write and
// records PostgreSQL's documented temporary-table exception explicitly.
func TestPostgresReadonlyBoundsHiddenBuiltinOverloadEffects(t *testing.T) {
	h := newSQLIntegrationSession(t, 5*time.Second)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	opened, err := Open(ctx, h.connection)
	if err != nil {
		t.Fatal("cannot open semantic readonly fixture")
	}
	physical := opened.(*Session)
	defer physical.Close()
	suffix := fmt.Sprint(time.Now().UnixNano())
	schema := "dbeer_policy_semantics_" + suffix
	table := "dbeer_policy_persistent_" + suffix
	if _, err = h.observer.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal("cannot create semantic readonly schema")
	}
	t.Cleanup(func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if _, err := h.observer.Exec(cleanup, "DROP SCHEMA "+schema+" CASCADE"); err != nil {
			t.Error("cannot remove semantic readonly schema")
		}
		if _, err := h.observer.Exec(cleanup, "DROP TABLE IF EXISTS "+table); err != nil {
			t.Error("cannot remove semantic readonly table")
		}
	})
	if _, err = h.observer.Exec(ctx, "CREATE TABLE "+table+" (id integer)"); err != nil {
		t.Fatal("cannot create semantic readonly table")
	}
	function := "CREATE FUNCTION " + schema + ".abs(text) RETURNS integer LANGUAGE plpgsql VOLATILE AS $$ BEGIN IF $1='temporary' THEN INSERT INTO pg_temp.dbeer_semantic_temp VALUES(1); ELSE INSERT INTO public." + table + " VALUES(1); END IF; RETURN 1; END $$"
	if _, err = h.observer.Exec(ctx, function); err != nil {
		t.Fatal("cannot create semantic readonly overload")
	}
	execute := func(sql string) protocol.Response { return physical.Execute(ctx, protocol.Command{SQL: sql}) }
	if execute("CREATE TEMP TABLE dbeer_semantic_temp(id integer)").Type != "query.result" || execute("SET search_path TO "+schema+",public").Type != "query.result" {
		t.Fatal("cannot prepare semantic readonly session")
	}
	if err := physical.SetReadOnly(ctx, true); err != nil {
		t.Fatal("cannot install server readonly")
	}
	if result := execute("SELECT abs('persistent')"); result.Type != "error" || result.SQLState != "25006" {
		t.Fatal("server readonly did not reject hidden persistent write")
	}
	if result := execute("SELECT abs('temporary')"); result.Type != "query.result" {
		t.Fatal("documented temporary-table exception changed")
	}
	count := execute("SELECT count(*) FROM pg_temp.dbeer_semantic_temp")
	if count.Type != "query.result" || len(count.Rows) != 1 || count.Rows[0][0] == nil || *count.Rows[0][0] != "1" {
		t.Fatal("temporary-table exception was not reproduced")
	}
	var persistent int
	if err := h.observer.QueryRow(ctx, "SELECT count(*) FROM "+table).Scan(&persistent); err != nil || persistent != 0 {
		t.Fatal("hidden permanent write escaped server readonly")
	}
}
