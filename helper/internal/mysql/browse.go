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
	var predicates, sourcePredicates []string
	var args []any
	for _, filter := range request.Filters {
		kind, ok := actual[filter.Column]
		if !ok {
			return browsePlan{}, invalidSettings("Unknown MySQL filter column.")
		}
		column := QuoteIdentifier(filter.Column)
		switch filter.Operator {
		case "isNull":
			predicates = append(predicates, column+" IS NULL")
			sourcePredicates = append(sourcePredicates, column+" IS NULL")
		case "isNotNull":
			predicates = append(predicates, column+" IS NOT NULL")
			sourcePredicates = append(sourcePredicates, column+" IS NOT NULL")
		default:
			if filter.Value == nil {
				return browsePlan{}, invalidSettings("A MySQL filter value is missing.")
			}
			cell := protocol.CellValue{Kind: "text", Value: filter.Value}
			var value any = *filter.Value
			if binaryType(kind) {
				decoded, err := base64.StdEncoding.DecodeString(*filter.Value)
				if err != nil {
					return browsePlan{}, invalidSettings("MySQL binary filter values must use base64.")
				}
				value = decoded
				cell.Kind = "binary"
			}
			if spatialType(kind) || kind == "vector" {
				column = "UNHEX(HEX(" + column + "))"
			}
			literal, err := insertLiteral(cell)
			if err != nil {
				return browsePlan{}, invalidSettings("A MySQL filter value is invalid.")
			}
			if filter.Operator == "contains" {
				predicates = append(predicates, "LOCATE(?, "+column+") > 0")
				sourcePredicates = append(sourcePredicates, "LOCATE("+literal+", "+column+") > 0")
			} else {
				parameter, canonical, err := browseNumericParameter(kind, *filter.Value)
				if err != nil {
					return browsePlan{}, err
				}
				if parameter != "?" {
					value = canonical
					literal, _ = insertLiteral(protocol.CellValue{Kind: "text", Value: &canonical})
				}
				operator := map[string]string{"eq": "=", "ne": "<>", "lt": "<", "lte": "<=", "gt": ">", "gte": ">="}[filter.Operator]
				if operator == "" {
					return browsePlan{}, invalidSettings("Unknown MySQL filter operator.")
				}
				predicates = append(predicates, column+" "+operator+" "+parameter)
				sourcePredicates = append(sourcePredicates, column+" "+operator+" "+strings.Replace(parameter, "?", literal, 1))
			}
			args = append(args, value)
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
