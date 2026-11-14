package postgres

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"strings"
	"testing"
)

func TestStructureAdvancedSelectedSubtreeKeysLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	f.exec("CREATE TABLE " + f.table("scope_root") + "(root_key integer,mid_key integer,sub_key integer,payload text) PARTITION BY RANGE(root_key)")
	f.exec("CREATE TABLE " + f.table("scope_mid") + " PARTITION OF " + f.table("scope_root") + " FOR VALUES FROM(0) TO(100) PARTITION BY RANGE(mid_key)")
	f.exec("CREATE TABLE " + f.table("scope_nested") + " PARTITION OF " + f.table("scope_mid") + " FOR VALUES FROM(0) TO(100) PARTITION BY RANGE(sub_key)")
	f.exec("CREATE TABLE " + f.table("scope_leaf") + " PARTITION OF " + f.table("scope_nested") + " FOR VALUES FROM(0) TO(100)")
	f.exec("CREATE TABLE " + f.table("scope_mid_leaf") + " PARTITION OF " + f.table("scope_mid") + " FOR VALUES FROM(100) TO(200)")
	f.exec("CREATE TABLE " + f.table("scope_sibling") + " PARTITION OF " + f.table("scope_root") + " FOR VALUES FROM(100) TO(200) PARTITION BY LIST((root_key % 2))")
	f.exec("CREATE TABLE " + f.table("scope_sibling_leaf") + " PARTITION OF " + f.table("scope_sibling") + " FOR VALUES IN(1)")
	f.exec("COMMENT ON TABLE " + f.table("scope_sibling") + " IS 'unselected expression partition retained'")
	f.exec("INSERT INTO " + f.table("scope_root") + " VALUES(1,10,1,''),(1,10,2,'NULL'),(2,110,1,NULL),(101,7,7,'sibling')")
	var originalDefinition string
	if f.observer.QueryRow(ctx, "SELECT pg_catalog.pg_get_partkeydef($1::pg_catalog.regclass)", f.table("scope_sibling")).Scan(&originalDefinition) != nil || originalDefinition == "" {
		t.Fatal("unselected expression partition metadata unavailable")
	}
	s := &Session{conn: f.conn}
	store := &tableedit.Store{}
	target := tableedit.Target{Schema: f.schema, Table: "scope_mid"}
	b, err := store.Load(ctx, s, target)
	if err != nil || b.Baseline.Advanced == nil || b.Baseline.Advanced.FamilyCount != 7 {
		t.Fatal("complete connected family was not captured")
	}
	bad := tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Keys: []tableedit.KeyEdit{{Action: "add", Kind: "unique", Name: "scope_bad", Columns: []string{"mid_key"}}}}
	if _, err = store.PreviewContext(ctx, s, b.Baseline.ID, bad); err == nil || !strings.Contains(err.Error(), "every direct key column") {
		t.Fatal("selected descendant partition key was not required")
	}
	good := tableedit.Draft{AuthoringVersion: 2, Columns: []tableedit.Column{}, Keys: []tableedit.KeyEdit{{Action: "add", Kind: "unique", Name: "scope_unique", Columns: []string{"mid_key", "sub_key"}}}}
	authoringApply(t, s, store, target, good)
	var count int
	if f.observer.QueryRow(ctx, "SELECT pg_catalog.count(*) FROM "+f.table("scope_root")).Scan(&count) != nil || count != 4 {
		t.Fatal("affected or unrelated rows changed")
	}
	var definition string
	if f.observer.QueryRow(ctx, "SELECT pg_catalog.pg_get_partkeydef($1::pg_catalog.regclass)", f.table("scope_sibling")).Scan(&definition) != nil || definition != originalDefinition {
		t.Fatal("unselected expression partition changed")
	}
}
