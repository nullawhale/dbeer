package sqlcomplete

import (
	"strings"
	"testing"
)

func TestCassandraNativeFunctionFamiliesHaveOfflineSignatures(t *testing.T) {
	for _, check := range []struct{ name, result string }{
		{"BLOBASDECIMAL", "decimal"}, {"DECIMALASBLOB", "blob"},
		{"BLOB_AS_TIMEUUID", "timeuuid"}, {"TIME_AS_BLOB", "blob"},
		{"MAXWRITETIME", "bigint"}, {"CAST", "target type"},
		{"ABS", "same as value"}, {"MAP_KEYS", "set<key type>"},
		{"MAP_VALUES", "list<value type>"}, {"COLLECTION_COUNT", "int"},
		{"COLLECTION_AVG", "element type"}, {"MASK_HASH", "blob"},
		{"MASK_REPLACE", "same as value"}, {"SIMILARITY_COSINE", "float"},
	} {
		prefix := "system."
		if cqlSpecialSelector(check.name) {
			prefix = ""
		}
		help := signatureAt(t, "SELECT "+prefix+check.name+"(|)", Context{Engine: "cassandra"})
		if help == nil || len(help.Signatures) == 0 || !strings.HasSuffix(help.Signatures[0].Label, " → "+check.result) {
			t.Errorf("missing native signature for %s", check.name)
		}
	}
	for _, name := range functions("cassandra") {
		if len(builtinSignatures(name, "cassandra")) == 0 {
			t.Errorf("completion has no offline signature: %s", name)
		}
	}
}

func TestCassandraNativeCompletionPreservesNamespaceAndDialect(t *testing.T) {
	for _, name := range []string{"BLOBASINT", "COLLECTION_COUNT", "MAP_KEYS", "MASK_HASH", "SIMILARITY_COSINE"} {
		items := suggestions(t, "SELECT "+name+"| FROM demo.events", Context{Engine: "cassandra"})
		found := false
		for _, item := range items {
			if item.Label == name {
				found = true
				if item.InsertText != "system."+name {
					t.Errorf("ambiguous insertion for %s: %s", name, item.InsertText)
				}
			}
		}
		if !found {
			t.Errorf("missing CQL native completion %s", name)
		}
		for _, engine := range []string{"postgresql", "mysql"} {
			if signatureAt(t, "SELECT "+name+"(|)", Context{Engine: engine}) != nil {
				t.Errorf("CQL function leaked into %s: %s", engine, name)
			}
		}
	}
}

func TestCassandraNativeOverloadsTrackMaskingArguments(t *testing.T) {
	help := signatureAt(t, "SELECT system.mask_inner('Alice', 1, 2, |)", Context{Engine: "cassandra"})
	if help == nil || len(help.Signatures) != 2 {
		t.Fatal("masking overloads unavailable")
	}
	active := help.Signatures[help.ActiveSignature]
	if active.ActiveParameter != 3 || len(active.Parameters) != 4 {
		t.Fatal("fourth masking argument did not select the padding overload")
	}
	span := active.Parameters[3]
	if active.Label[span.Start:span.End] != "padding: text" {
		t.Fatal("padding span does not identify the active argument")
	}
}

func TestCassandraRemovedDateAliasesAreNotSuggested(t *testing.T) {
	for _, name := range []string{"DATEOF", "UNIXTIMESTAMPOF"} {
		for _, item := range suggestions(t, "SELECT | FROM demo.events", Context{Engine: "cassandra"}) {
			if item.Label == name {
				t.Errorf("function removed in Cassandra 5 was suggested: %s", name)
			}
		}
		if signatureAt(t, "SELECT system."+name+"(|)", Context{Engine: "cassandra"}) == nil {
			t.Errorf("existing Cassandra 4.1 scripts lost legacy signature help: %s", name)
		}
	}
}
