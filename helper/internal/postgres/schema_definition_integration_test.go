package postgres

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	sc "dbeer/helper/internal/schemacompare"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func TestSchemaDefinitionFromRealCapture(t *testing.T) {
	dsn := os.Getenv("DBEER_TEST_DSN")
	if dsn == "" {
		t.Skip("disposable PostgreSQL fixture required")
	}
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal("fixture connection failed")
	}
	defer conn.Close(ctx)
	schema := "definition_" + time.Now().Format("150405000000")
	q := pgx.Identifier{schema}.Sanitize()
	if _, err = conn.Exec(ctx, "CREATE SCHEMA "+q); err != nil {
		t.Fatal("fixture schema creation failed")
	}
	defer conn.Exec(ctx, "DROP SCHEMA "+q+" CASCADE")
	fixture := "CREATE TABLE " + q + `.items (
		id bigint PRIMARY KEY,
		amount numeric(30,9) DEFAULT 1.002,
		title text DEFAULT 'original.schema',
		changed_at timestamp(3) with time zone,
		duration interval DAY TO SECOND(2),
		words varchar(12)[][],
		twice numeric GENERATED ALWAYS AS (amount * 2) STORED,
		CONSTRAINT positive CHECK (amount > 0),
		CONSTRAINT title_unique UNIQUE NULLS NOT DISTINCT (title)
	); CREATE INDEX title_idx ON ` + q + `.items(title DESC NULLS FIRST) INCLUDE(amount);
	COMMENT ON COLUMN ` + q + `.items.title IS 'preserved quote'' and newline';`
	if _, err = conn.Exec(ctx, fixture); err != nil {
		t.Fatal("definition fixture creation failed")
	}
	reader, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal("capture connection failed")
	}
	collector := sc.NewCollector(ctx, sc.DefaultLimits())
	err = (&Session{conn: reader}).ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{schema}, Limits: sc.DefaultLimits()}, collector)
	reader.Close(ctx)
	if err != nil {
		t.Fatalf("frozen capture failed (%T)", err)
	}
	if len(collector.Capture.Tables) != 1 {
		t.Fatal("fixture table capture unavailable")
	}
	ref := collector.Capture.Tables[0].Ref
	// Removing the live source proves the renderer needs only frozen facts. The
	// resulting definition is then accepted by PostgreSQL under the same names.
	if _, err = conn.Exec(ctx, "DROP TABLE "+q+".items"); err != nil {
		t.Fatal("fixture source removal failed")
	}
	definition, err := RenderSchemaDefinition(ctx, collector.Capture, ref)
	if err != nil {
		t.Fatalf("definition failed (%T)", err)
	}
	if definition.Limited {
		t.Fatal("ordinary supported capture produced a limited definition")
	}
	for _, expected := range []string{"numeric(30, 9)", "timestamp(3) with time zone", "interval DAY TO SECOND(2)", "character varying(12)[][]", "GENERATED ALWAYS AS", "NULLS NOT DISTINCT", "DESC NULLS FIRST", "INCLUDE (\"amount\")", "COMMENT ON COLUMN", "original.schema"} {
		if !strings.Contains(definition.SQL, expected) {
			t.Fatal("definition omitted a captured fixture property")
		}
	}
	if _, err = conn.Exec(ctx, definition.SQL); err != nil {
		if pgErr, ok := err.(*pgconn.PgError); ok {
			t.Fatalf("definition rejected by PostgreSQL (code=%s position=%d)", pgErr.Code, pgErr.Position)
		}
		t.Fatalf("definition acceptance failed (%T)", err)
	}
}
