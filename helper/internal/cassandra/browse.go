package cassandra

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math/big"
	"strconv"
	"strings"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	gocql "github.com/apache/cassandra-gocql-driver/v2"
)

type browseCursor struct {
	signature, schema string
	page              []byte
	skip              int
	expires           time.Time
}

func (s *Session) browse(ctx context.Context, command protocol.Command, sink adapter.ResultSink) protocol.Response {
	request := *command.Catalog
	if request.Page != 0 {
		return s.failure(command, "unsupported", "Cassandra browsing uses sequential cursors rather than page offsets.")
	}
	if expression, valid := request.EffectiveFilterExpression(); !valid {
		return s.failure(command, "validation", "The Cassandra browse filter is invalid.")
	} else if expression != nil {
		if _, ok := expression.FlattenAND(); !ok {
			return s.failure(command, "unsupported", "Cassandra browsing supports AND conditions only. OR groups are unavailable.")
		}
	}
	columns, failure := s.tableColumns(ctx, command, request.Schema, request.Object)
	if failure != nil {
		return *failure
	}
	if len(columns) == 0 {
		return s.failure(command, "sql", "The Cassandra table or materialized view is unavailable.")
	}
	sql, values, err := browseStatement(request, columns)
	if errors.Is(err, errBrowseType) {
		return s.failure(command, "unsupported", "Generated Cassandra filters support scalar values only. Use explicit CQL to filter tuple, user-defined, collection, frozen, or vector keys.")
	}
	if err != nil {
		return s.failure(command, "unsupported", "Cassandra filters require a complete partition key with an ordered clustering-key prefix, or one indexed equality. Sorting requires a complete partition key and clustering columns. No ALLOW FILTERING is added.")
	}
	version, failure := s.metadata(ctx, command, "SELECT schema_version FROM system.local")
	if failure != nil {
		return *failure
	}
	schema := schemaFingerprint(columns)
	if len(version) > 0 {
		schema += "/" + version[0]["schema_version"]
	}
	encoded, _ := json.Marshal(struct {
		SQL      string
		Values   []any
		Keyspace string
	}{sql, values, s.keyspace})
	sum := sha256.Sum256(encoded)
	signature := hex.EncodeToString(sum[:])
	var page []byte
	skip := 0
	if request.Cursor != "" {
		cursor, ok := s.cursors[request.Cursor]
		delete(s.cursors, request.Cursor)
		if !ok || cursor.signature != signature || cursor.schema != schema || time.Now().After(cursor.expires) {
			s.cursors = make(map[string]browseCursor)
			return s.failure(command, "cursor", "This Cassandra page cursor expired or no longer matches the table, filters, sort, or schema. Refresh the first page.")
		}
		page, skip = cursor.page, cursor.skip
	} else {
		s.cursors = make(map[string]browseCursor)
	}
	result, next, nextSkip, failure := s.query(ctx, command, sql, values, 0, sink, &displayBudget{}, false, true, page, skip, false)
	if failure != nil {
		return *failure
	}
	if len(next) > 0 || nextSkip > 0 {
		if len(next) > 64*1024 {
			return s.failure(command, "result", "Cassandra returned an oversized page cursor.")
		}
		// A page whose first value exceeds the display budget cannot advance safely.
		if result.DisplayedRowCount == 0 && nextSkip == skip {
			result.DisplayNotice = "A Cassandra row exceeds the display limit. Use explicit export to read the full result."
		} else {
			var token [24]byte
			if _, err := rand.Read(token[:]); err != nil {
				return s.failure(command, "cursor", "A Cassandra page cursor could not be created.")
			}
			result.NextCursor = hex.EncodeToString(token[:])
			if s.cursors == nil {
				s.cursors = make(map[string]browseCursor)
			}
			for key, cursor := range s.cursors {
				if time.Now().After(cursor.expires) {
					delete(s.cursors, key)
				}
			}
			if len(s.cursors) >= 16 {
				s.cursors = make(map[string]browseCursor)
			}
			s.cursors[result.NextCursor] = browseCursor{signature: signature, schema: schema, page: append([]byte(nil), next...), skip: nextSkip, expires: time.Now().Add(5 * time.Minute)}
		}
	}
	notice := "Cassandra pages are sequential and do not provide a snapshot or a global row order."
	if result.DisplayNotice != "" {
		notice = result.DisplayNotice + " " + notice
	}
	if request.Cursor != "" {
		notice += " This page uses a cursor that is not encoded in source CQL. Rerunning the CQL starts a fresh read rather than returning this page."
	}
	sourceSQL, _, sourceErr := buildBrowseStatement(request, columns, true)
	if sourceErr != nil {
		notice += " The source CQL could not be captured for this page."
	}
	result.DisplayNotice = notice
	if sink != nil {
		_ = sink.End(0, result)
	}
	response := s.response(command)
	response.Columns = result.Columns
	response.Rows = result.Rows
	response.RowCount = result.RowCount
	response.DisplayedRowCount = result.DisplayedRowCount
	response.Truncated = result.Truncated
	response.NextCursor = result.NextCursor
	response.DisplayNotice = result.DisplayNotice
	response.CommandTag = "SELECT"
	response.ResultSets = []protocol.ResultSet{result}
	return response.WithReadSQL(sourceSQL)
}

var errBrowse = errors.New("unsupported Cassandra browse condition")
var errBrowseType = errors.New("unsupported Cassandra generated-filter type")

// Complex values remain lossless in execution/display/export. Generated text
// parameters intentionally support only the native scalar types below; frozen
// and user-defined spellings must not silently fall through to driver errors.
func browseScalarType(nativeType string) bool {
	switch strings.ToLower(strings.TrimSpace(nativeType)) {
	case "ascii", "text", "varchar", "int", "bigint", "smallint", "tinyint", "counter", "uuid", "timeuuid", "inet", "date", "duration", "blob", "boolean", "varint", "decimal", "float", "double", "timestamp", "time":
		return true
	default:
		return false
	}
}

func browseStatement(request protocol.CatalogRequest, columns []tableColumn) (string, []any, error) {
	return buildBrowseStatement(request, columns, false)
}

// Standalone source uses the same validated key and ordering plan as execution.
// Render values through the driver's scalar conversion and the lossless CQL
// formatter, preserving exact decimals, binary keys and temporal values.
func buildBrowseStatement(request protocol.CatalogRequest, columns []tableColumn, source bool) (string, []any, error) {
	expression, valid := request.EffectiveFilterExpression()
	if !valid {
		return "", nil, errBrowse
	}
	if expression != nil {
		filters, ok := expression.FlattenAND()
		if !ok {
			return "", nil, errBrowse
		}
		request.Filters = filters
		request.FilterExpression = nil
	}
	byName := map[string]tableColumn{}
	var partition, clustering []tableColumn
	for _, column := range columns {
		byName[column.name] = column
		switch column.kind {
		case "partition_key":
			partition = append(partition, column)
		case "clustering":
			clustering = append(clustering, column)
		}
	}
	filters := map[string][]protocol.CatalogFilter{}
	for _, filter := range request.Filters {
		column, ok := byName[filter.Column]
		if !ok || filter.Value == nil {
			return "", nil, errBrowse
		}
		if !browseScalarType(column.nativeType) {
			return "", nil, errBrowseType
		}
		if filter.Operator != "eq" && filter.Operator != "lt" && filter.Operator != "lte" && filter.Operator != "gt" && filter.Operator != "gte" {
			return "", nil, errBrowse
		}
		filters[filter.Column] = append(filters[filter.Column], filter)
	}
	fullPartition := len(partition) > 0
	for _, column := range partition {
		fs := filters[column.name]
		if len(fs) != 1 || fs[0].Operator != "eq" {
			fullPartition = false
		}
	}
	if len(filters) > 0 && !fullPartition {
		if len(request.Filters) != 1 {
			return "", nil, errBrowse
		}
		filter := request.Filters[0]
		column := byName[filter.Column]
		if !column.indexed || filter.Operator != "eq" {
			return "", nil, errBrowse
		}
	} else if fullPartition {
		ended, rangeSeen := false, false
		for _, column := range clustering {
			fs := filters[column.name]
			if len(fs) == 0 {
				ended = true
				continue
			}
			if ended || rangeSeen {
				return "", nil, errBrowse
			}
			if len(fs) == 1 && fs[0].Operator == "eq" {
				continue
			}
			lower, upper := false, false
			for _, filter := range fs {
				switch filter.Operator {
				case "lt", "lte":
					if upper {
						return "", nil, errBrowse
					}
					upper = true
				case "gt", "gte":
					if lower {
						return "", nil, errBrowse
					}
					lower = true
				default:
					return "", nil, errBrowse
				}
			}
			rangeSeen = true
		}
		for name := range filters {
			column := byName[name]
			if column.kind != "partition_key" && column.kind != "clustering" {
				return "", nil, errBrowse
			}
		}
	}
	if len(request.Sort) > 0 && !fullPartition {
		return "", nil, errBrowse
	}
	sql := "SELECT * FROM " + qualified(request.Schema, request.Object)
	var where []string
	var values []any
	operators := map[string]string{"eq": "=", "lt": "<", "lte": "<=", "gt": ">", "gte": ">="}
	for _, filter := range request.Filters {
		parameter := textParameter{Value: *filter.Value}
		operand := "?"
		if source {
			column := byName[filter.Column]
			info := gocql.NewNativeType(5, gocql.TypeCustom, strings.ToLower(strings.TrimSpace(column.nativeType)))
			encoded, err := parameter.MarshalCQL(info)
			if err != nil {
				return "", nil, err
			}
			operand, err = cqlValue(info, encoded, true, 0)
			if err != nil {
				return "", nil, err
			}
			if info.Type() == gocql.TypeFloat || info.Type() == gocql.TypeDouble {
				if operand == "+Inf" {
					operand = "Infinity"
				} else if operand == "-Inf" {
					operand = "-Infinity"
				}
			}
		}
		where = append(where, quoteIdentifier(filter.Column)+" "+operators[filter.Operator]+" "+operand)
		values = append(values, parameter)
	}
	if len(where) > 0 {
		sql += " WHERE " + strings.Join(where, " AND ")
	}
	var order []string
	reverse := -1
	sortStart := 0
	if len(request.Sort) > 0 {
		for sortStart < len(clustering) && clustering[sortStart].name != request.Sort[0].Column {
			fs := filters[clustering[sortStart].name]
			if len(fs) != 1 || fs[0].Operator != "eq" {
				return "", nil, errBrowse
			}
			sortStart++
		}
	}
	for offset, item := range request.Sort {
		i := sortStart + offset
		if i >= len(clustering) || item.Column != clustering[i].name || item.Direction != "asc" && item.Direction != "desc" {
			return "", nil, errBrowse
		}
		natural := clustering[i].order
		if natural == "" || natural == "none" {
			natural = "asc"
		}
		r := 0
		if item.Direction != natural {
			r = 1
		}
		if reverse >= 0 && reverse != r {
			return "", nil, errBrowse
		}
		reverse = r
		order = append(order, quoteIdentifier(item.Column)+" "+strings.ToUpper(item.Direction))
	}
	if len(order) > 0 {
		sql += " ORDER BY " + strings.Join(order, ", ")
	}
	return sql, values, nil
}

// Values stay parameters; no user value is concatenated into generated CQL.
// The driver's prepared type is authoritative for conversion and range checks.
type textParameter struct{ Value string }

func (p textParameter) MarshalCQL(info gocql.TypeInfo) ([]byte, error) {
	var value any = p.Value
	switch info.Type() {
	case gocql.TypeText, gocql.TypeAscii, gocql.TypeVarchar, gocql.TypeInt, gocql.TypeBigInt, gocql.TypeSmallInt, gocql.TypeTinyInt, gocql.TypeCounter, gocql.TypeUUID, gocql.TypeInet, gocql.TypeDate, gocql.TypeDuration:
	case gocql.TypeTimeUUID:
		parsed, err := gocql.ParseUUID(p.Value)
		if err != nil {
			return nil, errBrowse
		}
		value = parsed
	case gocql.TypeBlob:
		decoded, err := base64.StdEncoding.DecodeString(p.Value)
		if err != nil {
			return nil, errBrowse
		}
		value = decoded
	case gocql.TypeBoolean:
		parsed, err := strconv.ParseBool(p.Value)
		if err != nil {
			return nil, errBrowse
		}
		value = parsed
	case gocql.TypeVarint:
		parsed, ok := new(big.Int).SetString(p.Value, 10)
		if !ok {
			return nil, errBrowse
		}
		value = parsed
	case gocql.TypeDecimal:
		parsed, err := parseDecimal(p.Value)
		if err != nil {
			return nil, errBrowse
		}
		value = parsed
	case gocql.TypeFloat:
		parsed, err := strconv.ParseFloat(p.Value, 32)
		if err != nil {
			return nil, errBrowse
		}
		value = float32(parsed)
	case gocql.TypeDouble:
		parsed, err := strconv.ParseFloat(p.Value, 64)
		if err != nil {
			return nil, errBrowse
		}
		value = parsed
	case gocql.TypeTimestamp:
		parsed, err := strconv.ParseInt(p.Value, 10, 64)
		if err != nil {
			date, err := time.Parse(time.RFC3339Nano, p.Value)
			if err != nil {
				return nil, errBrowse
			}
			value = date
		} else {
			value = parsed
		}
	case gocql.TypeTime:
		parsed, err := time.Parse("15:04:05.999999999", p.Value)
		if err != nil {
			return nil, errBrowse
		}
		value = time.Duration(parsed.Hour())*time.Hour + time.Duration(parsed.Minute())*time.Minute + time.Duration(parsed.Second())*time.Second + time.Duration(parsed.Nanosecond())
	default:
		return nil, errBrowse
	}
	encoded, err := gocql.Marshal(info, value)
	if err != nil {
		return nil, errBrowse
	}
	return encoded, nil
}
