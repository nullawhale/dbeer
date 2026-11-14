package mariadb

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/tableedit"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

type mariaDBCatalogRows struct {
	rows    [][]*string
	columns []protocol.Column
}

func (s *mariaDBCatalogRows) Begin(_ int, columns []protocol.Column) error {
	s.columns = append([]protocol.Column{}, columns...)
	return nil
}
func (s *mariaDBCatalogRows) Row(_ int, row []*string) error {
	copy := make([]*string, len(row))
	for i, v := range row {
		if v != nil {
			value := strings.Clone(*v)
			copy[i] = &value
		}
	}
	s.rows = append(s.rows, copy)
	return nil
}
func (s *mariaDBCatalogRows) End(_ int, _ protocol.ResultSet) error { return nil }

func TestMariaDBCompletionNativeOrderedMetadataAndNoRoutineEvaluationLive(t *testing.T) {
	s := dataIntegrationSession(t)
	settings := dataIntegrationSettings(t)
	prefix := fmt.Sprintf("g1_completion_%d", time.Now().UnixNano())
	parent, child, function, marker := prefix+"_parent", prefix+"_child", prefix+"_function", prefix+"_marker"
	q := QuoteIdentifier
	for _, sql := range []string{
		"CREATE TABLE " + q(parent) + "(zeta INT,alpha INT,amount DECIMAL(65,38),payload VARCHAR(40) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin,PRIMARY KEY(zeta,alpha)) ENGINE=InnoDB",
		"CREATE TABLE " + q(child) + "(first_value INT,second_value INT,CONSTRAINT " + q(prefix+"_fk") + " FOREIGN KEY(first_value,second_value) REFERENCES " + q(parent) + "(zeta,alpha)) ENGINE=InnoDB",
		"CREATE TABLE " + q(marker) + "(hits INT NOT NULL) ENGINE=InnoDB",
		"INSERT INTO " + q(marker) + " VALUES(0)",
		"CREATE FUNCTION " + q(function) + "(second_argument INT,first_argument DECIMAL(65,38)) RETURNS DECIMAL(65,38) MODIFIES SQL DATA BEGIN UPDATE " + q(marker) + " SET hits=hits+1; RETURN first_argument; END",
	} {
		dataRun(t, s, sql)
	}
	t.Cleanup(func() {
		for _, sql := range []string{"DROP FUNCTION IF EXISTS " + q(function), "DROP TABLE IF EXISTS " + q(child), "DROP TABLE IF EXISTS " + q(parent), "DROP TABLE IF EXISTS " + q(marker)} {
			dataRun(t, s, sql)
		}
	})
	response := s.Execute(context.Background(), protocol.Command{Type: "catalog", Catalog: &protocol.CatalogRequest{Kind: "completion", Schema: settings.Database}})
	if response.Type != "query.result" || response.DisplayNotice != "" {
		t.Fatalf("native completion unavailable: %s/%s", response.Category, response.SQLState)
	}
	byName := map[string][]*string{}
	for _, row := range response.Rows {
		if len(row) == 8 && row[0] != nil {
			byName[*row[0]] = row
		}
	}
	row := byName[parent]
	if len(row) != 8 || row[3] == nil || row[7] == nil {
		t.Fatal("complete native table metadata missing")
	}
	var columns []string
	var entries []protocol.CatalogColumnTypeEntry
	if json.Unmarshal([]byte(*row[3]), &columns) != nil || json.Unmarshal([]byte(*row[7]), &entries) != nil || len(columns) != 4 || columns[0] != "zeta" || columns[1] != "alpha" || len(entries) != 4 || entries[2].NativeType != "decimal(65,38)" || entries[3].Comparison == nil || entries[3].Comparison.CollationName != "utf8mb4_bin" || entries[3].Comparison.CollationIdentity == "" {
		t.Fatal("native ordered column/type/collation metadata changed")
	}
	row = byName[child]
	var foreign []struct {
		Name, TargetSchema, TargetTable string
		Columns                         []struct{ Source, Target string }
	}
	if len(row) != 8 || row[4] == nil || json.Unmarshal([]byte(*row[4]), &foreign) != nil || len(foreign) != 1 || foreign[0].TargetSchema != settings.Database || foreign[0].TargetTable != parent || len(foreign[0].Columns) != 2 || foreign[0].Columns[0].Source != "first_value" || foreign[0].Columns[0].Target != "zeta" || foreign[0].Columns[1].Target != "alpha" {
		t.Fatal("native nested foreign-key JSON lost ordering or identity")
	}
	row = byName[function]
	var signatures []struct {
		ReturnType string
		Parameters []struct {
			Name, Type string
			Position   int
		}
	}
	if len(row) != 8 || row[5] == nil || json.Unmarshal([]byte(*row[5]), &signatures) != nil || len(signatures) != 1 || signatures[0].ReturnType != "decimal(65,38)" || len(signatures[0].Parameters) != 2 || signatures[0].Parameters[0].Name != "second_argument" || signatures[0].Parameters[1].Name != "first_argument" || signatures[0].Parameters[1].Position != 2 {
		t.Fatal("native function signature changed or nested JSON was quoted")
	}
	seen := dataRun(t, s, "SELECT hits FROM "+q(marker))
	if len(seen.Rows) != 1 || seen.Rows[0][0] == nil || *seen.Rows[0][0] != "0" {
		t.Fatal("catalog completion evaluated an authored routine")
	}
	metadata := &mariaDBCatalogRows{}
	observed, consistency := s.ReadCatalogMetadata(context.Background(), protocol.Command{Type: "catalog", Catalog: &protocol.CatalogRequest{Kind: "columns", Schema: settings.Database, Object: parent}}, metadata)
	if observed.Type != "query.result" || observed.MetadataStale || observed.DisplayNotice != "" || consistency != "bestEffort" || len(metadata.rows) != 4 || len(metadata.columns) != 9 {
		t.Fatal("native full metadata stream or conservative consistency changed")
	}
	incoming := &mariaDBCatalogRows{}
	observed, consistency = s.ReadCatalogMetadata(context.Background(), protocol.Command{Type: "catalog", Catalog: &protocol.CatalogRequest{Kind: "referencingTables", Schema: settings.Database, Object: parent}}, incoming)
	if observed.Type != "query.result" || consistency != "bestEffort" || observed.MetadataTarget == nil || observed.MetadataTarget.Schema != settings.Database || observed.MetadataTarget.Name != parent || len(incoming.rows) != 1 || incoming.rows[0][1] == nil || *incoming.rows[0][1] != child {
		t.Fatal("native incoming target or owner stream changed")
	}
}

func TestMariaDBStructureContextNativeIdentityAndStateDriftLive(t *testing.T) {
	s := dataIntegrationSession(t)
	settings := dataIntegrationSettings(t)
	dataRun(t, s, "SET SESSION time_zone='+00:00'")
	observe := func() mariaDBStructureContext {
		t.Helper()
		var observed mariaDBStructureContext
		response := s.executeWith(context.Background(), protocol.Command{}, func(_ *collector, _ *wire.Result) error {
			var err error
			observed, err = s.mariaDBStructureContext(tableedit.Target{Schema: settings.Database, Table: "future_items", Create: true})
			return err
		})
		if response.Type == "error" {
			t.Fatalf("native structure context unavailable: %s/%s", response.Category, response.SQLState)
		}
		return observed
	}
	before := observe()
	if len(before.Native) != 23 || before.ServerVersion < 101109 || before.SchemaCharset == "" || before.SchemaCollation == "" || before.Native[12] != "+00:00" {
		t.Fatal("native context lost complete identity, encoding or schema defaults")
	}
	dataRun(t, s, "SET SESSION time_zone='+03:30'")
	after := observe()
	if tableedit.Fingerprint(before.Native) == tableedit.Fingerprint(after.Native) || after.Native[12] != "+03:30" {
		t.Fatal("native context did not bind changed session state")
	}
	for i := range before.Native {
		if i != 12 && before.Native[i] != after.Native[i] {
			t.Fatal("fixed metadata observation changed another session property")
		}
	}
	dataRun(t, s, "SET SESSION time_zone='+00:00'")
	final := observe()
	if tableedit.Fingerprint(before.Native) != tableedit.Fingerprint(final.Native) {
		t.Fatal("explicitly restored native context changed metadata identity")
	}
}
