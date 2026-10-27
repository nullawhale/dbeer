package mongodb

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"dbeer/helper/internal/mongoscript"
	"dbeer/helper/internal/protocol"
	"go.mongodb.org/mongo-driver/v2/bson"
)

func TestCanonicalExtendedJSONTypeFixture(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/mongodb-bson-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Document json.RawMessage `json:"document"`
	}
	if json.Unmarshal(data, &fixture) != nil {
		t.Fatal("invalid BSON fixture")
	}
	var raw bson.Raw
	if err = bson.UnmarshalExtJSON(fixture.Document, true, &raw); err != nil {
		t.Fatal("BSON fixture could not be decoded")
	}
	text, err := CanonicalDocument(raw)
	if err != nil {
		t.Fatal("BSON fixture could not be encoded")
	}
	var roundtrip bson.Raw
	if bson.UnmarshalExtJSON([]byte(text), true, &roundtrip) != nil || !bytes.Equal(raw, roundtrip) {
		t.Fatal("Canonical Extended JSON changed BSON types or bytes")
	}
	for _, tag := range []string{"$oid", "$numberInt", "$numberLong", "$numberDecimal", "$numberDouble", "$date", "$binary", "$timestamp", "$regularExpression", "$minKey", "$maxKey", "$undefined", "$symbol", "$code", "$scope", "$dbPointer"} {
		if !strings.Contains(text, `"`+tag+`"`) {
			t.Fatal("BSON type tag was discarded")
		}
	}
	if _, err := CanonicalDocument(bson.Raw{1, 2, 3}); err == nil {
		t.Fatal("invalid BSON accepted")
	}
}

func TestMongoClientOptionsDisableRetriesAndRequireVerifiedTLS(t *testing.T) {
	c := protocol.Connection{Engine: "mongodb", Host: "localhost", Port: 27017, SSLMode: "verify-full", MongoDB: &protocol.MongoDBSettings{ReplicaSet: "rs0"}}
	opts, err := clientOptions(c)
	if err != nil {
		t.Fatal(err)
	}
	if opts.RetryReads == nil || *opts.RetryReads || opts.RetryWrites == nil || *opts.RetryWrites || opts.TLSConfig == nil || opts.TLSConfig.InsecureSkipVerify || opts.ReplicaSet == nil || *opts.ReplicaSet != "rs0" {
		t.Fatal("MongoDB connection safety settings lost")
	}
	c.SSLMode = "require"
	if _, err := clientOptions(c); err == nil {
		t.Fatal("unverified TLS mode accepted")
	}
}

func TestMongoDBGeneratedFindUsesNativeCatalogContract(t *testing.T) {
	command := protocol.Command{Type: "catalog", Catalog: &protocol.CatalogRequest{Kind: "select", Schema: "demo", Object: "items", ObjectKind: "table"}}
	r := (&Session{}).Execute(context.Background(), command)
	if r.Type != "query.result" || len(r.Columns) != 1 || r.Columns[0].Name != "sql" || len(r.Rows) != 1 {
		t.Fatal("generated find does not match the native editor contract")
	}
	script, err := mongoscript.Parse(*r.Rows[0][0])
	if err != nil || script.Database != "demo" || script.Collection != "items" || script.Aggregate {
		t.Fatal("generated find cannot be executed as MongoDB JSON")
	}
}

func TestBrowseUsesTypedParametersAndDistinguishesNullFromMissing(t *testing.T) {
	value := `{"$numberLong":"9007199254740993"}`
	s, err := browseScript(protocol.CatalogRequest{Schema: "demo", Object: "items", Filters: []protocol.CatalogFilter{{Column: "nested.value", Operator: "eq", Value: &value}, {Column: "nullable", Operator: "isNull"}}})
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ := bson.MarshalExtJSON(s.Filter, true, false)
	if !strings.Contains(string(encoded), `"$numberLong":"9007199254740993"`) || !strings.Contains(string(encoded), `"$type"`) {
		t.Fatal("filter type or exact null semantics lost")
	}
	value = `".*secret"`
	s, err = browseScript(protocol.CatalogRequest{Schema: "demo", Object: "items", Filters: []protocol.CatalogFilter{{Column: "name", Operator: "contains", Value: &value}}})
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ = bson.MarshalExtJSON(s.Filter, true, false)
	if !strings.Contains(string(encoded), `\\.\\*secret`) {
		t.Fatal("contains interpreted a regular expression")
	}
	_, err = browseScript(protocol.CatalogRequest{Schema: "demo", Object: "items", Sort: []protocol.CatalogSort{{Column: "$where", Direction: "asc"}}})
	if err == nil {
		t.Fatal("operator accepted as a field")
	}
	r := safeError(protocol.Command{}, context.Background(), errDocumentLimit, false, nil)
	if r.OutcomeUnknown || r.Category != "result" {
		t.Fatal("display limit misreported as unknown write")
	}
}
