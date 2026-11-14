package schemaimport

import (
	"context"
	"dbeer/helper/internal/mariadb"
	"dbeer/helper/internal/schemabundle"
	sc "dbeer/helper/internal/schemacompare"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMariaDBOfflineNativeDeclarationGrammar(t *testing.T) {
	sql := "CREATE TABLE `native_schema`.`t` (`id` BIGINT(20) UNSIGNED NOT NULL AUTO_INCREMENT,`n` DECIMAL(65,38) DEFAULT 123456789012345678901234567.12345678901234567890123456789012345678,`b` VARBINARY(8) DEFAULT X'00ff',`v` VARCHAR(32) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT '😀' INVISIBLE WITHOUT SYSTEM VERSIONING,`rs` TIMESTAMP(6) GENERATED ALWAYS AS ROW START,`re` TIMESTAMP(6) GENERATED ALWAYS AS ROW END,PERIOD FOR SYSTEM_TIME (`rs`,`re`),CONSTRAINT `PRIMARY` PRIMARY KEY (`id`,`re`) USING BTREE,KEY `ignored_native` (`v`(7) DESC) USING BTREE IGNORED COMMENT 'native') ENGINE=InnoDB DEFAULT CHARACTER SET=utf8mb4 COLLATE=utf8mb4_bin WITH SYSTEM VERSIONING"
	ast, e := parseDefinition(context.Background(), sql, "mariadb", "native_schema", false)
	if e != nil || len(ast.tables) != 1 {
		t.Fatalf("native table grammar unavailable: %v", e)
	}
	table, limited, e := applyTableAST(context.Background(), ast.tables[0], nil, nil, "mariadb", false)
	if e != nil || limited {
		t.Fatalf("native declaration gained incorrect manual state: %v", e)
	}
	if table.Kind.Value == nil || *table.Kind.Value != "systemVersioned" || len(table.Columns.Items) != 6 || len(table.Indexes.Items) != 2 {
		t.Fatal("native declaration kind/column/index facts changed")
	}
	if table.Columns.Items[1].Type.Value == nil || table.Columns.Items[1].Type.Value.Modifiers.Value == nil || *table.Columns.Items[1].Type.Value.Modifiers.Value.Scale != 38 {
		t.Fatal("native scale38 was reduced to legacy MySQL bounds")
	}
	if table.Columns.Items[2].Default.Value == nil || table.Columns.Items[2].Default.Value.Encoding != "base64" || *table.Columns.Items[2].Default.Value.Value != base64.StdEncoding.EncodeToString([]byte{0, 255}) {
		t.Fatal("native binary default was conflated with text")
	}
	index := table.Indexes.Items[1]
	if index.Visible.Value == nil || *index.Visible.Value || index.Keys.Items[0].Descending.Value == nil || !*index.Keys.Items[0].Descending.Value || index.Keys.Items[0].PrefixLength.Value == nil || *index.Keys.Items[0].PrefixLength.Value != 7 {
		t.Fatal("native ignored/direction/prefix index properties disappeared")
	}
	if e := validateOwnership(sc.Capture{Context: sc.CaptureContext{Engine: "mariadb"}, Tables: []sc.Table{table}}); e != nil {
		t.Fatal("native period declaration ownership failed")
	}
}
func TestMariaDBOfflineNativeBoundsAndUnknowns(t *testing.T) {
	for _, sql := range []string{"DECIMAL(66,38)", "DECIMAL(65,39)", "DECIMAL(5,6)", "FLOAT(256,2)", "FLOAT(5,31)", "BIT(65)", "UUID(1)", "INET4(4)"} {
		tokens, e := lex(context.Background(), sql, "mariadb", false)
		if e != nil {
			t.Fatal("native bounded type lex failed")
		}
		if _, e = builtinType(tokens, "mariadb"); e == nil {
			t.Fatal("unsupported native type bound became known")
		}
	}
	for _, sql := range []string{"/*M!100100 DROP TABLE outside */ CREATE TABLE t(id INT)", "/*!100100 DROP TABLE outside */ CREATE TABLE t(id INT)"} {
		if _, e := parseDefinition(context.Background(), sql, "mariadb", "native_schema", false); e == nil {
			t.Fatal("native executable comments were treated as harmless metadata")
		}
	}
	ast, e := parseDefinition(context.Background(), "CREATE TABLE t(id INT,KEY k(id) KEY_BLOCK_SIZE=8) ENGINE=InnoDB", "mariadb", "native_schema", false)
	if e != nil {
		t.Fatal("unknown property envelope could not be inspected")
	}
	if _, _, e = applyTableAST(context.Background(), ast.tables[0], nil, nil, "mariadb", false); e == nil {
		t.Fatal("unknown native index option gained complete independent facts")
	}
	for _, engine := range []string{"mysql", "postgresql"} {
		tokens, e := lex(context.Background(), "DECIMAL(65,38)", engine, false)
		if e != nil {
			t.Fatal("legacy type lexer changed")
		}
		if _, e = builtinType(tokens, engine); e != nil {
			t.Fatal("legacy independent grammar was tightened by MariaDB admission")
		}
	}
}
func TestMariaDBOfflineImplicitPeriodAddresses(t *testing.T) {
	ast, e := parseDefinition(context.Background(), "CREATE TABLE t(id INT NOT NULL,CONSTRAINT `PRIMARY` PRIMARY KEY(id,row_end) USING BTREE) ENGINE=InnoDB WITH SYSTEM VERSIONING", "mariadb", "native_schema", false)
	if e != nil {
		t.Fatal("native implicit period grammar failed")
	}
	table, limited, e := applyTableAST(context.Background(), ast.tables[0], nil, nil, "mariadb", false)
	if e != nil || limited || len(table.Columns.Items) != 1 {
		t.Fatal("native implicit periods invented ordinary columns")
	}
	if e := validateOwnership(sc.Capture{Context: sc.CaptureContext{Engine: "mariadb"}, Tables: []sc.Table{table}}); e != nil {
		t.Fatal("proven implicit period index address was rejected")
	}
	table.Options.Items = nil
	if e := validateOwnership(sc.Capture{Context: sc.CaptureContext{Engine: "mariadb"}, Tables: []sc.Table{table}}); e == nil {
		t.Fatal("missing period witness authorized a nonexistent column")
	}
}
func mariaDBNativeWriteBundle(t *testing.T, capture sc.Capture) (string, schemabundle.Manifest) {
	t.Helper()
	ctx := context.Background()
	result, e := schemabundle.Build(ctx, t.TempDir(), capture, []string{"native_schema"}, mariadb.RenderSchemaDefinition)
	if e != nil {
		t.Fatalf("native bundle build failed: %v", e)
	}
	defer result.Close()
	dir := t.TempDir()
	files := []schemabundle.File{result.Summary.Manifest, result.Manifest.Capture}
	for _, object := range result.Manifest.Objects {
		files = append(files, object.File)
	}
	for _, file := range files {
		data := []byte{}
		for offset := int64(0); ; {
			chunk, e := result.Chunk(ctx, file.ID, offset, 65536)
			if e != nil {
				t.Fatal("native bundle chunk unavailable")
			}
			part, e := base64.StdEncoding.DecodeString(chunk.DataBase64)
			if e != nil {
				t.Fatal("native chunk encoding invalid")
			}
			data = append(data, part...)
			offset = chunk.NextOffset
			if !chunk.HasMore {
				break
			}
		}
		if e := os.WriteFile(filepath.Join(dir, file.Path), data, 0600); e != nil {
			t.Fatal("native bundle fixture write failed")
		}
	}
	return dir, result.Manifest
}
func TestMariaDBOfflineNativeBundleRead(t *testing.T) {
	ast, e := parseDefinition(context.Background(), "CREATE TABLE native_schema.t(id INT(11) NOT NULL,n DECIMAL(65,38) DEFAULT 0.125,b VARBINARY(8) DEFAULT X'00ff',v VARCHAR(32) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT '😀' INVISIBLE,CONSTRAINT `PRIMARY` PRIMARY KEY(id) USING BTREE,KEY ignored_native(v(7) DESC) USING BTREE IGNORED) ENGINE=InnoDB DEFAULT CHARACTER SET=utf8mb4 COLLATE=utf8mb4_bin", "mariadb", "native_schema", false)
	if e != nil {
		t.Fatal("native bundle SQL envelope failed")
	}
	table, limited, e := applyTableAST(context.Background(), ast.tables[0], nil, nil, "mariadb", false)
	if e != nil || limited {
		t.Fatal("native pure bundle facts unavailable")
	}
	table.Dependencies = sc.DerivedDependencies(table)
	capture := sc.Capture{Context: sc.CaptureContext{Engine: "mariadb", Consistency: "bestEffort", Visibility: "complete", EngineContext: sc.Known([]sc.Option{{Name: "sqlMode", Value: ""}})}, Inventories: []sc.Inventory{{Schema: "native_schema", Existence: "present", Tables: sc.Complete([]sc.Ref{table.Ref}), Types: sc.Complete[sc.Ref](nil)}}, Tables: []sc.Table{table}}
	dir, manifest := mariaDBNativeWriteBundle(t, capture)
	imported, e := Read(context.Background(), schemabundle.Source{Path: dir}, t.TempDir(), mariadb.RenderSchemaDefinition)
	if e != nil {
		t.Fatalf("native independent offline bundle read failed: %v", e)
	}
	if imported.Capture.Context.Engine != "mariadb" || len(imported.Capture.Tables) != 1 || imported.Summary.ModifiedSQL != 0 || imported.Summary.ManualObjects != 0 {
		t.Fatalf("native offline summary: manual=%d complete=%t engineKnown=%t tables=%d modified=%d", imported.Summary.ManualObjects, imported.Summary.Complete, imported.Capture.Context.Engine == "mariadb", len(imported.Capture.Tables), imported.Summary.ModifiedSQL)
	}
	before, e := json.Marshal(imported.Capture.Tables[0].Columns)
	if e != nil {
		t.Fatal("native imported facts invalid")
	}
	if !strings.Contains(string(before), "38") {
		t.Fatal("native imported scale bound disappeared")
	}
	for _, object := range manifest.Objects {
		if object.Ref != table.Ref {
			continue
		}
		path := filepath.Join(dir, object.File.Path)
		original, re := os.ReadFile(path)
		if re != nil {
			t.Fatal("native SQL fixture unavailable")
		}
		edited := strings.Replace(string(original), " IGNORED", " NOT IGNORED", 1)
		if edited == string(original) {
			t.Fatal("native ignored property not explicitly emitted")
		}
		if os.WriteFile(path, []byte(edited), 0600) != nil {
			t.Fatal("native SQL edit unavailable")
		}
		changed, re := Read(context.Background(), schemabundle.Source{Path: dir, AllowSQLChanges: true}, t.TempDir(), mariadb.RenderSchemaDefinition)
		if re != nil || changed.Summary.ModifiedSQL != 1 || changed.Summary.ManualObjects != 0 {
			t.Fatal("reviewed native index change did not derive independent facts")
		}
		found := false
		for _, x := range changed.Capture.Tables[0].Indexes.Items {
			if x.Ref.Name == "ignored_native" {
				found = x.Visible.Value != nil && *x.Visible.Value
			}
		}
		if !found {
			t.Fatal("native changed SQL retained stale ignored-index facts")
		}
		retained, _ := json.Marshal(imported.Capture.Tables[0].Columns)
		if string(retained) != string(before) {
			t.Fatal("offline edit mutated retained source facts")
		}
		if os.WriteFile(path, []byte(strings.Replace(edited, "NOT IGNORED", "NOT IGNORED KEY_BLOCK_SIZE=8", 1)), 0600) != nil {
			t.Fatal("native unknown option edit unavailable")
		}
		if _, re = Read(context.Background(), schemabundle.Source{Path: dir, AllowSQLChanges: true}, t.TempDir(), mariadb.RenderSchemaDefinition); re == nil {
			t.Fatal("unmodeled changed index property gained independent authority")
		}
	}

}
