package dbtools

import (
	"bytes"
	"context"
	"strings"
	"testing"
)

func TestDatabaseToolsSQLRestrictionPreservesCopyAndQuotedBodies(t *testing.T) {
	sql := `-- PostgreSQL database dump
\restrict PublicDumpKey
SET standard_conforming_strings=on;
CREATE FUNCTION fixture() RETURNS text LANGUAGE sql AS $body$
SELECT '\! this is a SQL string';
$body$;
COPY fixture (id,value) FROM stdin;
1	\restrict this is COPY data
2	\! this is COPY data
\.
\unrestrict PublicDumpKey
`
	var out bytes.Buffer
	if err := sanitizePostgresDump(context.Background(), strings.NewReader(sql), &out); err != nil {
		t.Fatal("a standard dump with COPY and quoted bodies was rejected")
	}
	if strings.Contains(out.String(), "\\restrict PublicDumpKey") || strings.Contains(out.String(), "\\unrestrict PublicDumpKey") || !strings.Contains(out.String(), "1\t\\restrict this is COPY data") || !strings.Contains(out.String(), "SELECT '\\! this is a SQL string';") {
		t.Fatal("restriction wrappers or SQL/COPY bytes were not handled exactly")
	}
	for _, bad := range []string{"\\! touch /synthetic/file\n", "SELECT 1 \\gexec\n", "\\copy fixture FROM '/synthetic/private'\n", "\\i /synthetic/private\n", "COPY fixture FROM stdin;\n1\n", "SELECT 'unterminated", "/* unterminated"} {
		out.Reset()
		if sanitizePostgresDump(context.Background(), strings.NewReader(bad), &out) == nil {
			t.Fatal("unsafe or incomplete plain SQL was accepted")
		}
	}
}
func TestDatabaseToolsSQLStreamingDoesNotRequireBoundedLineLength(t *testing.T) {
	value := strings.Repeat("a", 4*1024*1024)
	sql := "CREATE TABLE fixture(value text);\nCOPY fixture FROM stdin;\n" + value + "\n\\.\n"
	var out bytes.Buffer
	if sanitizePostgresDump(context.Background(), strings.NewReader(sql), &out) != nil || out.String() != sql+"\n" {
		t.Fatal("long COPY rows changed during bounded streaming")
	}
	sql = "SELECT '" + value + "';\n"
	out.Reset()
	if sanitizePostgresDump(context.Background(), strings.NewReader(sql), &out) != nil || out.String() != sql+"\n" {
		t.Fatal("long SQL values changed during bounded streaming")
	}
}
func TestDatabaseToolsSQLCancellationAndNestedComments(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if sanitizePostgresDump(ctx, strings.NewReader("SELECT 1;"), &bytes.Buffer{}) == nil {
		t.Fatal("cancelled SQL preparation proceeded")
	}
	sql := "/* outer /* nested \\! harmless */ still comment */\n" + `SELECT E'escaped\'quote', 'doubled''quote', $tag$\! literal$tag$;` + "\n"
	var out bytes.Buffer
	if sanitizePostgresDump(context.Background(), strings.NewReader(sql), &out) != nil || out.String() != sql+"\n" {
		t.Fatal("SQL lexical contexts were not preserved")
	}
}
