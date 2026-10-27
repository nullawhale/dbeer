package mysql

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	wire "github.com/go-mysql-org/go-mysql/mysql"
	"reflect"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	tc "dbeer/helper/internal/tablecapture"
)

func TestMySQLTypeCatalogDefinitionRoundTrip(t *testing.T) {
	s := integrationSession(t)
	reader := integrationSession(t)
	database := integrationSettings(t).Database
	for _, mode := range []string{"STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION", "STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION,NO_BACKSLASH_ESCAPES"} {
		t.Run(mode, func(t *testing.T) {
			for _, session := range []*Session{s, reader} {
				run(t, session, "SET SESSION sql_mode='"+mode+"'")
			}
			name := fmt.Sprintf("dbeer_type_matrix_%x", s.connectionID)
			clone := name + "_copy"
			for _, table := range []string{name, clone} {
				run(t, s, "DROP TABLE IF EXISTS "+QuoteIdentifier(table))
				defer run(t, s, "DROP TABLE IF EXISTS "+QuoteIdentifier(table))
			}
			labels := []string{"", "a,b", "owner's", "back\\slash", "new\nline", "\x00", "я"}
			renderLabels := func(labels []string) string {
				r := myDefinition{w: &sc.DefinitionWriter{Context: context.Background()}, engine: sc.Known([]sc.Option{{Name: "sqlMode", Value: mode}})}
				r.typ(sc.TypeUse{Ref: sc.Ref{Name: "enum"}, Modifiers: sc.Known(sc.TypeModifiers{}), Labels: sc.Complete(labels)})
				d, _ := r.w.Finish()
				return d.SQL
			}
			columns := []string{"id INT PRIMARY KEY", "signed_value BIGINT", "unsigned_value BIGINT UNSIGNED", "exact_value DECIMAL(65,30) DEFAULT 9007199254740993.123456789012345678901234567890", "approximate FLOAT(11,5) UNSIGNED", "approximate_double DOUBLE(20,9)", "padded INT(8) ZEROFILL", "flag TINYINT(1)", "bits BIT(64) DEFAULT b'101'", "fixed BINARY(4) DEFAULT X'00ff8001'", "variable VARBINARY(4) DEFAULT X'00ff8001'", "words VARCHAR(20) CHARACTER SET latin1 COLLATE latin1_bin", "document JSON", "choice " + renderLabels(labels) + " CHARACTER SET utf8mb4 COLLATE utf8mb4_bin", "choices SET('a','owner''s','') CHARACTER SET utf8mb4", "binary_choice ENUM(X'00',X'ff',X'80') CHARACTER SET binary DEFAULT X'ff'", "day DATE", "moment DATETIME(6)", "instant TIMESTAMP(6) NULL DEFAULT NULL", "duration TIME(6)", "yr YEAR", "g GEOMETRY", "p POINT NOT NULL SRID 0", "geographic POINT SRID 4326", "line LINESTRING", "area POLYGON", "mp MULTIPOINT", "ml MULTILINESTRING", "ma MULTIPOLYGON", "collection GEOMETRYCOLLECTION", "SPATIAL INDEX p_spatial(p)"}
			run(t, s, "CREATE TABLE "+QuoteIdentifier(name)+" ("+strings.Join(columns, ",")+") ENGINE=InnoDB")
			capture := func() sc.Capture {
				c := sc.NewCollector(context.Background(), sc.DefaultLimits())
				if err := reader.ReadSchema(context.Background(), sc.CaptureSpec{Schemas: []string{database}, Limits: sc.DefaultLimits()}, c); err != nil {
					t.Fatalf("type matrix capture failed: %T", err)
				}
				return c.Capture
			}
			selectTable := func(c sc.Capture, name string) sc.Table {
				for _, table := range c.Tables {
					if table.Ref.Name == name {
						return table
					}
				}
				t.Fatal("type matrix table missing")
				return sc.Table{}
			}
			before := capture()
			table := selectTable(before, name)
			for _, column := range table.Columns.Items {
				if column.Type.Value == nil || column.Type.Value.Modifiers.Value == nil || !column.Type.Value.Labels.Complete {
					definition := run(t, s, "SELECT COLUMN_TYPE,CHARACTER_SET_NAME,COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_NAME='"+name+"' AND COLUMN_NAME='binary_choice'")
					t.Fatalf("supported type became incomplete: column=%s type=%v definition=%q charset=%v collation=%v", column.Ref.Name, column.Type.Value, *definition.Rows[0][0], definition.Rows[0][1], definition.Rows[0][2])
				}
				if column.Ref.Name == "choice" && !reflect.DeepEqual(column.Type.Value.Labels.Items, labels) {
					t.Fatal("ENUM labels changed bytes")
				}
				if column.Ref.Name == "binary_choice" && (column.Type.Value.LabelEncoding != "base64" || !reflect.DeepEqual(column.Type.Value.Labels.Items, []string{"AA==", "/w==", "gA=="})) {
					t.Fatal("binary ENUM labels changed bytes")
				}
				if column.Ref.Name == "fixed" || column.Ref.Name == "variable" {
					if column.Default.Value == nil || column.Default.Value.Encoding != "base64" || column.Default.Value.Value == nil || *column.Default.Value.Value != "AP+AAQ==" {
						t.Fatal("binary default truncated at NUL")
					}
				}
			}
			copy := table
			copy.Ref.Name = clone
			before.Tables = []sc.Table{copy}
			definition, err := RenderSchemaDefinition(context.Background(), before, copy.Ref)
			if err != nil || definition.Limited {
				notes := []string{}
				for _, line := range strings.Split(definition.SQL, "\n") {
					if strings.HasPrefix(line, "--") {
						notes = append(notes, line)
					}
				}
				t.Fatalf("supported type matrix definition was incomplete: notes=%v", notes)
			}
			created, createErr := s.work.client.Execute(definition.SQL)
			if created != nil {
				created.Close()
			}
			if createErr != nil {
				var server *wire.MyError
				if errors.As(createErr, &server) {
					t.Fatalf("rendered type matrix SQL rejected: code=%d", server.Code)
				}
				t.Fatalf("rendered type matrix SQL rejected: %T", createErr)
			}
			after := selectTable(capture(), clone)
			if len(table.Columns.Items) != len(after.Columns.Items) {
				t.Fatal("type matrix column count changed")
			}
			for i, column := range table.Columns.Items {
				recreated := after.Columns.Items[i]
				column.Ref.Table = clone
				if !reflect.DeepEqual(column, recreated) {
					t.Fatalf("type matrix round trip changed column %s", column.Ref.Name)
				}
			}
		})
	}
}

func TestMySQLAllNativeValueFamiliesCaptureAndApply(t *testing.T) {
	s, writer, reader := integrationSession(t), integrationSession(t), integrationSession(t)
	name := fmt.Sprintf("dbeer_value_matrix_%x", s.connectionID)
	quoted := QuoteIdentifier(name)
	run(t, s, "CREATE TABLE "+quoted+"(id BIGINT UNSIGNED PRIMARY KEY, f FLOAT, d DOUBLE, flags BIT(64), doc JSON, e ENUM('','a','b'), choices SET('a','b'), p POINT SRID 4326, g GEOMETRY, moment DATETIME(6), duration TIME(6), bytes VARBINARY(8), fixed_text CHAR(8)) ENGINE=InnoDB")
	defer run(t, s, "DROP TABLE IF EXISTS "+quoted)
	run(t, s, "INSERT INTO "+quoted+" VALUES(18446744073709551615,0.1,1.2345678901234567,b'101',JSON_OBJECT('n',18446744073709551615),'a','a,b',ST_GeomFromText('POINT(45 90)',4326),ST_GeomFromText('GEOMETRYCOLLECTION(POINT(1 2),LINESTRING(0 0,3 4))'),'2020-01-02 03:04:05.123456','-838:59:58.999999',X'00ff80','padded')")
	if version := run(t, reader, "SELECT VERSION()"); strings.HasPrefix(*version.Rows[0][0], "8.0.") {
		run(t, reader, "SET SESSION sql_mode=CONCAT_WS(',',@@SESSION.sql_mode,'PAD_CHAR_TO_FULL_LENGTH')")
	}
	if err := reader.SetReadOnly(context.Background(), true); err != nil {
		t.Fatal("read-only setup failed")
	}
	table := tc.Table{Schema: integrationSettings(t).Database, Name: name}
	d, err := reader.DescribeTable(context.Background(), table)
	if err != nil {
		t.Fatalf("all native families describe failed: %T", err)
	}
	columns := []string{}
	for _, column := range d.Columns {
		columns = append(columns, column.Name)
	}
	sink := &dataCaptureTestSink{}
	_, _, err = reader.CaptureTable(context.Background(), tc.Spec{Table: table, DescriptorDigest: d.Digest, Columns: columns, Keys: []string{"id"}, ReadLimit: 10}, sink)
	if err != nil || len(sink.rows) != 1 {
		t.Fatalf("all native families capture failed: %T", err)
	}
	row := sink.rows[0]
	if *row[0] != "18446744073709551615" || *row[3] != "AAAAAAAAAAU=" || *row[10] != "-838:59:58.999999" || *row[11] != "AP+A" || *row[12] != "padded" {
		t.Fatal("native values lost precision or binary bytes")
	}
	point, err := base64.StdEncoding.DecodeString(*row[7])
	if err != nil || len(point) != 25 || point[0] != 0xe6 || point[1] != 0x10 {
		t.Fatal("geometry SRID or WKB lost")
	}
	request := editingRequest(t, s, name)
	request.Changes = []protocol.RowChange{{Kind: "update", Original: originalRow(t, s, name, "id=18446744073709551615"), Values: []protocol.ColumnAssignment{assign("f", typedText("0.2")), assign("d", typedText("1.2345678901234565")), assign("flags", typedBinary("AAAAAAAAAAc=")), assign("doc", typedText("{\"updated\": true}")), assign("e", typedText("b")), assign("choices", typedText("b")), assign("p", typedBinary(*row[7])), assign("g", typedBinary(*row[8]))}}}
	if response := executeChanges(writer, request, true); response.Type != "query.result" {
		t.Fatal("native family preview failed")
	}
	if response := executeChanges(writer, request, false); response.Type != "query.result" {
		t.Fatalf("native family apply failed: category=%s state=%s", response.Category, response.SQLState)
	}
	got := run(t, s, "SELECT flags,e,choices,JSON_EXTRACT(doc,'$.updated') FROM "+quoted).Rows[0]
	if *got[0] != "AAAAAAAAAAc=" || *got[1] != "b" || *got[2] != "b" || *got[3] != "true" {
		t.Fatal("native family apply changed values")
	}
}

func TestMySQLEnumCaptureDistinguishesErrorZeroFromDeclaredEmpty(t *testing.T) {
	s, reader, writer := integrationSession(t), integrationSession(t), integrationSession(t)
	name := fmt.Sprintf("dbeer_enum_indices_%x", s.connectionID)
	quoted := QuoteIdentifier(name)
	run(t, s, "CREATE TABLE "+quoted+"(id INT PRIMARY KEY,e ENUM('','a'),note TEXT) ENGINE=InnoDB")
	defer run(t, s, "DROP TABLE IF EXISTS "+quoted)
	run(t, s, "SET SESSION sql_mode=''")
	run(t, s, "INSERT INTO "+quoted+" VALUES(1,0,'first'),(2,1,'second'),(3,NULL,'third')")
	if err := reader.SetReadOnly(context.Background(), true); err != nil {
		t.Fatal("read-only setup failed")
	}
	table := tc.Table{Schema: integrationSettings(t).Database, Name: name}
	d, err := reader.DescribeTable(context.Background(), table)
	if err != nil {
		t.Fatal("ENUM descriptor failed")
	}
	sink := &dataCaptureTestSink{}
	_, out, err := reader.CaptureTable(context.Background(), tc.Spec{Table: table, DescriptorDigest: d.Digest, Columns: []string{"id", "e"}, Keys: []string{"id"}, ReadLimit: 10}, sink)
	if err != nil || len(sink.rows) != 3 || out.Rendering != "mysqlTextUTCUTF8v3" {
		t.Fatal("ENUM exact capture failed")
	}
	if *sink.rows[0][1] != `[0, ""]` || *sink.rows[1][1] != `[1, ""]` || sink.rows[2][1] != nil {
		t.Fatal("ENUM empty, error and SQL NULL collapsed")
	}
	request := editingRequest(t, s, name)
	request.Changes = []protocol.RowChange{{Kind: "update", Original: originalRow(t, s, name, "id=2"), Values: []protocol.ColumnAssignment{assign("note", typedText("changed"))}}}
	run(t, s, "UPDATE "+quoted+" SET e=0 WHERE id=2")
	if response := executeChanges(writer, request, false); response.Category != "conflict" {
		t.Fatal("ambiguous empty ENUM original overwrote another member")
	}
}

func TestMySQLChangesRejectLossyWarningsAndImplicitTimestampNull(t *testing.T) {
	s, writer := integrationSession(t), integrationSession(t)
	name := fmt.Sprintf("dbeer_lossless_changes_%x", s.connectionID)
	quoted := QuoteIdentifier(name)
	run(t, s, "CREATE TABLE "+quoted+"(id INT PRIMARY KEY,n DECIMAL(4,2),instant TIMESTAMP NOT NULL DEFAULT '2020-01-02 03:04:05') ENGINE=InnoDB")
	defer run(t, s, "DROP TABLE IF EXISTS "+quoted)
	run(t, s, "INSERT INTO "+quoted+"(id,n) VALUES(1,1.23)")
	request := editingRequest(t, s, name)
	request.Changes = []protocol.RowChange{{Kind: "update", Original: originalRow(t, s, name, "id=1"), Values: []protocol.ColumnAssignment{assign("n", typedText("1.234"))}}}
	if response := executeChanges(writer, request, false); response.Type != "error" || response.OutcomeUnknown {
		t.Fatal("lossy rounding warning was applied")
	}
	if *run(t, s, "SELECT n FROM "+quoted).Rows[0][0] != "1.23" {
		t.Fatal("rounding warning left changes committed")
	}
	run(t, writer, "SET SESSION explicit_defaults_for_timestamp=OFF")
	request.Changes[0].Values = []protocol.ColumnAssignment{assign("instant", protocol.CellValue{Kind: "null"})}
	if response := executeChanges(writer, request, false); response.Type != "error" || response.OutcomeUnknown {
		t.Fatal("SQL NULL became an implicit timestamp default")
	}
	if *run(t, s, "SELECT instant FROM "+quoted).Rows[0][0] != "2020-01-02 03:04:05" {
		t.Fatal("NULL timestamp assignment changed data")
	}
}

func TestMySQLSetCaptureDistinguishesEmptyMemberBits(t *testing.T) {
	s, reader, writer := integrationSession(t), integrationSession(t), integrationSession(t)
	name := fmt.Sprintf("dbeer_set_masks_%x", s.connectionID)
	quoted := QuoteIdentifier(name)
	run(t, s, "CREATE TABLE "+quoted+"(id INT PRIMARY KEY,s SET('','a'),note TEXT) ENGINE=InnoDB")
	defer run(t, s, "DROP TABLE IF EXISTS "+quoted)
	run(t, s, "INSERT INTO "+quoted+" VALUES(1,0,'first'),(2,1,'second'),(3,2,'third'),(4,3,'fourth'),(5,NULL,'fifth')")
	if err := reader.SetReadOnly(context.Background(), true); err != nil {
		t.Fatal("read-only setup failed")
	}
	table := tc.Table{Schema: integrationSettings(t).Database, Name: name}
	d, err := reader.DescribeTable(context.Background(), table)
	if err != nil {
		t.Fatal("SET descriptor failed")
	}
	sink := &dataCaptureTestSink{}
	_, _, err = reader.CaptureTable(context.Background(), tc.Spec{Table: table, DescriptorDigest: d.Digest, Columns: []string{"id", "s"}, Keys: []string{"id"}, ReadLimit: 10}, sink)
	if err != nil || len(sink.rows) != 5 {
		t.Fatal("SET exact capture failed")
	}
	want := []string{`[0, ""]`, `[1, ""]`, `[2, "61"]`, `[3, "61"]`}
	for i, expected := range want {
		if sink.rows[i][1] == nil || *sink.rows[i][1] != expected {
			t.Fatal("SET stored empty-member bit collapsed")
		}
	}
	if sink.rows[4][1] != nil {
		t.Fatal("SET SQL NULL collapsed")
	}
	request := editingRequest(t, s, name)
	request.Changes = []protocol.RowChange{{Kind: "update", Original: originalRow(t, s, name, "id=3"), Values: []protocol.ColumnAssignment{assign("note", typedText("changed"))}}}
	run(t, s, "UPDATE "+quoted+" SET s=3 WHERE id=3")
	if response := executeChanges(writer, request, false); response.Category != "conflict" {
		t.Fatal("ambiguous SET original overwrote another mask")
	}
}

func TestMySQLBrowseStorageTokensAllowExactChoiceEdits(t *testing.T) {
	s, writer := integrationSession(t), integrationSession(t)
	name := fmt.Sprintf("dbeer_choice_tokens_%x", s.connectionID)
	quoted := QuoteIdentifier(name)
	run(t, s, "CREATE TABLE "+quoted+"(id INT PRIMARY KEY,e ENUM('','a'),s SET('','a'),note VARCHAR(30)) ENGINE=InnoDB")
	defer run(t, s, "DROP TABLE IF EXISTS "+quoted)
	run(t, s, "SET SESSION sql_mode=''")
	run(t, s, "INSERT INTO "+quoted+" VALUES(1,1,3,'original'),(2,0,2,'other'),(3,NULL,NULL,'nulls')")
	browse := func() protocol.Response {
		response := catalogRequest(t, s, protocol.CatalogRequest{Kind: "browse", Schema: integrationSettings(t).Database, Object: name, ObjectKind: "table"})
		if len(response.Columns) != 4 || len(response.Rows) != 3 || len(response.StorageTokens) != 3 {
			t.Fatal("choice browse storage tokens missing or hidden columns exposed")
		}
		for _, row := range response.Rows {
			if len(row) != 4 {
				t.Fatal("hidden storage values leaked into visible results")
			}
		}
		if response.StorageTokens[0] == response.StorageTokens[1] || response.StorageTokens[1] == response.StorageTokens[2] {
			t.Fatal("different choice masks or SQL NULL share storage token")
		}
		return response
	}
	before := browse()
	request := editingRequest(t, s, name)
	request.Changes = []protocol.RowChange{{Kind: "update", Original: originalRow(t, s, name, "id=1"), StorageToken: before.StorageTokens[0], Values: []protocol.ColumnAssignment{assign("note", typedText("changed"))}}}
	if response := executeChanges(writer, request, true); response.Type != "query.result" {
		t.Fatal("exact empty-choice preview rejected")
	}
	if response := executeChanges(writer, request, false); response.Type != "query.result" {
		t.Fatalf("exact empty-choice apply rejected: category=%s state=%s", response.Category, response.SQLState)
	}
	before = browse()
	request.Changes[0].Original = originalRow(t, s, name, "id=1")
	request.Changes[0].StorageToken = before.StorageTokens[0]
	run(t, s, "UPDATE "+quoted+" SET e=0,s=2 WHERE id=1")
	if response := executeChanges(writer, request, false); response.Category != "conflict" {
		t.Fatal("hidden choice storage change was overwritten")
	}
}
