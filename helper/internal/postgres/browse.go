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
	var where, sourceWhere []string
	var values [][]byte
	operators := map[string]string{"eq": "=", "ne": "<>", "lt": "<", "lte": "<=", "gt": ">", "gte": ">="}
	for _, filter := range request.Filters {
		column, ok := columns[filter.Column]
		if !ok {
			return browsePlan{}, errBrowse
		}
		quoted := pgx.Identifier{filter.Column}.Sanitize()
		if filter.Operator == "isNull" {
			where = append(where, quoted+" IS NULL")
			sourceWhere = append(sourceWhere, quoted+" IS NULL")
			continue
		}
		if filter.Operator == "isNotNull" {
			where = append(where, quoted+" IS NOT NULL")
			sourceWhere = append(sourceWhere, quoted+" IS NOT NULL")
			continue
		}
		if filter.Value == nil {
			return browsePlan{}, errBrowse
		}
		value := *filter.Value
		cell := protocol.CellValue{Kind: "text", Value: filter.Value}
		if column.binary {
			cell.Kind = "binary"
			decoded, err := base64.StdEncoding.DecodeString(value)
			if err != nil {
				return browsePlan{}, errBrowse
			}
			value = `\x` + hex.EncodeToString(decoded)
		}
		literal, err := insertLiteral(cell)
		if err != nil {
			return browsePlan{}, errBrowse
		}
		values = append(values, []byte(value))
		parameter := "$" + strconv.Itoa(len(values))
		if filter.Operator == "contains" {
			if column.binary {
				where = append(where, "position("+parameter+"::bytea IN "+quoted+")>0")
				sourceWhere = append(sourceWhere, "position("+literal+"::bytea IN "+quoted+")>0")
			} else {
				where = append(where, "strpos("+quoted+"::text,"+parameter+"::text)>0")
				sourceWhere = append(sourceWhere, "strpos("+quoted+"::text,"+literal+"::text)>0")
			}
		} else if operator, ok := operators[filter.Operator]; ok {
			// Keep fractional and out-of-range operands exact instead of asking
			// PostgreSQL to parse them as the column's narrower integer type.
			if column.numeric {
				parameter += "::numeric"
				literal += "::numeric"
			}
			where = append(where, quoted+" "+operator+" "+parameter)
			sourceWhere = append(sourceWhere, quoted+" "+operator+" "+literal)
		} else {
			return browsePlan{}, errBrowse
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
