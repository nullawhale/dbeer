package mysql

import (
	"strings"
	"testing"
)

func TestIndexAttributeEvidenceKeepsVersionCommentsAndLiteralBoundaries(t *testing.T) {
	raw := "CREATE TABLE `t(able)` (`body` text COMMENT 'WITH PARSER ENGINE_ATTRIBUTE', KEY `WITH PARSER` (`body`(10)) COMMENT 'ENGINE_ATTRIBUTE' /*!80000 INVISIBLE */, FULLTEXT KEY `parsed` (`body`) /*!50100 WITH PARSER `ngram` */, KEY `engine` (`body`(8)) /*!80021 ENGINE_ATTRIBUTE='{\"WITH PARSER\":\"literal\"}' */) ENGINE=InnoDB COMMENT='WITH PARSER'"
	attrs, known, ok := mysqlIndexAttributeEvidence(raw, "")
	if !ok || !known["WITH PARSER"] || attrs["WITH PARSER"] != nil || attrs["parsed"]["reason"] != "FULLTEXT parser" || !strings.HasSuffix(attrs["parsed"]["definition"], "*/") || attrs["engine"]["reason"] != "index engine attributes" {
		t.Fatal("canonical index attribute boundaries were lost")
	}
	for _, test := range []struct{ mode, tail string }{
		{"", `COMMENT 'a\' WITH PARSER still_literal'`},
		{"ANSI_QUOTES,NO_BACKSLASH_ESCAPES", `COMMENT 'a'' WITH PARSER ''still_literal'`},
	} {
		raw := "CREATE TABLE `t` (`id` int, KEY `key` (`id`) " + test.tail + ") ENGINE=InnoDB"
		attrs, known, ok := mysqlIndexAttributeEvidence(raw, test.mode)
		if !ok || !known["key"] || len(attrs) != 0 {
			t.Fatal("a comment literal was mistaken for executable index attributes")
		}
	}
	for _, raw := range []string{"CREATE TABLE `t` (`id` int, KEY `i` (`id`) COMMENT 'unfinished)", "CREATE TABLE `t` (`id` int, KEY `i` (`id`) /* unfinished)"} {
		if _, _, ok := mysqlIndexAttributeEvidence(raw, ""); ok {
			t.Fatal("uncertain metadata was accepted as absence of hidden options")
		}
	}
	attrs, _, ok = mysqlIndexAttributeEvidence("CREATE TABLE `t` (`id` int, KEY `i` (`id`) FUTURE_OPTION 1)", "")
	if !ok || attrs["i"]["reason"] != "unrecognized index options" {
		t.Fatal("future index syntax was silently ignored")
	}
}
