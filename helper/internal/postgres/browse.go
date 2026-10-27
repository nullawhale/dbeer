package postgres

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"sort"
	"strconv"
	"strings"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
)

type browseColumn struct {
	name    string
	primary int
	binary  bool
	numeric bool
}

type browsePlan struct {
	statement         string
	values            [][]byte
	sourceSQL         string
	notice            string
	storageProjection bool
}

var errBrowse = errors.New("invalid PostgreSQL table browse request")

func browseSQL(ctx context.Context, conn *pgx.Conn, command protocol.Command) (browsePlan, *protocol.Response) {
	request := command.Catalog
	storageProjection := false
	rows, err := conn.Query(ctx, `SELECT a.attname::text,COALESCE((SELECT key.ordinality FROM pg_catalog.pg_index i CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY key(attnum,ordinality) WHERE i.indrelid=c.oid AND i.indisprimary AND key.attnum=a.attnum),0),`+postgresBinaryTypeSQL+`,a.atttypid IN (20,21,23,700,701,1700),c.relkind IN ('r','p')
FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace JOIN pg_catalog.pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
WHERE n.nspname::text=$1::text AND c.relname::text=$2::text ORDER BY a.attnum`, request.Schema, request.Object)
	if err != nil {
		response := queryError(command, ctx, conn, err)
		response.Message = "Table metadata is unavailable or access was denied."
		response.ErrorPosition = 0
		return browsePlan{}, &response
	}
	var columns []browseColumn
	for rows.Next() {
		var column browseColumn
		if rows.Scan(&column.name, &column.primary, &column.binary, &column.numeric, &storageProjection) != nil {
			rows.Close()
			response := protocol.ErrorResponse(command, "result", "Table metadata could not be decoded.")
			response.Connected, response.TransactionStatus = true, transactionStatus(conn)
			return browsePlan{}, &response
		}
		columns = append(columns, column)
	}
	rows.Close()
	if rows.Err() != nil {
		response := queryError(command, ctx, conn, rows.Err())
		response.Message = "Table metadata is unavailable or access was denied."
		response.ErrorPosition = 0
		return browsePlan{}, &response
	}
	plan, err := buildBrowsePlan(*request, columns)
	if err != nil {
		response := protocol.ErrorResponse(command, "protocol", "A requested table column or filter is unavailable.")
		response.Connected, response.TransactionStatus = true, transactionStatus(conn)
		return browsePlan{}, &response
	}
	if storageProjection {
		plan.statement = strings.Replace(plan.statement, "SELECT * FROM ", "SELECT *,"+postgresStorageProjection+" AS "+pgx.Identifier{postgresStorageAlias}.Sanitize()+" FROM ", 1)
		plan.storageProjection = true
	}
	return plan, nil
}

// The executed statement and its standalone source share one plan. Only bound
// operands differ; quoting uses the same lossless formatter as offline INSERTs.
func buildBrowsePlan(request protocol.CatalogRequest, metadata []browseColumn) (browsePlan, error) {
	columns := make(map[string]browseColumn, len(metadata))
	var primary []browseColumn
	for _, column := range metadata {
		columns[column.name] = column
		if column.primary > 0 {
			primary = append(primary, column)
		}
	}
	var order []string
	seen := make(map[string]bool)
	for _, item := range request.Sort {
		if _, ok := columns[item.Column]; !ok || seen[item.Column] || item.Direction != "asc" && item.Direction != "desc" {
			return browsePlan{}, errBrowse
		}
		seen[item.Column] = true
		order = append(order, pgx.Identifier{item.Column}.Sanitize()+" "+strings.ToUpper(item.Direction))
	}
	sort.Slice(primary, func(a, b int) bool { return primary[a].primary < primary[b].primary })
	for _, column := range primary {
		if !seen[column.name] {
			order = append(order, pgx.Identifier{column.name}.Sanitize()+" ASC")
		}
	}
	var values [][]byte
	compileCondition := func(filter protocol.CatalogFilter) (string, string, error) {
		column, ok := columns[filter.Column]
		if !ok {
			return "", "", errBrowse
		}
		quoted := pgx.Identifier{filter.Column}.Sanitize()
		if filter.Operator == "isNull" || filter.Operator == "isNotNull" {
			if filter.Value != nil {
				return "", "", errBrowse
			}
			predicate := quoted + " IS NULL"
			if filter.Operator == "isNotNull" {
				predicate = quoted + " IS NOT NULL"
			}
			return predicate, predicate, nil
		}
		if filter.Value == nil {
			return "", "", errBrowse
		}
		value := *filter.Value
		cell := protocol.CellValue{Kind: "text", Value: filter.Value}
		if column.binary {
			cell.Kind = "binary"
			decoded, err := base64.StdEncoding.DecodeString(value)
			if err != nil {
				return "", "", errBrowse
			}
			value = `\x` + hex.EncodeToString(decoded)
		}
		literal, err := insertLiteral(cell)
		if err != nil {
			return "", "", errBrowse
		}
		values = append(values, []byte(value))
		parameter := "$" + strconv.Itoa(len(values))
		if filter.Operator == "contains" {
			if column.binary {
				return "position(" + parameter + "::bytea IN " + quoted + ")>0", "position(" + literal + "::bytea IN " + quoted + ")>0", nil
			}
			return "strpos(" + quoted + "::text," + parameter + "::text)>0", "strpos(" + quoted + "::text," + literal + "::text)>0", nil
		}
		operator := map[string]string{"eq": "=", "ne": "<>", "lt": "<", "lte": "<=", "gt": ">", "gte": ">="}[filter.Operator]
		if operator == "" {
			return "", "", errBrowse
		}
		// Keep fractional and out-of-range operands exact instead of asking
		// PostgreSQL to parse them as the column's narrower integer type.
		if column.numeric {
			parameter += "::numeric"
			literal += "::numeric"
		}
		return quoted + " " + operator + " " + parameter, quoted + " " + operator + " " + literal, nil
	}
	if _, valid := request.EffectiveFilterExpression(); !valid {
		return browsePlan{}, errBrowse
	}
	var where, sourceWhere []string
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
				predicates = append(predicates, predicate)
				sources = append(sources, source)
			}
			separator := " " + strings.ToUpper(expression.Kind) + " "
			return "(" + strings.Join(predicates, separator) + ")", "(" + strings.Join(sources, separator) + ")", nil
		}
		predicate, source, err := compile(*request.FilterExpression)
		if err != nil {
			return browsePlan{}, err
		}
		where, sourceWhere = []string{predicate}, []string{source}
	} else {
		for _, filter := range request.Filters {
			predicate, source, err := compileCondition(filter)
			if err != nil {
				return browsePlan{}, err
			}
			where, sourceWhere = append(where, predicate), append(sourceWhere, source)
		}
	}
	statement := func(predicates []string) string {
		sql := "SELECT * FROM " + pgx.Identifier{request.Schema, request.Object}.Sanitize()
		if len(predicates) > 0 {
			sql += " WHERE " + strings.Join(predicates, " AND ")
		}
		if len(order) > 0 {
			sql += " ORDER BY " + strings.Join(order, ",")
		}
		return sql + " LIMIT 200 OFFSET " + strconv.Itoa(request.Page*200)
	}
	sourceSQL := statement(sourceWhere)
	notice := ""
	if len(primary) == 0 {
		notice = "This object has no primary key. No stable page order is guaranteed, even when data is unchanged; rows may repeat or be skipped between pages."
	}
	return browsePlan{statement: statement(where), values: values, sourceSQL: sourceSQL, notice: notice}, nil
}
