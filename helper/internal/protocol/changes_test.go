package protocol

import (
	"encoding/json"
	"testing"
)

func TestChangesTypedValidationAndStrictParsing(t *testing.T) {
	value := ""
	request := ChangesRequest{Schema: "db", Table: "t", Columns: []SnapshotColumn{{Name: "id", Engine: "mysql", NativeType: "int"}}, Changes: []RowChange{{Kind: "insert", Values: []ColumnAssignment{{Column: "id", Value: CellValue{Kind: "text", Value: &value}}}}}}
	encoded, _ := json.Marshal(request)
	if _, ok := parseChanges(encoded); !ok {
		t.Fatal("valid empty text rejected")
	}
	for _, bad := range []string{
		`{"schema":"db","table":"t","columns":[{"name":"id","engine":"mysql","nativeType":"int"}],"changes":[{"kind":"update","original":[],"values":[]}]}`,
		`{"schema":"db","table":"t","columns":[{"name":"id","engine":"mysql","nativeType":"int"}],"changes":[{"kind":"insert","values":[{"column":"id","value":{"kind":"binary","value":"!!!"}}]}]}`,
		`{"schema":"db","table":"t","extra":1,"columns":[],"changes":[]}`,
		`{"schema":"db","schema":"other","table":"t","columns":[],"changes":[]}`,
		`{"SCHEMA":"db","table":"t","columns":[{"name":"id","engine":"mysql","nativeType":"int"}],"changes":[{"kind":"insert"}]}`,
		`{"schema":"db","table":"t","columns":[{"Name":"id","engine":"mysql","nativeType":"int"}],"changes":[{"kind":"insert"}]}`,
	} {
		if _, ok := parseChanges([]byte(bad)); ok {
			t.Fatal("invalid changes accepted")
		}
	}
	if (CellValue{Kind: "default"}).Valid(false) || (CellValue{Kind: "null", Value: &value}).Valid(true) {
		t.Fatal("invalid snapshot/default semantics accepted")
	}
}
