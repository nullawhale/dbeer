package tableedit

import "testing"

func TestMariaDBAdvancedKindsRemainEngineScoped(t *testing.T) {
	for _, kind := range []string{"mariaDBPartitions", "mariaDBMyISAM", "mariaDBAria", "mariaDBSystemVersioned"} {
		nontransactional := kind == "mariaDBMyISAM" || kind == "mariaDBAria"
		support := NewAdvancedSupport([]string{kind}, "operation", 1, nontransactional, map[string]string{})
		storage := "InnoDB"
		if kind == "mariaDBMyISAM" {
			storage = "MyISAM"
		}
		if kind == "mariaDBAria" {
			storage = "Aria"
		}
		support.Relations = []AdvancedRelationFact{{Target: Target{Schema: "fixture", Table: "items"}, Kind: "table", Persistence: "permanent", StorageEngine: storage, Parents: []Target{}, Policies: []AdvancedPolicyFact{}}}
		if !support.Valid("mariadb") || support.Valid("mysql") || support.Valid("postgresql") {
			t.Fatal("native kinds crossed engine boundary")
		}
		support.Nontransactional = !nontransactional
		if support.Valid("mariadb") {
			t.Fatal("native transaction disclosure was lost")
		}
		support.Nontransactional = nontransactional
		support.Relations[0].RowSecurity = true
		if support.Valid("mariadb") {
			t.Fatal("PostgreSQL security model was aliased to MariaDB")
		}
	}
}
func TestMariaDBIndexFactsUseNativeMethodAndIgnoredVisibility(t *testing.T) {
	column := "amount"
	visible := false
	descending := true
	prefix := int64(12)
	target := Target{Schema: "fixture", Table: "items"}
	definition := IndexDefinition{Method: "btree", Terms: []IndexTerm{{Column: &column, PrefixLength: &prefix, Descending: &descending}}, Visible: &visible}
	facts := IndexFacts("mariadb", target, "ignored_amount", false, definition)
	observed, ok := ObservedIndexDefinition("mariadb", facts)
	if !ok || observed.Method != "btree" || observed.Visible == nil || *observed.Visible || len(observed.Terms) != 1 || observed.Terms[0].PrefixLength == nil || *observed.Terms[0].PrefixLength != 12 || observed.Terms[0].Descending == nil || !*observed.Terms[0].Descending {
		t.Fatal("native index facts lost order, prefix or ignored state")
	}
}

func TestMariaDBDecimalScaleAdmissionRetainsOtherEngineLimits(t *testing.T) {
	typ := DataType{Kind: "numeric", Precision: 65, Scale: 38}
	if !typ.Valid() || !typ.ValidForEngine("mariadb") || typ.ValidForEngine("mysql") || typ.ValidForEngine("postgresql") || typ.ValidForEngine("sqlite") {
		t.Fatal("engine-specific scale limit changed")
	}
	draft := Draft{Columns: []Column{{Name: "amount", Type: typ, Nullable: true, Default: Default{Kind: "none"}}}}
	if draft.ValidateForEngine("mariadb") != nil || draft.ValidateForEngine("mysql") == nil || draft.ValidateForEngine("postgresql") == nil {
		t.Fatal("draft bypassed engine-specific numeric admission")
	}
}

func TestMariaDBExpectedIntegerDisplayWidthsRemainNative(t *testing.T) {
	for _, tc := range []struct {
		kind  string
		width int64
	}{{"integer", 11}, {"bigint", 20}} {
		native := ExpectedNewType("mariadb", DataType{Kind: tc.kind})
		mysql := ExpectedNewType("mysql", DataType{Kind: tc.kind})
		if native.Modifiers.Value == nil || native.Modifiers.Value.Length == nil || *native.Modifiers.Value.Length != tc.width || mysql.Modifiers.Value == nil || mysql.Modifiers.Value.Length != nil {
			t.Fatal("native display widths were dropped or imposed on another engine")
		}
	}
	old := ExpectedNewType("mariadb", DataType{Kind: "integer"})
	old.Modifiers.Value.Unsigned = true
	target := DataType{Kind: "integer"}
	changed := ExpectedChangedType("mariadb", old, ColumnChange{Name: "id", Type: &target})
	if changed.Modifiers.Value.Length == nil || *changed.Modifiers.Value.Length != 10 || !changed.Modifiers.Value.Unsigned {
		t.Fatal("native unsigned integer width or signedness changed")
	}
}
