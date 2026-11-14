package mariadb

import (
	"context"
	"encoding/base64"
	"errors"
	"reflect"
	"strings"
	"testing"

	sc "dbeer/helper/internal/schemacompare"
)

func TestMariaDBSchemaNativeDefaultConstants(t *testing.T) {
	textType := mariaSchemaType("varchar", "varchar(64)", "utf8mb4", "64", "", "", "")
	for _, test := range []struct {
		raw                   *string
		kind, value, encoding string
	}{
		{nil, "none", "", ""}, {schemaString("NULL"), "sqlNull", "", ""}, {schemaString("'NULL'"), "literal", "NULL", "text"}, {schemaString("''"), "literal", "", "text"}, {schemaString("'q''s\\n\\\\x'"), "literal", "q's\n\\x", "text"}, {schemaString("(concat('a','b'))"), "expression", "", ""}, {schemaString("9007199254741105.0000"), "literal", "9007199254741105.0000", "text"},
	} {
		got := mariaSchemaDefault(test.raw, textType, "utf8mb4")
		if got.Value == nil || got.Value.Kind != test.kind {
			t.Fatal("native literal/expression/NULL classification changed")
		}
		if test.kind == "literal" && (got.Value.Value == nil || *got.Value.Value != test.value || got.Value.Encoding != test.encoding) {
			t.Fatal("native default spelling or escape bytes changed")
		}
	}
	binaryType := mariaSchemaType("varbinary", "varbinary(8)", "", "8", "", "", "")
	got := mariaSchemaDefault(schemaString("'\\0\\\\\\''"), binaryType, "binary")
	if got.Value == nil || got.Value.Value == nil || got.Value.Encoding != "base64" || *got.Value.Value != base64.StdEncoding.EncodeToString([]byte{0, '\\', '\''}) {
		t.Fatal("binary catalog default lost exact bytes")
	}
	for _, input := range []string{"'unterminated", "'a'b'", "'\\q'"} {
		if _, ok := mariaCatalogLiteral(input); ok {
			t.Fatal("malformed catalog constant was decoded")
		}
	}
}
func schemaString(value string) *string { return &value }
func TestMariaDBSchemaNativeIndexClausesAndSequence(t *testing.T) {
	raw := "CREATE TABLE `t` (`id` int(11), KEY `k` (`id` DESC) /*!100623 IGNORED */, KEY `opaque` (`id`) KEY_BLOCK_SIZE=8) ENGINE=InnoDB"
	attrs, names, ok := mariaIndexAttributeEvidence(raw, "")
	if !ok || !names["k"] || len(attrs["k"]) != 0 || attrs["opaque"]["reason"] != "index key block size" {
		t.Fatal("native ignored index or opaque property evidence changed")
	}
	seq, ok := mariaSequenceDefinition(sc.Ref{Schema: "s", Name: "seq"}, "CREATE SEQUENCE `seq` start with 9007199254741105 minvalue 1 maxvalue 9223372036854775806 increment by 7 cache 17 nocycle ENGINE=InnoDB", "")
	if !ok || seq.Ref.Kind != "sequence" || seq.Start.Value == nil || *seq.Start.Value != "9007199254741105" || seq.Cache.Value == nil || *seq.Cache.Value != "17" {
		t.Fatal("native sequence configuration lost exactness")
	}
	_, ok = mariaSequenceDefinition(seq.Ref, "CREATE SEQUENCE `seq` start with 1 start with 2 minvalue 1 maxvalue 10 increment by 1 nocache nocycle ENGINE=InnoDB", "")
	if ok {
		t.Fatal("ambiguous sequence definition acquired completeness")
	}
}
func TestMariaDBSchemaNativeBoundsAndSinkCancellation(t *testing.T) {
	failure := errors.New("controlled schema sink failure")
	budget := sc.NewCollector(context.Background(), sc.Limits{Nodes: 1, Members: 2, Bytes: 1000, Scalar: 32})
	sink := &mariaSchemaSink{budget: budget, next: &schemaFailSink{err: failure}}
	if !errors.Is(sink.Inventory(sc.Inventory{Schema: "s"}), failure) {
		t.Fatal("schema sink backpressure was swallowed")
	}
	if reflect.DeepEqual(mariaRowsDigest([][]*string{{nil}}), mariaRowsDigest([][]*string{{schemaString("")}})) {
		t.Fatal("metadata NULL and empty scalars share a digest")
	}
}

type schemaFailSink struct {
	sc.Sink
	err error
}

func (s *schemaFailSink) Inventory(sc.Inventory) error { return s.err }

func TestMariaDBSchemaNativeOpaquePropertyBoundaries(t *testing.T) {
	raw := "CREATE TABLE `t` (`v` varchar(32) COMMENT 'PARTITION BY HASH(fake)') ENGINE=InnoDB PARTITION BY HASH(`id`) PARTITIONS 2"
	tail, ok := mariaPartitionTail(raw, "")
	if !ok || tail != "PARTITION BY HASH(`id`) PARTITIONS 2" {
		t.Fatal("native partition token boundary entered quoted column text")
	}
	if _, ok = mariaPartitionTail("CREATE TABLE `t` (`v` varchar(32) COMMENT 'PARTITION BY HASH(fake)') ENGINE=InnoDB", ""); ok {
		t.Fatal("quoted partition text gained native property authority")
	}
	periods, ok := mariaApplicationPeriods("CREATE TABLE `t` (`v` date,`e` date,PERIOD FOR `valid_time` (`v`,`e`),PERIOD FOR SYSTEM_TIME(`v`,`e`))", "")
	if !ok || len(periods) != 1 || periods[0] != "PERIOD FOR `valid_time` (`v`,`e`)" {
		t.Fatal("application and system period metadata were conflated")
	}
	if _, ok = mariaApplicationPeriods("CREATE TABLE `t` (`v` date,PERIOD FOR p (`v`", ""); ok {
		t.Fatal("malformed application-period evidence was accepted")
	}
	if got := mariaUnmodeledExtra("on update current_timestamp(6) INVISIBLE WITHOUT SYSTEM VERSIONING"); got != "" {
		t.Fatal("known native column extra retained a false unknown tail")
	}
	if got := mariaUnmodeledExtra("INVISIBLE FUTURE_NATIVE_PROPERTY"); got != "FUTURE_NATIVE_PROPERTY" {
		t.Fatal("unknown native column extra disappeared")
	}
}

func TestMariaDBSchemaNativeDefinitionWitness(t *testing.T) {
	base := "CREATE TABLE `t` (`id` int(11),`v` date,`e` date,KEY `k` (`id`)) ENGINE=InnoDB AUTO_INCREMENT=1"
	if mariaDefinitionIndexDigest(base, "") != mariaDefinitionIndexDigest(strings.Replace(base, "AUTO_INCREMENT=1", "AUTO_INCREMENT=9", 1), "") {
		t.Fatal("volatile counter entered native definition witness")
	}
	for _, pair := range [][2]string{{base + " PARTITION BY HASH(`id`) PARTITIONS 2", base + " PARTITION BY HASH(`id`) PARTITIONS 3"}, {"CREATE TABLE `t` (`v` date,`e` date,PERIOD FOR p(`v`,`e`))", "CREATE TABLE `t` (`v` date,`e` date,PERIOD FOR q(`v`,`e`))"}, {base, base + " PARTITION BY HASH(`id`) PARTITIONS 2"}} {
		if mariaDefinitionIndexDigest(pair[0], "") == mariaDefinitionIndexDigest(pair[1], "") {
			t.Fatal("opaque native property or presence disappeared from definition witness")
		}
	}
}
