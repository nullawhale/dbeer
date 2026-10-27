package mysql

import (
	"context"
	"reflect"
	"strings"
	"testing"

	sc "dbeer/helper/internal/schemacompare"
)

func TestCatalogTypeLabelsPreserveEscapesOrderAndEmptyMembers(t *testing.T) {
	want := []string{"", "a,b", "owner's", "\\n", "line\nnext", "\x00", "\r", "я", "\t", "\x1a"}
	definition := "enum('','a,b','owner''s','\\\\n','line\\nnext','\\0','\\r','я','\t','\x1a')"
	if got, ok := mysqlTypeLabels(definition, "enum"); !ok || !reflect.DeepEqual(got, want) {
		t.Fatal("catalog labels lost bytes or order")
	}
	for _, bad := range []string{"enum()", "enum('a',)", "enum('a' 'b')", "enum('a\\q')", "enum('unterminated)", "enum(x'ff0')", "enum('a') unsigned"} {
		if _, ok := mysqlTypeLabels(bad, "enum"); ok {
			t.Fatal("malformed catalog labels accepted")
		}
	}
}

func TestMySQLTypeModifiersAreLosslessAndRenderable(t *testing.T) {
	for _, test := range []struct{ kind, definition, length, precision, scale, temporal, srid, sql string }{
		{"bit", "bit(64)", "", "64", "", "", "", "BIT(64)"},
		{"float", "float(11,5) unsigned zerofill", "", "12", "5", "", "", "FLOAT(11, 5) UNSIGNED ZEROFILL"},
		{"double", "double", "", "22", "", "", "", "DOUBLE"},
		{"tinyint", "tinyint(1)", "", "3", "0", "", "", "TINYINT(1)"},
		{"point", "point", "", "", "", "", "0", "POINT SRID 0"},
		{"point", "point", "", "", "", "", "4326", "POINT SRID 4326"},
		{"vector", "vector(16383)", "65532", "", "", "", "", "VECTOR(16383)"},
		{"datetime", "datetime(6)", "", "", "", "6", "", "DATETIME(6)"},
	} {
		t.Run(test.definition+test.srid, func(t *testing.T) {
			u := mysqlSchemaType(test.kind, test.definition, "", test.length, test.precision, test.scale, test.temporal, test.srid)
			r := myDefinition{w: &sc.DefinitionWriter{Context: context.Background()}}
			r.typ(u)
			d, err := r.w.Finish()
			if err != nil || d.Limited || d.SQL != test.sql {
				t.Fatalf("type modifier render changed: %q", d.SQL)
			}
		})
	}
}

func TestBinaryInlineLabelsDoNotBecomeReplacementCharacters(t *testing.T) {
	u := mysqlSchemaType("enum", "enum('\\0',x'ff',x'80')", "binary", "1", "", "", "", "")
	if u.LabelEncoding != "base64" || !u.Labels.Complete || !reflect.DeepEqual(u.Labels.Items, []string{"AA==", "/w==", "gA=="}) {
		t.Fatal("binary labels lost bytes")
	}
	r := myDefinition{w: &sc.DefinitionWriter{Context: context.Background()}}
	r.typ(u)
	d, err := r.w.Finish()
	if err != nil || d.Limited || d.SQL != "ENUM(X'00', X'ff', X'80')" {
		t.Fatal("binary label SQL changed bytes")
	}
	left, right := "\xff", "\xfe"
	if reflect.DeepEqual(mysqlRawRows([][]*string{{&left}}), mysqlRawRows([][]*string{{&right}})) {
		t.Fatal("catalog digest collapsed invalid UTF-8")
	}
	for _, mode := range []string{"", "NO_BACKSLASH_ESCAPES"} {
		u = mysqlSchemaType("enum", "enum('a\\\\b','owner''s')", "utf8mb4", "7", "", "", "", "")
		r = myDefinition{w: &sc.DefinitionWriter{Context: context.Background()}, engine: sc.Known([]sc.Option{{Name: "sqlMode", Value: mode}})}
		r.typ(u)
		d, err = r.w.Finish()
		if err != nil || d.Limited || strings.Contains(d.SQL, "unavailable") {
			t.Fatal("SQL mode blocked a known label")
		}
		if mode != "" && !strings.Contains(d.SQL, "'a\\b'") {
			t.Fatal("NO_BACKSLASH_ESCAPES rendering doubled a literal backslash")
		}
	}
}

func TestNoninjectiveChoiceDefinitionsRequireStorageEvidence(t *testing.T) {
	for _, test := range []struct {
		kind      string
		labels    []string
		ambiguous bool
	}{
		{"enum", []string{"a", "a"}, true}, {"enum", []string{"a", "b"}, false},
		{"set", []string{"a,b", "a", "b"}, true}, {"set", []string{"a", "a"}, true},
		{"set", []string{"", "a"}, true}, {"set", []string{"a", "b"}, false},
	} {
		if mysqlAmbiguousChoiceLabels(test.kind, test.labels) != test.ambiguous {
			t.Fatal("choice definition storage ambiguity was missed")
		}
	}
}
