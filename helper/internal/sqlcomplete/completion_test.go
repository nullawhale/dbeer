package sqlcomplete

import (
	"strings"
	"testing"
	"unicode/utf8"
)

func fixture(engine string) Context {
	return Context{Engine: engine, Catalog: []Relation{
		{Schema: "public", Name: "orders", Kind: "table", Columns: []string{"id", "customer_id", "tenant_id", "total", "status"}, ForeignKeys: []ForeignKey{
			{Name: "orders_customer_fk", TargetSchema: "public", TargetTable: "customers", Columns: []ForeignKeyColumn{{Source: "tenant_id", Target: "tenant_id"}, {Source: "customer_id", Target: "id"}}},
		}},
		{Schema: "public", Name: "customers", Kind: "table", Columns: []string{"id", "tenant_id", "name"}},
		{Schema: "private", Name: "secret", Kind: "table", Columns: []string{"secret_only"}},
		{Schema: "public", Name: "nodes", Kind: "table", Columns: []string{"id", "parent_id"}, ForeignKeys: []ForeignKey{
			{Name: "nodes_parent_fk", TargetSchema: "public", TargetTable: "nodes", Columns: []ForeignKeyColumn{{Source: "parent_id", Target: "id"}}},
		}},
	}}
}

func suggestions(t *testing.T, sql string, context Context) []Item {
	t.Helper()
	offset := strings.Index(sql, "|")
	if offset < 0 {
		t.Fatal("missing cursor marker")
	}
	sql = strings.Replace(sql, "|", "", 1)
	return Complete(sql, offset, context)
}

func TestClauseContextAndProjectionAliases(t *testing.T) {
	for _, engine := range []string{"postgresql", "mysql"} {
		for _, check := range []struct {
			sql     string
			yes, no []string
		}{
			{"SELECT * FROM |", []string{"orders", "customers", "public"}, []string{"SELECT", "COUNT", "total"}},
			{"SELECT * FROM orders o, |", []string{"customers"}, []string{"COUNT", "status"}},
			{"SELECT | FROM orders o", []string{"status", "total", "COUNT"}, []string{"orders", "customers", "secret_only"}},
			{"SELECT total AS revenue FROM orders WHERE |", []string{"status", "total"}, []string{"revenue", "orders", "secret_only", "SELECT"}},
			{"SELECT total AS revenue FROM orders ORDER BY |", []string{"revenue", "total", "DESC"}, []string{"orders", "secret_only"}},
			{"SELECT total AS revenue FROM orders GROUP BY |", []string{"revenue", "total"}, []string{"orders", "secret_only"}},
			{"SELECT * FROM orders ORDER |", []string{"BY"}, []string{"COUNT", "status"}},
			{"SELECT * FROM orders WHERE total IS |", []string{"NULL", "NOT"}, []string{"COUNT", "total"}},
			{"UPDATE orders SET |", []string{"total", "status"}, []string{"customers", "COUNT"}},
			{"SELECT * FROM orders o JOIN customers c USING (|)", []string{"id", "tenant_id"}, []string{"name", "status"}},
			{"SELECT * FROM orders o JOIN customers c |", []string{"ON", "USING"}, []string{"COUNT", "status"}},
		} {
			t.Run(engine+"/"+check.sql, func(t *testing.T) {
				items := suggestions(t, check.sql, fixture(engine))
				for _, label := range check.yes {
					if _, ok := itemWithLabel(items, label); !ok {
						t.Errorf("missing %s", label)
					}
				}
				for _, label := range check.no {
					if item, ok := itemWithLabel(items, label); ok && !(label == "orders" && item.Kind == 6) {
						t.Errorf("unexpected %s", label)
					}
				}
			})
		}
		having := suggestions(t, "SELECT total AS revenue FROM orders HAVING rev|", fixture(engine))
		_, ok := itemWithLabel(having, "revenue")
		if ok != (engine == "mysql") {
			t.Fatal("SELECT alias visibility does not follow dialect")
		}
	}
}

func TestCTEAndSubqueryScopes(t *testing.T) {
	for _, engine := range []string{"postgresql", "mysql"} {
		for _, check := range []struct {
			sql     string
			yes, no []string
		}{
			{"WITH recent AS (SELECT id AS order_id,total FROM orders) SELECT r.| FROM recent r", []string{"order_id", "total"}, []string{"id", "status"}},
			{"WITH recent(order_id,amount) AS (SELECT id,total FROM orders) SELECT r.| FROM recent r", []string{"order_id", "amount"}, []string{"id", "total"}},
			{"WITH first AS (SELECT * FROM orders), second AS (SELECT total AS amount FROM first) SELECT s.| FROM second s", []string{"amount"}, []string{"status", "total"}},
			{"WITH recent AS (SELECT o.* FROM orders o) SELECT r.| FROM recent r", []string{"status", "customer_id"}, []string{"secret_only"}},
			{"WITH orders AS (SELECT name AS customer_name FROM customers) SELECT o.| FROM orders o", []string{"customer_name"}, []string{"status", "total"}},
			{"WITH earlier AS (SELECT * FROM |), later AS (SELECT * FROM orders) SELECT * FROM earlier", []string{"orders"}, []string{"later", "earlier"}},
			{"SELECT d.| FROM (SELECT id AS order_id,total FROM orders) AS d", []string{"order_id", "total"}, []string{"id", "status"}},
			{"SELECT d.| FROM (SELECT id,total FROM orders) AS d(order_id,amount)", []string{"order_id", "amount"}, []string{"id", "total"}},
			{"SELECT | FROM orders o WHERE EXISTS (SELECT * FROM secret s WHERE s.secret_only=o.id)", []string{"status", "total"}, []string{"s", "secret_only"}},
			{"SELECT * FROM orders o WHERE EXISTS (SELECT o.| FROM customers c)", []string{"status", "total"}, []string{"name", "secret_only"}},
			{"SELECT * FROM orders o WHERE EXISTS (SELECT o.| FROM customers o)", []string{"name"}, []string{"status", "total"}},
			{"SELECT * FROM orders o, LATERAL (SELECT o.|) d", []string{"status", "total"}, []string{"secret_only"}},
			{"SELECT * FROM orders o, (SELECT o.|) d", nil, []string{"status", "total"}},
			{"SELECT * FROM orders o JOIN LATERAL (SELECT c.|) d ON true JOIN customers c ON true", nil, []string{"name"}},
			{"SELECT * FROM orders o WHERE EXISTS (WITH local AS (SELECT * FROM secret) SELECT * FROM local); SELECT * FROM |", []string{"orders"}, []string{"local", "o"}},
			{"SELECT * FROM orders o UNION ALL SELECT c.| FROM customers c", []string{"name"}, []string{"status", "total"}},
			{"SELECT * FROM orders o UNION ALL SELECT * FROM customers c WHERE |", []string{"name"}, []string{"status", "total"}},
			{"SELECT id AS result_id FROM orders UNION ALL SELECT id AS other_id FROM customers ORDER BY |", []string{"result_id"}, []string{"other_id", "status", "name"}},
			{"WITH RECURSIVE tree(node_id) AS (SELECT id FROM nodes UNION ALL SELECT t.| FROM tree t) SELECT * FROM tree", []string{"node_id"}, []string{"parent_id"}},
			{"WITH RECURSIVE tree AS (SELECT id,parent_id FROM nodes UNION ALL SELECT t.| FROM tree t) SELECT * FROM tree", []string{"id", "parent_id"}, nil},
			{"WITH recent AS (SELECT o.| FROM orders o", []string{"status", "total"}, []string{"secret_only"}},
			{"WITH recent AS (SELECT * FROM orders WHERE    |", []string{"status", "total"}, []string{"secret_only"}},
		} {
			t.Run(engine+"/"+check.sql, func(t *testing.T) {
				items := suggestions(t, check.sql, fixture(engine))
				for _, label := range check.yes {
					if _, ok := itemWithLabel(items, label); !ok {
						t.Errorf("missing %s", label)
					}
				}
				for _, label := range check.no {
					if _, ok := itemWithLabel(items, label); ok {
						t.Errorf("scope leaked %s", label)
					}
				}
			})
		}
	}
}

func TestForeignKeyJoinTablesAndConditions(t *testing.T) {
	for _, engine := range []string{"postgresql", "mysql"} {
		context := fixture(engine)
		q := func(name string) string { return quoteIdentifier(name, engine) }
		for _, sql := range []string{"SELECT * FROM orders o JOIN cust|", "SELECT * FROM orders o LEFT JOIN cust|", "SELECT * FROM orders o JOIN public.cust|"} {
			items := suggestions(t, sql, context)
			found := false
			for _, item := range items {
				if item.Kind != 15 {
					continue
				}
				found = true
				expected := q("public") + "." + q("customers")
				if strings.Contains(sql, "JOIN public.") {
					expected = q("customers")
				}
				expected += " AS " + q("c") + " ON " + q("o") + "." + q("tenant_id") + " = " + q("c") + "." + q("tenant_id") + " AND " + q("o") + "." + q("customer_id") + " = " + q("c") + "." + q("id")
				if item.InsertText != expected {
					t.Fatalf("wrong composite JOIN: %s", item.InsertText)
				}
			}
			if !found || items[0].Kind != 15 {
				t.Fatal("FK JOIN was missing or ranked below plain tables")
			}
		}
		reverse := suggestions(t, "SELECT * FROM customers c JOIN ord|", context)
		if len(reverse) == 0 || reverse[0].Kind != 15 || !strings.Contains(reverse[0].InsertText, q("o")+"."+q("customer_id")+" = "+q("c")+"."+q("id")) {
			t.Fatal("reverse JOIN missing")
		}
		conditions := suggestions(t, "SELECT * FROM orders o JOIN customers c ON |", context)
		if len(conditions) == 0 || conditions[0].Kind != 15 || !strings.Contains(conditions[0].InsertText, " AND ") {
			t.Fatal("ON did not offer the composite FK predicate")
		}
		conditions = suggestions(t, "SELECT * FROM orders o JOIN customers c ON o|", context)
		if len(conditions) == 0 || conditions[0].Kind != 15 || !strings.HasPrefix(conditions[0].Label, "o.") {
			t.Fatal("ON prefix did not match the readable FK condition")
		}
		self := suggestions(t, "SELECT * FROM nodes n JOIN nod|", context)
		count := 0
		for _, item := range self {
			if item.Kind == 15 {
				count++
				if !strings.Contains(item.InsertText, " AS "+q("n2")+" ON ") {
					t.Fatal("self JOIN alias collided")
				}
			}
		}
		if count != 2 {
			t.Fatal("self JOIN must offer parent and child directions")
		}
		for _, sql := range []string{"SELECT * FROM orders o CROSS JOIN cust|", "SELECT * FROM orders o NATURAL JOIN cust|", "SELECT * FROM orders o JOIN cust| c ON c.id=o.customer_id", "SELECT * FROM cust|"} {
			for _, item := range suggestions(t, sql, context) {
				if item.Kind == 15 {
					t.Fatal("offered JOIN in an incompatible context")
				}
			}
		}
	}
}

func TestAmbiguousColumnsAreQualifiedAndAliasesHideTableNames(t *testing.T) {
	items := suggestions(t, "SELECT i| FROM orders o JOIN customers c ON true", fixture("postgresql"))
	insertions := map[string]bool{}
	for _, item := range items {
		if item.Label == "id" {
			insertions[item.InsertText] = true
		}
	}
	if !insertions[`"o"."id"`] || !insertions[`"c"."id"`] || insertions[`"id"`] {
		t.Fatal("ambiguous columns were inserted without qualification")
	}
	if items := suggestions(t, "SELECT orders.| FROM orders o", fixture("postgresql")); len(items) != 0 {
		t.Fatal("an alias did not hide the original table name")
	}
}

func TestCompletionBoundsMalformedInputAndQuotedKeywords(t *testing.T) {
	context := fixture("postgresql")
	for _, sql := range []string{strings.Repeat("(", 2000) + "SELECT |", "WITH x AS (WITH y AS (SELECT 1 AS id) SELECT * FROM y) SELECT x.| FROM x", "SELECT \"FROM\" FROM orders WHERE |"} {
		_ = suggestions(t, sql, context)
	}
	if len(Complete("SELECT", -1, context)) != 0 || len(Complete("SELECT", 100, context)) != 0 || len(Complete("😀", 1, context)) != 0 {
		t.Fatal("invalid byte offset accepted")
	}
}

func TestIdentifierCaseInDerivedOutputsAndJoinAliases(t *testing.T) {
	context := fixture("postgresql")
	for _, sql := range []string{"WITH Mixed AS (SELECT id AS Renamed FROM orders) SELECT m.| FROM mixed m", "SELECT d.| FROM (SELECT id AS Renamed FROM orders) d"} {
		items := suggestions(t, sql, context)
		if item, ok := itemWithLabel(items, "renamed"); !ok || item.InsertText != `"renamed"` {
			t.Fatal("unquoted projected name was not folded")
		}
	}
	items := suggestions(t, "WITH Mixed AS (SELECT id FROM orders) SELECT * FROM mix|", context)
	if item, ok := itemWithLabel(items, "Mixed"); !ok || item.InsertText != `"mixed"` {
		t.Fatal("CTE insertion quoted the wrong case")
	}
	items = suggestions(t, "SELECT * FROM orders O JOIN cust|", context)
	if len(items) == 0 || !strings.Contains(items[0].InsertText, `"o"."customer_id"`) {
		t.Fatal("JOIN quoted an unquoted alias with incorrect case")
	}
	items = suggestions(t, "SELECT |FROM orders", context)
	if item, ok := itemWithLabel(items, "status"); !ok || item.Start != item.End {
		t.Fatal("empty prefix consumed the following keyword")
	}
}

func TestQuotedPunctuationDoesNotChangeTheQueryStructure(t *testing.T) {
	context := Context{Engine: "postgresql", Catalog: []Relation{
		{Schema: "public", Name: "(", Kind: "table", Columns: []string{")", ",", "FROM", "*", "."}},
		{Schema: "public", Name: ",", Kind: "table", Columns: []string{"other"}},
	}}
	for _, sql := range []string{`SELECT t.| FROM "(" t`, `WITH c AS (SELECT t.* FROM "(" t) SELECT c.| FROM c`} {
		items := suggestions(t, sql, context)
		for _, name := range context.Catalog[0].Columns {
			if _, ok := itemWithLabel(items, name); !ok {
				t.Fatal("quoted punctuation changed the source scope")
			}
		}
	}
	items := suggestions(t, `SELECT t.| FROM "," t`, context)
	if _, ok := itemWithLabel(items, "other"); !ok {
		t.Fatal("quoted comma was treated as a FROM separator")
	}
}

func FuzzCompletionNeverPanics(f *testing.F) {
	for _, sql := range []string{"SELECT * FROM orders o JOIN ", "WITH x AS (SELECT id FROM orders) SELECT x.", "SELECT * FROM (SELECT 1 AS id) d WHERE EXISTS (SELECT d.)", "WITH RECURSIVE t(id) AS (SELECT 1 UNION ALL SELECT id FROM t) SELECT * FROM t", "SELECT NULLIF(ROUND(1,2), ", "SELECT COALESCE(ARRAY[1,2], 'a,b', "} {
		f.Add(sql, uint16(len(sql)))
	}
	f.Fuzz(func(t *testing.T, sql string, offset uint16) {
		if len(sql) > 8192 {
			return
		}
		for _, engine := range []string{"postgresql", "mysql"} {
			items := Complete(sql, int(offset)%(len(sql)+1), fixture(engine))
			for _, item := range items {
				if item.Start < 0 || item.End < item.Start || item.End > len(sql) {
					t.Fatal("replacement escaped the document")
				}
				previous := 0
				for _, span := range item.Matches {
					if span.Start < previous || span.End <= span.Start || span.End > len(item.Label) ||
						!utf8.ValidString(item.Label[:span.Start]) || !utf8.ValidString(item.Label[span.Start:span.End]) {
						t.Fatal("match span escaped its label or split a code point")
					}
					previous = span.End
				}
			}
			if help := Signatures(sql, int(offset)%(len(sql)+1), fixture(engine)); help != nil {
				if help.ActiveSignature < 0 || help.ActiveSignature >= len(help.Signatures) {
					t.Fatal("invalid active signature")
				}
				for _, signature := range help.Signatures {
					for _, span := range signature.Parameters {
						if span.Start < 0 || span.End < span.Start || span.End > len(signature.Label) {
							t.Fatal("invalid signature parameter range")
						}
					}
				}
			}
		}
	})
}
