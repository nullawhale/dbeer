package queryparams

import (
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func binding(name, kind, value string) protocol.QueryParameter {
	return protocol.QueryParameter{Name: name, Type: kind, Value: &value}
}

func TestBindingRewritesOnlyPlaceholdersAndNeverValues(t *testing.T) {
	parameters := []protocol.QueryParameter{binding("id", "integer", "42"), binding("value", "text", "'; DELETE FROM secret; --"), binding("unused", "text", "")}
	for _, engine := range []string{"postgresql", "mysql"} {
		sql := "SELECT :id, :value, :id, ':missing', \"quoted:missing\" /* :missing */ -- :missing\n"
		if engine == "postgresql" {
			sql += ", $$:missing$$, $tag$:missing$tag$, :id::int8"
		} else {
			sql += ", `:missing`, @x := :id # :missing\n"
		}
		bound, err := Bind(engine, sql, parameters)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(bound.SQL, *parameters[1].Value) {
			t.Fatal("parameter value entered SQL text")
		}
		if engine == "postgresql" {
			if len(bound.Parameters) != 2 || !strings.HasPrefix(bound.SQL, "SELECT $1, $2, $1,") || !strings.HasSuffix(bound.SQL, "$1::int8") {
				t.Fatal("repeated PostgreSQL binding changed")
			}
		} else if len(bound.Parameters) != 4 || !strings.HasPrefix(bound.SQL, "SELECT ?, ?, ?,") || !strings.Contains(bound.SQL, "@x := ?") {
			t.Fatal("MySQL positional binding changed")
		}
	}
}

func TestBindingsRejectAmbiguityNativeParametersAndUnusedInvalidValues(t *testing.T) {
	p := []protocol.QueryParameter{binding("x", "text", "safe")}
	for _, test := range []struct{ engine, sql string }{
		{"postgresql", "SELECT :missing"}, {"mysql", "SELECT :missing"},
		{"postgresql", "SELECT $1"}, {"mysql", "SELECT ?"},
		{"postgresql", "SELECT ':hidden\\' , :x'"}, {"mysql", "SELECT ':hidden\\' , :x'"},
		{"mysql", "SELECT 1 /*! , :x */"}, {"postgresql", "SELECT :xé"},
	} {
		if _, err := Bind(test.engine, test.sql, p); err == nil {
			t.Fatalf("accepted invalid parameter syntax for %s", test.engine)
		}
	}
	for _, engine := range []string{"postgresql", "mysql", "cassandra", "mongodb"} {
		if _, err := Bind(engine, "SELECT 1", []protocol.QueryParameter{binding("x", "integer", "9223372036854775808")}); err == nil {
			t.Fatal("unused invalid definition accepted")
		}
	}
	for _, engine := range []string{"cassandra", "mongodb"} {
		if _, err := Bind(engine, "SELECT 1", p); err == nil {
			t.Fatal("unsupported engine accepted parameters")
		}
	}
	for _, engine := range []string{"postgresql", "mysql"} {
		bound, err := Bind(engine, "SELECT 1", p)
		if err != nil || bound.SQL != "SELECT 1" || len(bound.Parameters) != 0 {
			t.Fatal("unused valid definitions changed a selected statement")
		}
	}
}

func TestTypedMySQLParametersHaveLosslessDecimalAndTemporalCasts(t *testing.T) {
	bound, err := Bind("mysql", "SELECT :amount, :day, :at", []protocol.QueryParameter{binding("amount", "decimal", "-1234567890.123456789"), binding("day", "date", "2024-02-29"), binding("at", "timestamp", "2026-11-01 12:30:59.123456")})
	if err != nil || bound.SQL != "SELECT CAST(? AS DECIMAL(19,9)), CAST(? AS DATE), CAST(? AS DATETIME(6))" {
		t.Fatal("typed MySQL binding changed")
	}
	if _, err := Bind("mysql", "SELECT 1", []protocol.QueryParameter{binding("x", "decimal", "0."+strings.Repeat("1", 31))}); err == nil {
		t.Fatal("unrepresentable MySQL decimal accepted")
	}
}

func TestDialectQuoteAndCommentBoundaries(t *testing.T) {
	p := []protocol.QueryParameter{binding("x", "text", "a")}
	for _, sql := range []string{`SELECT E'escaped\' :hidden', :x`, "SELECT /* outer /* :hidden */ still :hidden */ :x", "SELECT foo$tag$, :x", "SELECT U&'\\0061 :hidden', :x"} {
		if bound, err := Bind("postgresql", sql, p); err != nil || len(bound.Parameters) != 1 {
			t.Fatal("PostgreSQL lexical boundary changed")
		}
	}
	// MySQL requires whitespace after -- to begin a comment.
	if _, err := Bind("mysql", "SELECT 1--:missing, :x", p); err == nil {
		t.Fatal("non-comment hid a missing MySQL parameter")
	}
}

func TestOrdinaryPostgresArraySlicesDoNotOptIntoNamedParameters(t *testing.T) {
	for _, sql := range []string{"SELECT values[lo:hi] FROM demo", "SELECT values[:upper_bound] FROM demo"} {
		for _, parameters := range [][]protocol.QueryParameter{nil, {}} {
			bound, err := Bind("postgresql", sql, parameters)
			if err != nil || bound.SQL != sql || len(bound.Parameters) != 0 {
				t.Fatal("ordinary array slice changed without parameter definitions")
			}
		}
	}
}

func TestRepeatedMySQLValuesCannotAmplifyTheDriverPacketWithoutBound(t *testing.T) {
	p := []protocol.QueryParameter{binding("x", "text", strings.Repeat("a", protocol.MaxQueryParameterBytes))}
	if _, err := Bind("mysql", "SELECT "+strings.Repeat(":x,", 9)+"1", p); err == nil {
		t.Fatal("repeated value amplification was unbounded")
	}
}
