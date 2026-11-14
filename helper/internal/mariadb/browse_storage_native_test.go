package mariadb

import (
	"context"
	"fmt"
	"math"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

func TestMariaDBBrowseStorageCanonicalNativeValuesAndSelectSQLLive(t *testing.T) {
	s := dataIntegrationSession(t)
	settings := dataIntegrationSettings(t)
	name := fmt.Sprintf("g1_browse_storage_%d", time.Now().UnixNano())
	target := QuoteIdentifier(settings.Database) + "." + QuoteIdentifier(name)
	dataRun(t, s, "SET SESSION time_zone='+00:00'")
	dataRun(t, s, "CREATE TABLE "+target+"(id INT PRIMARY KEY,stamp TIMESTAMP(6) NULL,f FLOAT(8,4),e ENUM('','x'),choice SET('','a'),j JSON) ENGINE=InnoDB")
	t.Cleanup(func() { dataRun(t, s, "DROP TABLE IF EXISTS "+target) })
	dataRun(t, s, "INSERT INTO "+target+" VALUES(1,'2024-01-02 03:04:05.123456',0.1,'','a','{\"a\":1, \"a\":2}'),(2,NULL,NULL,'x','',NULL)")
	dataRun(t, s, "SET SESSION time_zone='+02:00'")
	before := dataRun(t, s, "SELECT @@sql_mode,@@time_zone")
	browse := func(kind string) protocol.Response {
		t.Helper()
		response := s.Execute(context.Background(), protocol.Command{Type: "catalog", ResultValues: protocol.NativeResultValuesFormat, Catalog: &protocol.CatalogRequest{Kind: kind, Schema: settings.Database, Object: name, ObjectKind: "table"}})
		if response.Type != "query.result" {
			t.Fatalf("native browse failed: %s/%s", response.Category, response.SQLState)
		}
		return response
	}
	first := browse("browse")
	if len(first.Rows) != 2 || len(first.Columns) != 6 || len(first.Rows[0]) != 6 || len(first.StorageTokens) != 2 || !strings.HasPrefix(first.StorageTokens[0], "mariadb.storage.v1:") || first.Rows[0][1] == nil || *first.Rows[0][1] != "2024-01-02 03:04:05.123456" || first.Rows[1][1] != nil || first.Rows[0][2] == nil || first.Rows[0][5] == nil || *first.Rows[0][5] != "{\"a\":1, \"a\":2}" {
		t.Fatal("native browse lost canonical time, JSON spelling, NULL, hidden fields or storage tokens")
	}
	promoted, err := strconv.ParseFloat(*first.Rows[0][2], 64)
	if err != nil || math.Float64bits(promoted) != math.Float64bits(float64(float32(0.1))) {
		t.Fatal("promoted native float was rounded through display scale")
	}
	if !reflect.DeepEqual(before.Rows, dataRun(t, s, "SELECT @@sql_mode,@@time_zone").Rows) {
		t.Fatal("browse implicitly changed session state")
	}
	selected := browse("select")
	if len(selected.Rows) != 1 || len(selected.Rows[0]) != 2 || selected.Rows[0][0] == nil || !strings.HasPrefix(*selected.Rows[0][0], "SELECT ") || strings.Contains(*selected.Rows[0][0], "__dbeer_storage_") || len(selected.StorageTokens) != 0 {
		t.Fatal("select did not return visible SQL without executing its row query")
	}
	dataRun(t, s, "SET SESSION time_zone='+05:00'")
	second := browse("browse")
	if !reflect.DeepEqual(first.Rows, second.Rows) || !reflect.DeepEqual(first.StorageTokens, second.StorageTokens) {
		t.Fatal("native canonical browse depends on current timezone")
	}
	dataRun(t, s, "UPDATE "+target+" SET choice=1 WHERE id=2")
	changed := browse("browse")
	if !reflect.DeepEqual(second.Rows, changed.Rows) || second.StorageTokens[1] == changed.StorageTokens[1] {
		t.Fatal("display-equivalent native SET storage mutation was not distinguished")
	}
}
