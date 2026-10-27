package sqlcomplete

import (
	"fmt"
	"reflect"
	"slices"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestCompletionAbbreviationsAndTypos(t *testing.T) {
	for _, engine := range []string{"postgresql", "mysql"} {
		context := fixture(engine)
		context.Catalog = append(context.Catalog,
			Relation{Schema: "app_data", Name: "order_items", Kind: "table", Columns: []string{"order_id", "Display Name", "HTTPStatus", "Üser_ID"}},
			Relation{Schema: "public", Name: "OrderItems", Kind: "view"},
			Relation{Schema: "public", Name: "noise", Kind: "table"},
			Relation{Schema: "public", Name: "total_items", Kind: "function"})
		for _, check := range []struct{ sql, label string }{
			{"SELECT * FROM oi|", "order_items"},
			{"SELECT * FROM OI|", "OrderItems"},
			{"SELECT * FROM orditem|", "order_items"},
			{"SELECT * FROM items|", "order_items"},
			{"SELECT * FROM o_i|", "order_items"},
			{"SELECT * FROM ordres|", "orders"},
			{"SELECT * FROM ordr|", "orders"},
			{"SELECT * FROM oorders|", "orders"},
			{"SELECT * FROM cusotm|", "customers"},
			{"SELECT * FROM cstomers|", "customers"},
			{"SELECT * FROM custamrs|", "customers"},
			{"SELECT * FROM ad|", "app_data"},
			{"SELECT * FROM app_data.oi|", "order_items"},
			{"SELECT ti|", "total_items"},
			{"SELECT d.oi| FROM app_data.order_items d", "order_id"},
			{"SELECT d.dn| FROM app_data.order_items d", "Display Name"},
			{"SELECT d.hs| FROM app_data.order_items d", "HTTPStatus"},
			{"SELECT d.üi| FROM app_data.order_items d", "Üser_ID"},
			{"WITH recent AS (SELECT order_id FROM app_data.order_items) SELECT r.oi| FROM recent r", "order_id"},
			{"SELECT d.oi| FROM (SELECT order_id FROM app_data.order_items) d", "order_id"},
		} {
			t.Run(engine+"/"+check.sql, func(t *testing.T) {
				items := suggestions(t, check.sql, context)
				if _, ok := itemWithLabel(items, check.label); !ok {
					t.Fatalf("missing %s in %#v", check.label, items)
				}
			})
		}
		for _, check := range []struct{ sql, label string }{
			{"SELECT * FROM oi|", "noise"},  // Not an arbitrary subsequence.
			{"SELECT * FROM ox|", "orders"}, // No typo correction for two letters.
			{"SELECT * FROM xyzq|", "orders"},
			{"SELECT d.oi| FROM orders d", "order_id"},                     // No unrelated columns.
			{"SELECT d.hs| FROM app_data.order_items other", "HTTPStatus"}, // No fuzzy alias binding.
		} {
			if item, ok := itemWithLabel(suggestions(t, check.sql, context), check.label); ok {
				t.Errorf("%s offered unexpected %#v", check.sql, item)
			}
		}
	}
}

func FuzzNameMatchSpans(f *testing.F) {
	for _, seed := range [][2]string{
		{"oi", "order_items"}, {"ordit", "OrderItems"}, {"ordes", "orders"}, {"ordres", "orders"},
		{"😀o", "😀orders"}, {"dn", "😀Display_Name"}, {"ui", "user_item_id"},
		{strings.Repeat("a", 63) + "b", strings.Repeat("a", 64)},
	} {
		f.Add(seed[0], seed[1])
	}
	f.Fuzz(func(t *testing.T, query, label string) {
		if len(query) > 1024 || len(label) > 1024 || !utf8.ValidString(query) || !utf8.ValidString(label) {
			return
		}
		matcher := newNameMatcher(query)
		rank, ok := matcher.match(label)
		var spans []MatchSpan
		tracedRank, tracedOK := matcher.search(label, &spans)
		if rank != tracedRank || ok != tracedOK {
			t.Fatal("tracing changed search quality")
		}
		if !ok || query == "" {
			if len(spans) != 0 {
				t.Fatal("highlight without a typed match")
			}
			return
		}
		if len(spans) == 0 || len(spans) > 64 {
			t.Fatal("missing or unbounded highlight")
		}
		letters := map[rune]int{}
		for _, r := range strings.ToLower(query) {
			letters[r]++
		}
		previous := 0
		for _, span := range spans {
			if span.Start < previous || span.End <= span.Start || span.End > len(label) ||
				!utf8.ValidString(label[:span.Start]) || !utf8.ValidString(label[span.Start:span.End]) {
				t.Fatal("invalid label span")
			}
			for _, r := range strings.ToLower(label[span.Start:span.End]) {
				letters[r]--
				if letters[r] < 0 {
					t.Fatal("highlighted a letter that did not match the query")
				}
			}
			previous = span.End
		}
	})
}

func TestCompletionRanksScopeAndMatchQualityBeforeTruncation(t *testing.T) {
	for _, engine := range []string{"postgresql", "mysql"} {
		context := fixture(engine)
		context.Catalog[0].Columns = []string{"count_items", "coin", "count_value", "orders_total", "order_id"}
		context.Catalog = append(context.Catalog,
			Relation{Schema: "public", Name: "order_info", Kind: "function"},
			Relation{Schema: "public", Name: "ordres_report", Kind: "function"})
		for i := range 400 {
			context.Catalog = append(context.Catalog, Relation{Schema: "public", Name: fmt.Sprintf("co_%03d", i), Kind: "function"})
		}
		items := suggestions(t, "SELECT co| FROM orders o", context)
		if len(items) != 256 || items[0].Label != "coin" || items[1].Label != "count_items" || items[2].Label != "count_value" {
			t.Fatalf("query columns must lead even in a large catalog: %#v", items[:min(len(items), 4)])
		}
		items = suggestions(t, "SELECT count| FROM orders o", context)
		if len(items) == 0 || items[0].Label != "COUNT" {
			t.Fatal("an exact function must precede longer column prefixes")
		}
		items = suggestions(t, "SELECT oi| FROM orders o", context)
		if len(items) < 2 || items[0].Label != "order_id" || items[1].Label != "order_info" {
			t.Fatal("a query-column abbreviation must precede general function abbreviations")
		}
		items = suggestions(t, "SELECT ordres| FROM orders o", context)
		if len(items) < 2 || items[0].Label != "ordres_report" || items[1].Label != "orders_total" {
			t.Fatal("strong matches must precede typo-only matches")
		}
		items = suggestions(t, "WITH orders_local AS (SELECT id FROM orders) SELECT * FROM ord|", context)
		if len(items) == 0 || items[0].Label != "orders_local" {
			t.Fatal("local CTEs must precede catalog table prefixes")
		}
		items = suggestions(t, "SELECT * FROM orders o JOIN custmo|", context)
		if len(items) < 2 || items[0].Kind != 15 || items[0].Label != "customers" {
			t.Fatal("FK join must precede plain table for the same misspelling")
		}
		before := suggestions(t, "SELECT co| FROM orders o", context)
		slices.Reverse(context.Catalog)
		after := suggestions(t, "SELECT co| FROM orders o", context)
		if !reflect.DeepEqual(before, after) {
			t.Fatal("catalog enumeration order must not change ranked results")
		}
	}
}

func TestNameSearchWordBoundariesUnicodeAndLimits(t *testing.T) {
	for _, check := range []struct {
		query, label string
		want         bool
	}{
		{"oi", "order_items", true}, {"oi", "order_line_items", true},
		{"ordit", "OrderItems", true}, {"os", "OrderItems", false},
		{"hs", "HTTPServer", true}, {"hs", "HTTPStatus", true},
		{"v2i", "version2Items", true}, {"dn", "Display-Name", true},
		{"ui", "user_id", true}, {"üi", "Üser_ID", true},
		{"名番", "名前_番号", true}, {"😀", "😀orders", true},
		{"_", "_", true}, {"__", "orders", false},
		{"a", "b", false}, {"ab", "ac", false},
		{"ordres", "orders", true}, {"ordes", "orders", true},
		{"ordeers", "orders", true}, {"orcres", "orders", false},
		{"custamrs", "customers", true}, {"custaxzz", "customers", false},
		{strings.Repeat("a", 65), strings.Repeat("a", 66), true},
		{strings.Repeat("a", 64) + "b", strings.Repeat("a", 66), false},
		{"oi", "order_" + strings.Repeat("x", 256) + "_items", false},
	} {
		t.Run(check.query+"/"+check.label, func(t *testing.T) {
			_, ok := newNameMatcher(check.query).match(check.label)
			if ok != check.want {
				t.Fatalf("match = %v, want %v", ok, check.want)
			}
		})
	}
}

func BenchmarkCompletionLargeCatalogSearch(b *testing.B) {
	context := Context{Engine: "postgresql"}
	sources := []string{}
	for i := range 2048 {
		entry := Relation{Schema: "public", Name: fmt.Sprintf("order_items_%04d", i), Kind: "table"}
		if i < 256 {
			sources = append(sources, fmt.Sprintf("%s t%d", entry.Name, i))
			for c := range 128 {
				entry.Columns = append(entry.Columns, fmt.Sprintf("order_item_%03d", c))
			}
		}
		context.Catalog = append(context.Catalog, entry)
	}
	for _, check := range []struct{ name, sql, prefix string }{
		{"tables/abbreviation", "SELECT * FROM oi", ""},
		{"tables/typo", "SELECT * FROM odrer", ""},
		{"columns/abbreviation", "SELECT oi FROM " + strings.Join(sources, ", "), "SELECT oi"},
		{"columns/typo", "SELECT odrer FROM " + strings.Join(sources, ", "), "SELECT odrer"},
	} {
		b.Run(check.name, func(b *testing.B) {
			offset := len(check.sql)
			if check.prefix != "" {
				offset = len(check.prefix)
			}
			b.ReportAllocs()
			for b.Loop() {
				Complete(check.sql, offset, context)
			}
		})
	}
}
