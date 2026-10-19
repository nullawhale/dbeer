package postgres

import (
	"context"
	"encoding/base64"
	"encoding/hex"
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
}

func browseSQL(ctx context.Context, conn *pgx.Conn, command protocol.Command) (string, [][]byte, string, *protocol.Response) {
	request := command.Catalog
	rows, err := conn.Query(ctx, `SELECT a.attname::text,COALESCE((SELECT key.ordinality FROM pg_catalog.pg_index i CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY key(attnum,ordinality) WHERE i.indrelid=c.oid AND i.indisprimary AND key.attnum=a.attnum),0),a.atttypid=17
FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace JOIN pg_catalog.pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
WHERE n.nspname::text=$1::text AND c.relname::text=$2::text ORDER BY a.attnum`, request.Schema, request.Object)
	if err != nil {
		response := queryError(command, ctx, conn, err)
		response.Message = "Table metadata is unavailable or access was denied."
		response.ErrorPosition = 0
		return "", nil, "", &response
	}
	columns := make(map[string]browseColumn)
	var primary []browseColumn
	for rows.Next() {
		var column browseColumn
		if rows.Scan(&column.name, &column.primary, &column.binary) != nil {
			rows.Close()
			response := protocol.ErrorResponse(command, "result", "Table metadata could not be decoded.")
			response.Connected, response.TransactionStatus = true, transactionStatus(conn)
			return "", nil, "", &response
		}
		columns[column.name] = column
		if column.primary > 0 {
			primary = append(primary, column)
		}
	}
	rows.Close()
	if rows.Err() != nil {
		response := queryError(command, ctx, conn, rows.Err())
		response.Message = "Table metadata is unavailable or access was denied."
		response.ErrorPosition = 0
		return "", nil, "", &response
	}
	invalid := func() *protocol.Response {
		response := protocol.ErrorResponse(command, "protocol", "A requested table column or filter is unavailable.")
		response.Connected, response.TransactionStatus = true, transactionStatus(conn)
		return &response
	}
	var order []string
	seen := make(map[string]bool)
	for _, item := range request.Sort {
		if _, ok := columns[item.Column]; !ok || seen[item.Column] {
			return "", nil, "", invalid()
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
	var where []string
	var values [][]byte
	operators := map[string]string{"eq": "=", "ne": "<>", "lt": "<", "lte": "<=", "gt": ">", "gte": ">="}
	for _, filter := range request.Filters {
		column, ok := columns[filter.Column]
		if !ok {
			return "", nil, "", invalid()
		}
		quoted := pgx.Identifier{filter.Column}.Sanitize()
		if filter.Operator == "isNull" {
			where = append(where, quoted+" IS NULL")
			continue
		}
		if filter.Operator == "isNotNull" {
			where = append(where, quoted+" IS NOT NULL")
			continue
		}
		if filter.Value == nil {
			return "", nil, "", invalid()
		}
		value := *filter.Value
		if column.binary {
			decoded, err := base64.StdEncoding.DecodeString(value)
			if err != nil {
				return "", nil, "", invalid()
			}
			value = `\x` + hex.EncodeToString(decoded)
		}
		values = append(values, []byte(value))
		parameter := "$" + strconv.Itoa(len(values))
		if filter.Operator == "contains" {
			if column.binary {
				where = append(where, "position("+parameter+"::bytea IN "+quoted+")>0")
			} else {
				where = append(where, "strpos("+quoted+"::text,"+parameter+"::text)>0")
			}
		} else if operator, ok := operators[filter.Operator]; ok {
			where = append(where, quoted+" "+operator+" "+parameter)
		} else {
			return "", nil, "", invalid()
		}
	}
	sql := "SELECT * FROM " + pgx.Identifier{request.Schema, request.Object}.Sanitize()
	if len(where) > 0 {
		sql += " WHERE " + strings.Join(where, " AND ")
	}
	if len(order) > 0 {
		sql += " ORDER BY " + strings.Join(order, ",")
	}
	sql += " LIMIT 200 OFFSET " + strconv.Itoa(request.Page*200)
	notice := ""
	if len(primary) == 0 {
		notice = "This object has no primary key. Rows can move between pages when data changes."
	}
	return sql, values, notice, nil
}
