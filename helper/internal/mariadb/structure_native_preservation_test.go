package mariadb

import (
	"dbeer/helper/internal/tableedit"
	"testing"
)

func TestMariaDBNativeStructurePreservationOnlyReviewedSlots(t *testing.T) {
	base := tableedit.Baseline{Target: tableedit.Target{Schema: "s", Table: "t"}, NativeDefinition: "CREATE TABLE `t` (`id` int(11) NOT NULL,`v` varchar(20) DEFAULT NULL COMMENT 'DEFAULT stays',KEY `kept` (`id`) KEY_BLOCK_SIZE=8) ENGINE=InnoDB ROW_FORMAT=COMPRESSED COMMENT='preserve'"}
	d := tableedit.Default{Kind: "text"}
	ch := tableedit.ColumnChange{Name: "v", Default: &d}
	c := tableedit.Condition{Operation: tableedit.Operation{Kind: "changeColumn", Change: &ch}}
	after := base
	after.NativeDefinition = "CREATE TABLE `t` (`id` int(11) NOT NULL,`v` varchar(20) DEFAULT 'NULL' COMMENT 'DEFAULT stays',KEY `kept` (`id`) KEY_BLOCK_SIZE=8) ENGINE=InnoDB ROW_FORMAT=COMPRESSED COMMENT='preserve'"
	if !mariaDBNativeStructurePreserved(base, after, c) {
		t.Fatal("reviewed default slot changed unrelated native evidence")
	}
	for _, bad := range []string{
		"CREATE TABLE `t` (`id` int(11),`v` varchar(20) DEFAULT 'NULL' COMMENT 'DEFAULT stays',KEY `kept` (`id`) KEY_BLOCK_SIZE=8) ENGINE=InnoDB ROW_FORMAT=COMPRESSED COMMENT='preserve'",
		"CREATE TABLE `t` (`id` int(11) NOT NULL,`v` varchar(20) DEFAULT 'NULL' COMMENT 'changed',KEY `kept` (`id`) KEY_BLOCK_SIZE=8) ENGINE=InnoDB ROW_FORMAT=COMPRESSED COMMENT='preserve'",
		"CREATE TABLE `t` (`id` int(11) NOT NULL,`v` varchar(20) DEFAULT 'NULL' COMMENT 'DEFAULT stays',KEY `kept` (`id`) KEY_BLOCK_SIZE=4) ENGINE=InnoDB ROW_FORMAT=COMPRESSED COMMENT='preserve'",
		"CREATE TABLE `t` (`id` int(11) NOT NULL,`v` varchar(20) DEFAULT 'NULL' COMMENT 'DEFAULT stays',KEY `kept` (`id`) KEY_BLOCK_SIZE=8) ENGINE=Aria ROW_FORMAT=COMPRESSED COMMENT='preserve'",
	} {
		after.NativeDefinition = bad
		if mariaDBNativeStructurePreserved(base, after, c) {
			t.Fatal("unselected native property was erased from preservation proof")
		}
	}
}

func TestMariaDBBackfillPreservesEveryNativeSchemaSlot(t *testing.T) {
	b := tableedit.Baseline{Target: tableedit.Target{Schema: "s", Table: "t"}, NativeDefinition: "CREATE TABLE `t` (`id` int NOT NULL,`v` int DEFAULT NULL COMMENT 'retained') ENGINE=InnoDB"}
	name := "v"
	c := tableedit.Condition{Operation: tableedit.Operation{Kind: "backfill", Name: &name}}
	if !mariaDBNativeStructurePreserved(b, b, c) {
		t.Fatal("data-only reviewed UPDATE did not retain exact schema")
	}
	a := b
	a.NativeDefinition = "CREATE TABLE `t` (`id` int NOT NULL,`v` int DEFAULT NULL COMMENT 'changed') ENGINE=InnoDB"
	if mariaDBNativeStructurePreserved(b, a, c) {
		t.Fatal("data-only reviewed UPDATE normalized native schema drift")
	}
}

func TestMariaDBNativeForeignConstraintAndIndexNamespacesStayDistinct(t *testing.T) {
	b := tableedit.Baseline{Target: tableedit.Target{Schema: "s", Table: "t"}, NativeDefinition: "CREATE TABLE `t` (`id` int,KEY `shared_fk` (`id`),CONSTRAINT `shared_fk` FOREIGN KEY (`id`) REFERENCES `parent` (`id`)) ENGINE=InnoDB"}
	native, ok := mariaDBNativeStructure(b.NativeDefinition, "", "t")
	if !ok || len(native.objects) != 2 {
		t.Fatal("native independent index/constraint namespaces collided")
	}
	after := b
	after.NativeDefinition = "CREATE TABLE `t` (`id` int,KEY `shared_fk` (`id`)) ENGINE=InnoDB"
	c := tableedit.Condition{Operation: tableedit.Operation{Kind: "dropKey", Key: &tableedit.KeyEdit{Name: "shared_fk", Kind: "foreign"}}}
	if !mariaDBNativeStructurePreserved(b, after, c) {
		t.Fatal("selected FK drop did not retain same-named native index")
	}
	after.NativeDefinition = "CREATE TABLE `t` (`id` int) ENGINE=InnoDB"
	if mariaDBNativeStructurePreserved(b, after, c) {
		t.Fatal("FK drop also erased supporting index without an explicit reviewed step")
	}
	duplicate := "CREATE TABLE `t` (`id` int,KEY `shared` (`id`),UNIQUE KEY `shared` (`id`)) ENGINE=InnoDB"
	if _, ok := mariaDBNativeStructure(duplicate, "", "t"); ok {
		t.Fatal("duplicate native index namespace admitted")
	}
}
