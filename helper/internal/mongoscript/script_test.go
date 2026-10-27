package mongoscript

import (
	"strings"
	"testing"

	"go.mongodb.org/mongo-driver/v2/bson"
)

func TestParsePreservesOrderedSortAndBSONTypes(t *testing.T) {
	s, err := Parse(`{"database":"demo","collection":"orders","find":{"_id":{"$oid":"507f1f77bcf86cd799439011"},"n":{"$numberLong":"9007199254740993"},"price":{"$numberDecimal":"123456789.000000000001"}},"sort":{"z":-1,"a":1},"limit":200}`)
	if err != nil || s.Aggregate || s.Write || s.Limit != 200 || len(s.Sort) != 2 || s.Sort[0].Key != "z" {
		t.Fatal("valid find request lost ordering or options")
	}
	if _, ok := s.Filter[0].Value.(bson.ObjectID); !ok {
		t.Fatal("ObjectId type lost")
	}
	if n, ok := s.Filter[1].Value.(int64); !ok || n != 9007199254740993 {
		t.Fatal("int64 precision lost")
	}
	if _, ok := s.Filter[2].Value.(bson.Decimal128); !ok {
		t.Fatal("Decimal128 type lost")
	}
}

func TestReadAndOutputPipelines(t *testing.T) {
	if _, err := Parse(`{"collection":"items","find":{"pipeline":"daily"}}`); err != nil {
		t.Fatal("ordinary pipeline field was interpreted as an aggregation")
	}
	for _, test := range []struct {
		pipeline string
		write    bool
	}{
		{`[]`, false}, {`[{"$match":{"active":true}},{"$group":{"_id":"$region","n":{"$sum":1}}}]`, false},
		{`[{"$out":"archive"}]`, true}, {`[{"$merge":{"into":"archive","whenMatched":"replace"}}]`, true},
		{`[{"$lookup":{"from":"other","pipeline":[{"$match":{}}],"as":"items"}}]`, false},
	} {
		s, err := Parse(`{"collection":"items","aggregate":` + test.pipeline + `}`)
		if err != nil || s.Write != test.write || !s.Aggregate {
			t.Fatal("pipeline classification mismatch")
		}
	}
}

func TestBrowseValueRejectsDuplicateKeysAndRetainsExactIntegers(t *testing.T) {
	value, err := Value(`{"$numberLong":"9007199254740993"}`)
	if err != nil || value != int64(9007199254740993) {
		t.Fatal("browse value lost integer precision")
	}
	if _, err := Value(`{"a":1,"\u0061":2}`); err == nil {
		t.Fatal("duplicate browse keys accepted")
	}
}

func TestRejectsAmbiguousOrExecutableInput(t *testing.T) {
	for _, text := range []string{
		`db.orders.find({})`, `{"collection":"t","find":{}};`, `[]`, `null`, `{}`, `{"collection":"t","find":[],"aggregate":[]}`,
		`{"collection":"t","find":{},"find":{}}`, `{"collection":"t","find":{"x":1,"\u0078":2}}`,
		`{"collection":"t","find":{},"aggregate":[]}`, `{"collection":"t","find":{},"command":{"drop":"t"}}`,
		`{"collection":"t","find":{"$where":"return true"}}`, `{"collection":"t","find":{"x":{"$code":"return true"}}}`,
		`{"collection":"t","aggregate":[{"$project":{"n":{"$function":{"body":"return 1","args":[],"lang":"js"}}}}]}`,
		`{"collection":"t","aggregate":[{"$changeStream":{}}]}`, `{"collection":"t","aggregate":[{"$out":"x"},{"$match":{}}]}`,
		`{"collection":"t","aggregate":[{"$facet":{"x":[{"$out":"x"}]}}]}`,
		`{"collection":"t","aggregate":[{"$lookup":{"from":"u","pipeline":[{"$merge":"x"}],"as":"x"}}]}`,
		`{"collection":"t","aggregate":[{"$match":{},"$out":"x"}]}`, `{"collection":"t","find":{},"sort":{"x":2}}`,
		`{"collection":"t","find":{},"limit":0}`, `{"collection":"t","find":{},"limit":1.5}`, `{"collection":"t","aggregate":[],"sort":{}}`,
	} {
		if _, err := Parse(text); err == nil {
			t.Fatal("unsafe or ambiguous MongoDB input was accepted")
		}
	}
	if _, err := Parse(strings.Repeat(" ", (2<<20)+1)); err == nil {
		t.Fatal("oversized input accepted")
	}
}
