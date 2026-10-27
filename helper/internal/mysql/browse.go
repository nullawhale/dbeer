package mysql

import (
	"encoding/base64"
	"strconv"
	"strings"

	"dbeer/helper/internal/protocol"
)

type browsePlan struct {
	statement      string
	args           []any
	storageColumns []string
	sourceSQL      string
}

// The executed statement and its standalone source share one plan. Only bound
// operands differ; text and binary quoting reuse the offline INSERT formatter.
func buildBrowsePlan(request protocol.CatalogRequest, actual map[string]string, primaryKey []string, columnOrders ...[]string) (browsePlan, error) {
	storageColumns := mysqlBrowseStorageColumns(actual)
	visibleProjection := "*"
	canonical := false
	for _, kind := range actual {
		canonical = canonical || kind == "float" || kind == "double" || kind == "timestamp"
	}
	if canonical && len(columnOrders) > 0 {
		columns := []string{}
		for _, name := range columnOrders[0] {
			expression := mysqlStableProjection(name, actual[name])
			if expression != QuoteIdentifier(name) {
				expression += " AS " + QuoteIdentifier(name)
			}
			columns = append(columns, expression)
		}
		visibleProjection = strings.Join(columns, ", ")
	}
	var order []string
	seen := map[string]bool{}
	for _, sort := range request.Sort {
		if _, ok := actual[sort.Column]; !ok || seen[sort.Column] || sort.Direction != "asc" && sort.Direction != "desc" {
			return browsePlan{}, invalidSettings("Unknown or repeated MySQL sort column.")
		}
		seen[sort.Column] = true
		order = append(order, QuoteIdentifier(sort.Column)+" "+strings.ToUpper(sort.Direction))
	}
	for _, name := range primaryKey {
		if !seen[name] {
			order = append(order, QuoteIdentifier(name))
			seen[name] = true
		}
	}
	var args []any
	compileCondition := func(filter protocol.CatalogFilter) (string, string, error) {
		kind, ok := actual[filter.Column]
		if !ok {
			return "", "", invalidSettings("Unknown MySQL filter column.")
		}
		column := QuoteIdentifier(filter.Column)
		if filter.Operator == "isNull" || filter.Operator == "isNotNull" {
			if filter.Value != nil {
				return "", "", invalidSettings("A MySQL NULL filter cannot have a value.")
			}
			predicate := column + " IS NULL"
			if filter.Operator == "isNotNull" {
				predicate = column + " IS NOT NULL"
			}
			return predicate, predicate, nil
		}
		if filter.Value == nil {
			return "", "", invalidSettings("A MySQL filter value is missing.")
		}
		cell := protocol.CellValue{Kind: "text", Value: filter.Value}
		var value any = *filter.Value
		if binaryType(kind) {
			decoded, err := base64.StdEncoding.DecodeString(*filter.Value)
			if err != nil {
				return "", "", invalidSettings("MySQL binary filter values must use base64.")
			}
			value, cell.Kind = decoded, "binary"
		}
		if spatialType(kind) || kind == "vector" {
			column = "UNHEX(HEX(" + column + "))"
		}
		literal, err := insertLiteral(cell)
		if err != nil {
			return "", "", invalidSettings("A MySQL filter value is invalid.")
		}
		var predicate, source string
		if filter.Operator == "contains" {
			predicate, source = "LOCATE(?, "+column+") > 0", "LOCATE("+literal+", "+column+") > 0"
		} else {
			parameter, canonical, err := browseNumericParameter(kind, *filter.Value)
			if err != nil {
				return "", "", err
			}
			if parameter != "?" {
				value = canonical
				literal, _ = insertLiteral(protocol.CellValue{Kind: "text", Value: &canonical})
			}
			operator := map[string]string{"eq": "=", "ne": "<>", "lt": "<", "lte": "<=", "gt": ">", "gte": ">="}[filter.Operator]
			if operator == "" {
				return "", "", invalidSettings("Unknown MySQL filter operator.")
			}
			predicate, source = column+" "+operator+" "+parameter, column+" "+operator+" "+strings.Replace(parameter, "?", literal, 1)
		}
		args = append(args, value)
		return predicate, source, nil
	}
	if _, valid := request.EffectiveFilterExpression(); !valid {
		return browsePlan{}, invalidSettings("Invalid MySQL filter expression.")
	}
	var predicates, sourcePredicates []string
	if request.FilterExpression != nil {
		var compile func(protocol.CatalogFilterExpression) (string, string, error)
		compile = func(expression protocol.CatalogFilterExpression) (string, string, error) {
			if expression.Kind == "condition" {
				return compileCondition(*expression.Condition)
			}
			var predicates, sources []string
			for _, child := range expression.Children {
				predicate, source, err := compile(child)
				if err != nil {
					return "", "", err
				}
				predicates, sources = append(predicates, predicate), append(sources, source)
			}
			separator := " " + strings.ToUpper(expression.Kind) + " "
			return "(" + strings.Join(predicates, separator) + ")", "(" + strings.Join(sources, separator) + ")", nil
		}
		predicate, source, err := compile(*request.FilterExpression)
		if err != nil {
			return browsePlan{}, err
		}
		predicates, sourcePredicates = []string{predicate}, []string{source}
	} else {
		for _, filter := range request.Filters {
			predicate, source, err := compileCondition(filter)
			if err != nil {
				return browsePlan{}, err
			}
			predicates, sourcePredicates = append(predicates, predicate), append(sourcePredicates, source)
		}
	}
	statement := func(predicates []string) string {
		projection := visibleProjection
		if len(storageColumns) > 0 {
			projection += ", " + strings.Join(mysqlStorageProjections(storageColumns, actual), ", ")
		}
		query := "SELECT " + projection + " FROM " + QuoteIdentifier(request.Schema) + "." + QuoteIdentifier(request.Object)
		if len(predicates) > 0 {
			query += " WHERE " + strings.Join(predicates, " AND ")
		}
		if len(order) > 0 {
			query += " ORDER BY " + strings.Join(order, ", ")
		}
		query += " LIMIT 200"
		if request.Page > 0 {
			query += " OFFSET " + strconv.Itoa(request.Page*200)
		}
		return query
	}
	sourceSQL := statement(sourcePredicates)
	// Copy SQL is the user's visible query, without transport-only ordinals.
	if len(storageColumns) > 0 {
		sourceSQL = strings.Replace(sourceSQL, "SELECT "+visibleProjection+", "+strings.Join(mysqlStorageProjections(storageColumns, actual), ", "), "SELECT "+visibleProjection, 1)
	}
	return browsePlan{statement: statement(predicates), args: args, sourceSQL: sourceSQL, storageColumns: storageColumns}, nil
}
