package cassandra_test

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"math"
	"strconv"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/cassandra"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/safety"
	"dbeer/helper/internal/session"
)

func TestCassandraLiveExpandedNativeLanguageFunctions(t *testing.T) {
	connection := liveConnection(t)
	s := liveOpen(t, connection)
	version := liveValue(t, liveSQL(t, s, "SELECT release_version AS version FROM system.local"), "version")
	if version == nil {
		t.Fatal("Cassandra did not report its version")
	}
	major, err := strconv.Atoi(strings.SplitN(*version, ".", 2)[0])
	if err != nil {
		t.Fatal("Cassandra reported an invalid version")
	}
	table := `"` + strings.ReplaceAll(connection.Database, `"`, `""`) + `".live_expanded_language`
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		_ = s.Execute(ctx, protocol.Command{Type: "execute", RequestID: "language-cleanup", SQL: "DROP TABLE IF EXISTS " + table})
	})
	liveSQL(t, s, "DROP TABLE IF EXISTS "+table)
	liveSQL(t, s, "CREATE TABLE "+table+" (pk int,ck int,position int,value text,numbers list<int>,mapping map<text,int>,pair frozen<tuple<int,text>>,PRIMARY KEY(pk,ck,position))")
	liveSQL(t, s, "INSERT INTO "+table+" (pk,ck,position,value,numbers,mapping,pair) VALUES (1,1,1,'abcdef',[2,4,6],{'a':1,'b':2},(7,'tuple'))")
	if major >= 5 {
		liveSQL(t, s, "ALTER TABLE "+table+" ADD embedding vector<float,3>")
		liveSQL(t, s, "UPDATE "+table+" SET embedding=[1,0,0] WHERE pk=1 AND ck=1 AND position=1")
	}

	connection.Policy = &protocol.ExecutionPolicy{Environment: "development", ReadOnly: true}
	manager := session.New(cassandra.Open)
	defer manager.Close()
	receive := func(t *testing.T) protocol.Response {
		t.Helper()
		select {
		case response := <-manager.Responses():
			return response
		case <-time.After(30 * time.Second):
			t.Fatal("readonly Cassandra language request timed out")
			return protocol.Response{}
		}
	}
	if !manager.Submit(protocol.Command{Type: "connect", RequestID: "language-connect", Connection: &connection}) {
		t.Fatal("Cassandra manager stopped")
	}
	connected := receive(t)
	if connected.Type != "connect.result" {
		t.Fatal("readonly Cassandra language connection failed")
	}
	read := func(t *testing.T, selectors string, suffix ...string) protocol.Response {
		t.Helper()
		statement := "SELECT " + selectors + " FROM " + table + " WHERE pk=1 AND (ck,position)=(1,1)"
		if len(suffix) > 0 {
			statement += " " + strings.Join(suffix, " ")
		}
		assessment := safety.Classify("cassandra", statement)
		if len(assessment) != 1 || assessment[0].Kind != safety.Read {
			t.Fatal("native language expression was not assessed as a read")
		}
		if !manager.Submit(protocol.Command{Type: "execute", RequestID: "language", SessionID: connected.SessionID, QueryID: "language", SQL: statement}) {
			t.Fatal("Cassandra manager stopped")
		}
		for {
			response := receive(t)
			if response.Type == "query.started" || response.Type == "query.progress" {
				continue
			}
			if response.Type != "query.result" || len(response.Rows) != 1 || response.OutcomeUnknown {
				t.Fatalf("readonly native language query failed: type=%s category=%s", response.Type, response.Category)
			}
			return response
		}
	}
	valueEquals := func(t *testing.T, response protocol.Response, name, want string) {
		t.Helper()
		if got := liveValue(t, response, name); got == nil || *got != want {
			t.Fatalf("native language result changed for %s", name)
		}
	}

	// Round trips verify both compact spellings exposed by completion, including
	// types whose binary representation cannot be safely invented by a cast.
	for _, check := range []struct{ typ, bytes string }{
		{"ascii", "61"}, {"bigint", "0000000000000001"}, {"boolean", "01"}, {"counter", "0000000000000001"},
		{"date", "80000000"}, {"decimal", "0000000001"}, {"double", "3ff0000000000000"}, {"duration", "020406"},
		{"float", "3f800000"}, {"inet", "7f000001"}, {"int", "00000001"}, {"smallint", "0001"},
		{"text", "61"}, {"time", "0000000000000001"}, {"timestamp", "0000000000000000"},
		{"timeuuid", "50554d6e29bb11e5b345feff819cdc9f"}, {"tinyint", "01"},
		{"uuid", "550e8400e29b41d4a716446655440000"}, {"varchar", "61"}, {"varint", "01"},
	} {
		t.Run("blob/"+check.typ, func(t *testing.T) {
			result := read(t, "system."+check.typ+"AsBlob(system.blobAs"+check.typ+"(0x"+check.bytes+")) AS encoded")
			bytes, err := hex.DecodeString(check.bytes)
			if err != nil {
				t.Fatal("invalid synthetic conversion fixture")
			}
			valueEquals(t, result, "encoded", base64.StdEncoding.EncodeToString(bytes))
			if len(result.Columns) != 1 || result.Columns[0].Encoding != "base64" {
				t.Fatal("native blob conversion lost binary metadata")
			}
		})
	}
	t.Run("date_aliases", func(t *testing.T) {
		if major >= 5 {
			t.Skip("deprecated dateOf and unixTimestampOf were removed in Cassandra 5")
		}
		result := read(t, "system.dateOf(50554d6e-29bb-11e5-b345-feff819cdc9f) AS date_alias,system.toTimestamp(50554d6e-29bb-11e5-b345-feff819cdc9f) AS timestamp_value,system.unixTimestampOf(50554d6e-29bb-11e5-b345-feff819cdc9f) AS unix_alias,system.toUnixTimestamp(50554d6e-29bb-11e5-b345-feff819cdc9f) AS unix_value")
		if date, timestamp := liveValue(t, result, "date_alias"), liveValue(t, result, "timestamp_value"); date == nil || timestamp == nil || *date != *timestamp {
			t.Fatal("dateOf alias changed native timestamp semantics")
		}
		if alias, value := liveValue(t, result, "unix_alias"), liveValue(t, result, "unix_value"); alias == nil || value == nil || *alias != *value {
			t.Fatal("unixTimestampOf alias changed native timestamp semantics")
		}
	})
	t.Run("collection_tuple_reads", func(t *testing.T) {
		result := read(t, "system.toJson(mapping) AS map_json,system.toJson(pair) AS pair_json")
		if liveValue(t, result, "map_json") == nil || liveValue(t, result, "pair_json") == nil {
			t.Fatal("readonly CQL lost collection or tuple function arguments")
		}
		valueEquals(t, read(t, "COUNT(1) AS total"), "total", "1")
	})

	t.Run("cassandra5", func(t *testing.T) {
		if major < 5 {
			t.Skip("Cassandra 5 native functions are unavailable on this server")
		}
		t.Run("snake_case_aliases", func(t *testing.T) {
			result := read(t, "system.blob_as_int(system.int_as_blob(7)) AS integer_value,system.to_date(system.current_timestamp()) AS date_value,system.to_timestamp(system.current_timeuuid()) AS timestamp_value,system.to_unix_timestamp(system.current_date()) AS unix_value,system.current_time() AS time_value,system.min_timeuuid(system.current_timestamp()) AS minimum_uuid,system.max_timeuuid(system.current_timestamp()) AS maximum_uuid,system.to_json(value) AS json_value", `AND value=system.from_json('"abcdef"') ALLOW FILTERING`)
			valueEquals(t, result, "integer_value", "7")
			valueEquals(t, result, "json_value", `"abcdef"`)
			for _, name := range []string{"date_value", "timestamp_value", "unix_value", "time_value", "minimum_uuid", "maximum_uuid"} {
				if liveValue(t, result, name) == nil {
					t.Fatalf("native snake_case alias returned NULL for %s", name)
				}
			}
		})
		t.Run("math", func(t *testing.T) {
			result := read(t, "system.abs((double)-2.5) AS absolute,system.exp((double)0) AS exponential,system.log((double)1) AS natural_log,system.log10((double)100) AS decimal_log,system.round((double)1.5) AS rounded")
			for name, want := range map[string]float64{"absolute": 2.5, "exponential": 1, "natural_log": 0, "decimal_log": 2, "rounded": 2} {
				value := liveValue(t, result, name)
				if value == nil {
					t.Fatal("math function returned NULL")
				}
				got, err := strconv.ParseFloat(*value, 64)
				if err != nil || math.IsNaN(got) || math.Abs(got-want) > 1e-9 {
					t.Fatalf("math function changed result for %s", name)
				}
			}
		})
		t.Run("collections", func(t *testing.T) {
			result := read(t, "system.collection_count(system.map_keys(mapping)) AS key_count,system.collection_sum(system.map_values(mapping)) AS value_sum,system.collection_count(numbers) AS item_count,system.collection_min(numbers) AS minimum,system.collection_max(numbers) AS maximum,system.collection_sum(numbers) AS total,system.collection_avg(numbers) AS average")
			for name, want := range map[string]string{"key_count": "2", "value_sum": "3", "item_count": "3", "minimum": "2", "maximum": "6", "total": "12", "average": "4"} {
				valueEquals(t, result, name, want)
			}
		})
		t.Run("masking", func(t *testing.T) {
			result := read(t, "system.mask_null(value) AS absent,system.mask_default(value) AS default_value,system.mask_replace(value,'replacement') AS replaced,system.mask_inner(value,1,1) AS inner_value,system.mask_outer(value,1,1) AS outer_value,system.mask_inner(value,1,1,'#') AS padded,system.mask_hash(value) AS hashed")
			if liveValue(t, result, "absent") != nil {
				t.Fatal("mask_null did not preserve NULL")
			}
			for name, want := range map[string]string{"default_value": "****", "replaced": "replacement", "inner_value": "a****f", "outer_value": "*bcde*", "padded": "a####f"} {
				valueEquals(t, result, name, want)
			}
			digest := sha256.Sum256([]byte("abcdef"))
			valueEquals(t, result, "hashed", base64.StdEncoding.EncodeToString(digest[:]))
		})
		t.Run("vectors", func(t *testing.T) {
			result := read(t, "system.similarity_cosine(embedding,[1,0,0]) AS cosine,system.similarity_dot_product(embedding,[1,0,0]) AS dot_product,system.similarity_euclidean(embedding,[1,0,0]) AS euclidean")
			for _, name := range []string{"cosine", "dot_product", "euclidean"} {
				valueEquals(t, result, name, "1")
			}
		})
		t.Run("selectors", func(t *testing.T) {
			result := read(t, "mapping['a'] AS entry,MAXWRITETIME(mapping) AS latest,WRITETIME(value) AS written,MAXWRITETIME(value) AS scalar_latest,TTL(mapping['a']) AS expiry")
			valueEquals(t, result, "entry", "1")
			if latest := liveValue(t, result, "latest"); latest == nil || *latest == "" {
				t.Fatal("MAXWRITETIME lost collection cell timestamps")
			}
			if written, latest := liveValue(t, result, "written"), liveValue(t, result, "scalar_latest"); written == nil || latest == nil || *written != *latest {
				t.Fatal("MAXWRITETIME changed scalar timestamp semantics")
			}
			if liveValue(t, result, "expiry") != nil {
				t.Fatal("collection element TTL invented an expiry")
			}
		})
	})
}
