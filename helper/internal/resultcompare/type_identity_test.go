package resultcompare

import "testing"

func TestStructuralTypeIdentityGatesValuesAndKeys(t *testing.T) {
	for _, mode := range []string{"key", "rowOrder"} {
		t.Run(mode, func(t *testing.T) {
			a, b := cols("mood"), cols("mood")
			a[0].TypeIdentity, b[0].TypeIdentity = "pgtype-v1:first", "pgtype-v1:changed-labels"
			result := compare(t, source(a, []*string{text("")}), source(b, []*string{text("")}), Options{Mode: mode, Columns: []Mapping{{Left: 0, Right: 0, Key: mode == "key"}}})
			summary := result.Summary()
			if summary.FullEquality || summary.EqualRows != 0 || summary.SchemaDifferenceCount == 0 {
				t.Fatal("equal display strings hid a structural type change")
			}
		})
	}
}

func TestUnresolvedTypeDefinitionCannotEstablishEquality(t *testing.T) {
	for _, mode := range []string{"key", "rowOrder"} {
		t.Run(mode, func(t *testing.T) {
			columns := cols("ENUM")
			columns[0].Engine, columns[0].TypeIdentity = "mysql", "unresolved:enum-label-definition"
			result := compare(t, source(columns, []*string{text("")}), source(columns, []*string{text("")}), Options{Mode: mode, Columns: []Mapping{{Left: 0, Right: 0, Key: mode == "key"}}})
			if result.Summary().FullEquality || result.Summary().UncertainRows == 0 {
				t.Fatal("matching unknown definitions established equality")
			}
		})
	}
}

func TestLegacyMissingDefinitionEvidenceCannotEstablishEquality(t *testing.T) {
	for _, item := range []struct{ engine, native string }{
		{"mysql", "ENUM"}, {"mysql", "SET"}, {"mysql", "VARCHAR"}, {"mysql", "DECIMAL"}, {"mysql", "GEOMETRY"},
		{"cassandra", "address"}, {"cassandra", "frozen<map<text,int>>"},
		{"postgresql", "numeric"}, {"postgresql", "varchar"}, {"postgresql", "_int4"},
		{"postgresql", "date"}, {"postgresql", "float4"}, {"postgresql", "float8"},
		{"postgresql", "point"}, {"postgresql", "money"},
	} {
		t.Run(item.engine+"/"+item.native, func(t *testing.T) {
			for _, mode := range []string{"key", "rowOrder"} {
				columns := []Column{{Index: 0, Name: "value", Engine: item.engine, NativeType: item.native}}
				result := compare(t, source(columns, []*string{text("same")}), source(columns, []*string{text("same")}), Options{Mode: mode, Columns: []Mapping{{Key: mode == "key"}}})
				if result.Summary().FullEquality || result.Summary().UncertainRows == 0 {
					t.Fatal("legacy display names established equality without type definitions")
				}
			}
		})
	}
}

func TestLegacyParameterlessBuiltinMatchesItsNewExplicitIdentity(t *testing.T) {
	left, right := cols("int8"), cols("int8")
	right[0].TypeIdentity = effectiveIdentity(left[0])
	result := compare(t, source(left, []*string{text("1")}), source(right, []*string{text("1")}), Options{Mode: "key", Columns: []Mapping{{Key: true}}})
	if !result.Summary().FullEquality {
		t.Fatal("complete legacy builtin identity was unnecessarily lost")
	}
}
