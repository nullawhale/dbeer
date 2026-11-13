package postgres

import (
	sc "dbeer/helper/internal/schemacompare"
	"strings"
)

const unavailableCatalogExpression = "\x01catalog:"

// Deparsers can call user type output/typmod routines. Structure observations
// retain opaque trees for those types instead of invoking their support code.
func (r *schemaCapture) expressionProjection(node, relation string) string {
	deparse := "COALESCE(pg_catalog.pg_get_expr(" + node + "," + relation + ",false),'')"
	if !r.skipCustomTypeFormatting {
		return deparse
	}
	unsafe := `EXISTS(WITH RECURSIVE expression_types AS (
 SELECT et.oid,et.typtype,et.typbasetype,et.typoutput,et.typmodout
 FROM pg_catalog.regexp_matches((` + node + `)::pg_catalog.text,':[[:alpha:]_]*[tT][yY][pP][eE][[:alpha:]_]*[[:space:]]+([0-9]+)','g') AS m
 JOIN pg_catalog.pg_type et ON et.oid=(m[1])::pg_catalog.oid
 UNION SELECT b.oid,b.typtype,b.typbasetype,b.typoutput,b.typmodout FROM expression_types d JOIN pg_catalog.pg_type b ON b.oid=d.typbasetype WHERE d.typtype='d'
 ) SELECT 1 FROM expression_types t WHERE t.typtype='p' OR t.typoutput>=16384 OR t.typmodout>=16384 OR (t.oid>=16384 AND t.typtype NOT IN ('e','d')))`
	return "CASE WHEN " + node + " IS NULL THEN '' WHEN " + unsafe + " THEN pg_catalog.chr(1)||'catalog:'||(" + node + ")::pg_catalog.text ELSE " + deparse + " END"
}

func (r *schemaCapture) unavailableExpression(text, class, oid string) (sc.Expression, bool) {
	if !r.skipCustomTypeFormatting || !strings.HasPrefix(text, unavailableCatalogExpression) {
		return sc.Expression{}, false
	}
	if r.rawExpressions == nil {
		r.rawExpressions = map[string]string{}
	}
	r.rawExpressions[class+":"+oid] = strings.TrimPrefix(text, unavailableCatalogExpression)
	return sc.Expression{Text: "/* expression metadata unavailable: custom type support */", Dependencies: sc.Collection[sc.Ref]{Items: []sc.Ref{}, State: "unavailable", Code: "customTypeSupport", Complete: false}}, true
}
