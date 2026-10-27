package sqlcomplete

import "strings"

var keywords = strings.Fields("SELECT FROM WHERE JOIN LEFT RIGHT INNER OUTER FULL CROSS NATURAL ON USING AS AND OR NOT NULL IS IN EXISTS BETWEEN LIKE DISTINCT GROUP BY ORDER ASC DESC LIMIT OFFSET HAVING UNION ALL EXCEPT INTERSECT INSERT INTO VALUES UPDATE SET DELETE RETURNING WITH RECURSIVE CREATE ALTER DROP TABLE VIEW CASE WHEN THEN ELSE END OVER PARTITION NULLS FIRST LAST TRUE FALSE LATERAL WINDOW FETCH FOR MATERIALIZED COLLATE")

func isKeyword(word string) bool {
	for _, keyword := range keywords {
		if strings.EqualFold(word, keyword) {
			return true
		}
	}
	return false
}

func quoteIdentifier(name, engine string) string {
	quote := "\""
	if engine == "mysql" {
		quote = "`"
	}
	return quote + strings.ReplaceAll(name, quote, quote+quote) + quote
}

func qualifiedName(relation Relation, engine string) string {
	name := quoteIdentifier(relation.Name, engine)
	if relation.Schema != "" {
		name = quoteIdentifier(relation.Schema, engine) + "." + name
	}
	return name
}

func functions(engine string) []string {
	if engine == "cassandra" {
		return cassandraFunctions()
	}
	names := strings.Fields("COUNT SUM AVG MIN MAX COALESCE NULLIF LOWER UPPER LENGTH SUBSTRING ROUND ABS")
	if engine == "mysql" {
		return append(names, strings.Fields("IFNULL CONCAT NOW DATE_FORMAT JSON_EXTRACT GROUP_CONCAT")...)
	}
	return append(names, strings.Fields("NOW CURRENT_DATE DATE_TRUNC STRING_AGG ARRAY_AGG JSONB_BUILD_OBJECT GENERATE_SERIES")...)
}

func word(t token, value string) bool {
	return t.kind == wordToken && strings.EqualFold(t.value, value)
}
func punct(t token, value string) bool { return t.kind == punctuationToken && t.value == value }
func identifier(t token) bool {
	if t.kind == quotedToken {
		return true
	}
	if t.kind != wordToken || t.value == "" || t.value[0] >= '0' && t.value[0] <= '9' {
		return false
	}
	// FIRST/LAST and other contextual words may be legal unquoted names.
	for _, reserved := range strings.Fields("SELECT FROM WHERE JOIN LEFT RIGHT INNER OUTER FULL CROSS NATURAL ON USING AS AND OR NOT NULL IS IN EXISTS BETWEEN LIKE DISTINCT GROUP BY ORDER ASC DESC LIMIT OFFSET HAVING UNION ALL EXCEPT INTERSECT INSERT INTO VALUES UPDATE SET DELETE RETURNING WITH RECURSIVE CREATE ALTER DROP TABLE VIEW CASE WHEN THEN ELSE END OVER PARTITION TRUE FALSE LATERAL WINDOW FETCH FOR") {
		if word(t, reserved) {
			return false
		}
	}
	return true
}
