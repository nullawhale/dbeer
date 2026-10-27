package tablecapture

import (
	sc "dbeer/helper/internal/schemacompare"
	"strings"
	"testing"
)

func TestPostgresTypeClosesRecursiveRangesAndAttributes(t *testing.T) {
	ref := sc.Ref{Kind: "type", Schema: "custom", Name: "node"}
	use := sc.TypeUse{Ref: ref, Kind: "c", Modifiers: sc.Known(sc.TypeModifiers{}), Labels: sc.Complete[string](nil)}
	array := sc.TypeUse{Ref: ref, Kind: "array", Element: &use, Modifiers: sc.Known(sc.TypeModifiers{ArrayDimensions: 1}), Labels: sc.Complete[string](nil)}
	def := sc.TypeDefinition{Ref: ref, Kind: sc.Known("c"), Attributes: sc.Complete([]sc.Column{{Type: sc.Known(array)}})}
	identity, e := PostgresType(use, []sc.TypeDefinition{def})
	if e != nil || !strings.Contains(identity, "node") {
		t.Fatal("recursive type graph did not close", e)
	}
	if _, e = PostgresType(use, nil); e != ErrUnsupported {
		t.Fatal("missing definition accepted")
	}
	def.Attributes.Complete = false
	if _, e = PostgresType(use, []sc.TypeDefinition{def}); e != ErrUnsupported {
		t.Fatal("incomplete attributes accepted")
	}
	rangeRef := sc.Ref{Kind: "type", Schema: "custom", Name: "span"}
	rangeUse := sc.TypeUse{Ref: rangeRef, Kind: "r", Modifiers: sc.Known(sc.TypeModifiers{})}
	def.Attributes.Complete = true
	rangeDef := sc.TypeDefinition{Ref: rangeRef, Kind: sc.Known("r"), Range: &sc.TypeRange{Subtype: use}}
	if _, e = PostgresType(rangeUse, []sc.TypeDefinition{rangeDef}); e != ErrUnsupported {
		t.Fatal("missing range subtype definition accepted")
	}
	if _, e = PostgresType(rangeUse, []sc.TypeDefinition{rangeDef, def}); e != nil {
		t.Fatal("complete range subtype rejected", e)
	}
}
