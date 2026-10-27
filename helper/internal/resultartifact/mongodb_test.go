package resultartifact

import (
	"encoding/json"
	"testing"
)

func TestMongoDBSnapshotAcceptsBSONIdentity(t *testing.T) {
	column := Column{Index: 0, Name: "document", Engine: "mongodb", NativeType: "BSON document", TypeIdentity: "mongodb:bson:canonicalExtendedJSON:v1"}
	encoded, _ := json.Marshal(column)
	decoded, err := decodeColumn(encoded, 0)
	if err != nil || decoded != column || !validEngine("mongodb") {
		t.Fatal("MongoDB snapshot type identity was rejected or lost")
	}
}
