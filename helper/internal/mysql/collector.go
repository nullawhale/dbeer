package mysql

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strconv"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

const MaxResultRows = 1000
const MaxResultBytes = 8 * 1024 * 1024

type collector struct {
	response            protocol.Response
	bytes               int
	count               int64
	stopped             bool
	maxRows             int
	maxBytes            int
	resultSets          []protocol.ResultSet
	needsStatusProbe    bool
	omittedResults      bool
	delivery            *sinkDelivery
	resultIndex         int
	began               bool
	ended               bool
	valueColumns        []protocol.Column
	hiddenStorageFields int
}

type sinkDelivery struct {
	sink    adapter.ResultSink
	failure error
}

func (collector *collector) deliver(action func(adapter.ResultSink) error) {
	if collector.delivery != nil && collector.delivery.failure == nil {
		collector.delivery.failure = action(collector.delivery.sink)
	}
}

func newCollector(command protocol.Command) *collector {
	return &collector{maxRows: MaxResultRows, maxBytes: MaxResultBytes, response: protocol.Response{Type: "query.result", RequestID: command.RequestID,
		SessionID: command.SessionID, QueryID: command.QueryID, Rows: make([][]*string, 0)}}
}

func (collector *collector) columns(result *wire.Result) error {
	if len(result.Fields) > maxResultColumns || collector.hiddenStorageFields < 0 || collector.hiddenStorageFields > len(result.Fields) {
		return wire.ErrMalformPacket
	}
	fields := result.Fields[:len(result.Fields)-collector.hiddenStorageFields]
	collector.response.Columns = make([]protocol.Column, len(fields))
	for index, field := range fields {
		column := protocol.Column{Index: index, Name: string(field.Name), Engine: "mysql", NativeType: nativeType(field), TypeIdentity: mysqlWireTypeIdentity(field)}
		if binaryColumn(field) {
			column.Encoding = "base64"
		}
		collector.response.Columns[index] = column
	}
	collector.valueColumns = collector.response.Columns
	collector.began = true
	collector.deliver(func(sink adapter.ResultSink) error { return sink.Begin(collector.resultIndex, collector.valueColumns) })
	encoded, _ := json.Marshal(collector.response)
	collector.bytes = len(encoded)
	if collector.bytes+1024 > collector.maxBytes {
		collector.response.Columns = nil
		collector.response.Truncated, collector.stopped = true, true
	}
	return nil
}

func (collector *collector) row(values []wire.FieldValue) error {
	collector.count++
	if collector.stopped && (collector.delivery == nil || collector.delivery.failure != nil) {
		return nil
	}
	if len(collector.response.Rows) == collector.maxRows {
		collector.response.Truncated, collector.stopped = true, true
		if collector.delivery == nil || collector.delivery.failure != nil {
			return nil
		}
	}
	storageToken := ""
	if collector.hiddenStorageFields > 0 {
		if len(values) < collector.hiddenStorageFields {
			return wire.ErrMalformPacket
		}
		var err error
		storageToken, err = mysqlStorageToken(values[len(values)-collector.hiddenStorageFields:])
		if err != nil {
			return err
		}
		values = values[:len(values)-collector.hiddenStorageFields]
	}
	row := make([]*string, len(values))
	estimated := 2 + len(storageToken)
	for index, value := range values {
		if value.Type == wire.FieldValueTypeNull {
			estimated += 5
			continue
		}
		valueSize := 32
		if value.Type == wire.FieldValueTypeString {
			valueSize = len(value.AsString())
			if collector.valueColumns[index].Encoding == "base64" {
				valueSize = base64.StdEncoding.EncodedLen(valueSize)
			}
		}
		estimated += valueSize + 3
		if collector.bytes+estimated+1024 > collector.maxBytes && (collector.delivery == nil || collector.delivery.failure != nil) {
			collector.response.Truncated, collector.stopped = true, true
			return nil
		}
		var text string
		switch value.Type {
		case wire.FieldValueTypeString:
			if collector.valueColumns[index].Encoding == "base64" {
				text = base64.StdEncoding.EncodeToString(value.AsString())
			} else {
				text = string(value.AsString())
			}
		case wire.FieldValueTypeUnsigned:
			text = strconv.FormatUint(value.AsUint64(), 10)
		case wire.FieldValueTypeSigned:
			text = strconv.FormatInt(value.AsInt64(), 10)
		case wire.FieldValueTypeFloat:
			text = strconv.FormatFloat(value.AsFloat64(), 'g', -1, 64)
		}
		row[index] = &text
	}
	collector.deliver(func(sink adapter.ResultSink) error { return sink.Row(collector.resultIndex, row) })
	if collector.stopped {
		return nil
	}
	encoded, _ := json.Marshal(row)
	if collector.bytes+len(encoded)+len(storageToken)+1024 > collector.maxBytes {
		collector.response.Truncated, collector.stopped = true, true
		return nil
	}
	collector.response.Rows = append(collector.response.Rows, row)
	if storageToken != "" {
		collector.response.StorageTokens = append(collector.response.StorageTokens, storageToken)
	}
	collector.bytes += len(encoded) + len(storageToken) + 1
	return nil
}

func (collector *collector) finish(result *wire.Result, elapsed time.Duration, txStatus string) protocol.Response {
	if len(collector.resultSets) > 1 {
		response := collector.response
		response.DurationMS, response.TransactionStatus = float64(elapsed)/float64(time.Millisecond), txStatus
		response.ResultSets = collector.resultSets
		if collector.omittedResults {
			response.DisplayNotice = "Additional result sets exceeded the display limit and were drained without retaining data."
		}
		return boundResultSets(response)
	}
	return collector.finishSingle(result, elapsed, txStatus)
}

func (collector *collector) finishSingle(result *wire.Result, elapsed time.Duration, txStatus string) protocol.Response {
	response := collector.response
	response.DurationMS, response.TransactionStatus = float64(elapsed)/float64(time.Millisecond), txStatus
	response.CommandTag = "OK"
	response.RowCount = int64(result.AffectedRows)
	if len(response.Columns) > 0 || collector.count > 0 {
		response.CommandTag, response.RowCount = "SELECT", collector.count
	}
	if response.Truncated {
		response.DisplayNotice = "Result display is limited to 1000 rows and 8 MiB. The command completed in full."
	}
	response.DisplayedRowCount = len(response.Rows)
	if !collector.ended {
		collector.ended = true
		if !collector.began {
			collector.deliver(func(sink adapter.ResultSink) error { return sink.Begin(collector.resultIndex, []protocol.Column{}) })
		}
		summary := protocol.ResultSet{Columns: collector.valueColumns, CommandTag: response.CommandTag, RowCount: response.RowCount, DisplayedRowCount: response.DisplayedRowCount, Truncated: response.Truncated, DisplayNotice: response.DisplayNotice, StorageTokens: response.StorageTokens}
		collector.deliver(func(sink adapter.ResultSink) error { return sink.End(collector.resultIndex, summary) })
	}
	return response
}

func boundResultSets(response protocol.Response) protocol.Response {
	primary := 0
	for index, set := range response.ResultSets {
		if len(set.Columns) > 0 {
			primary = index
			break
		}
	}
	refresh := func() {
		set := response.ResultSets[primary]
		response.Columns, response.Rows, response.CommandTag, response.RowCount = set.Columns, set.Rows, set.CommandTag, set.RowCount
		response.StorageTokens = set.StorageTokens
		response.DisplayedRowCount, response.Truncated = set.DisplayedRowCount, set.Truncated
		if response.DisplayNotice == "" {
			response.DisplayNotice = set.DisplayNotice
		}
	}
	refresh()
	for {
		encoded, _ := json.Marshal(response)
		excess := len(encoded) - MaxResultBytes
		if excess <= 0 {
			return response
		}
		changed := false
		for index := len(response.ResultSets) - 1; index >= 0 && excess > 0; index-- {
			set := &response.ResultSets[index]
			for len(set.Rows) > 0 && excess > 0 {
				last := len(set.Rows) - 1
				row, _ := json.Marshal(set.Rows[last])
				multiplier := 1
				if index == primary {
					multiplier = 2
				}
				excess -= multiplier * (len(row) + 1)
				set.Rows = set.Rows[:last]
				if len(set.StorageTokens) > last {
					set.StorageTokens = set.StorageTokens[:last]
				}
				set.DisplayedRowCount = len(set.Rows)
				set.Truncated = true
				set.DisplayNotice = "Result display is limited to 1000 rows and 8 MiB across all result sets. The command completed in full."
				changed = true
			}
		}
		if !changed {
			// Metadata alone may exceed the budget. Keep compact summaries and
			// the actual command counts while explicitly omitting column details.
			for index := range response.ResultSets {
				if len(response.ResultSets[index].Columns) > 0 {
					response.ResultSets[index].Columns = []protocol.Column{}
					response.ResultSets[index].Truncated = true
					changed = true
				}
			}
			response.DisplayNotice = "Column metadata exceeds the display limit; result summaries are retained."
		}
		refresh()
		if !changed {
			return response
		}
	}
}

func (collector *collector) attachResults(response protocol.Response) protocol.Response {
	if len(collector.resultSets) > 0 {
		response.ResultSets = collector.resultSets
		return boundResultSets(response)
	}
	return response
}

func binaryColumn(field *wire.Field) bool {
	switch field.Type {
	case wire.MYSQL_TYPE_BIT, wire.MYSQL_TYPE_GEOMETRY, wire.MYSQL_TYPE_VECTOR:
		return true
	case wire.MYSQL_TYPE_BLOB, wire.MYSQL_TYPE_TINY_BLOB, wire.MYSQL_TYPE_MEDIUM_BLOB, wire.MYSQL_TYPE_LONG_BLOB,
		wire.MYSQL_TYPE_VARCHAR, wire.MYSQL_TYPE_VAR_STRING, wire.MYSQL_TYPE_STRING:
		return field.Charset == 63
	}
	return false
}

func nativeType(field *wire.Field) string {
	names := map[byte]string{
		wire.MYSQL_TYPE_DECIMAL: "DECIMAL", wire.MYSQL_TYPE_NEWDECIMAL: "DECIMAL",
		wire.MYSQL_TYPE_TINY: "TINYINT", wire.MYSQL_TYPE_SHORT: "SMALLINT", wire.MYSQL_TYPE_LONG: "INT",
		wire.MYSQL_TYPE_INT24: "MEDIUMINT", wire.MYSQL_TYPE_LONGLONG: "BIGINT", wire.MYSQL_TYPE_FLOAT: "FLOAT", wire.MYSQL_TYPE_DOUBLE: "DOUBLE",
		wire.MYSQL_TYPE_NULL: "NULL", wire.MYSQL_TYPE_DATE: "DATE", wire.MYSQL_TYPE_TIME: "TIME", wire.MYSQL_TYPE_DATETIME: "DATETIME",
		wire.MYSQL_TYPE_TIMESTAMP: "TIMESTAMP", wire.MYSQL_TYPE_YEAR: "YEAR", wire.MYSQL_TYPE_VARCHAR: "VARCHAR",
		wire.MYSQL_TYPE_VAR_STRING: "VARCHAR", wire.MYSQL_TYPE_STRING: "CHAR", wire.MYSQL_TYPE_BIT: "BIT", wire.MYSQL_TYPE_JSON: "JSON",
		wire.MYSQL_TYPE_ENUM: "ENUM", wire.MYSQL_TYPE_SET: "SET", wire.MYSQL_TYPE_TINY_BLOB: "TINYBLOB", wire.MYSQL_TYPE_MEDIUM_BLOB: "MEDIUMBLOB",
		wire.MYSQL_TYPE_LONG_BLOB: "LONGBLOB", wire.MYSQL_TYPE_BLOB: "BLOB", wire.MYSQL_TYPE_GEOMETRY: "GEOMETRY", wire.MYSQL_TYPE_VECTOR: "VECTOR",
	}
	name, ok := names[field.Type]
	if !ok {
		name = fmt.Sprintf("MYSQL_TYPE_%d", field.Type)
	}
	if field.Flag&wire.ENUM_FLAG != 0 {
		name = "ENUM"
	}
	if field.Flag&wire.SET_FLAG != 0 {
		name = "SET"
	}
	if field.Flag&wire.UNSIGNED_FLAG != 0 {
		name += " UNSIGNED"
	}
	return name
}

func mysqlWireTypeIdentity(field *wire.Field) string {
	identity, _ := json.Marshal(struct {
		Engine   string `json:"engine"`
		Type     byte   `json:"type"`
		Charset  uint16 `json:"charset"`
		Length   uint32 `json:"length"`
		Decimals byte   `json:"decimals"`
		Flags    uint16 `json:"flags"`
	}{"mysql", field.Type, field.Charset, field.ColumnLength, field.Decimal, field.Flag & (wire.UNSIGNED_FLAG | wire.ZEROFILL_FLAG | wire.BINARY_FLAG | wire.ENUM_FLAG | wire.SET_FLAG)})
	unresolved := field.Type == wire.MYSQL_TYPE_ENUM || field.Type == wire.MYSQL_TYPE_SET || field.Type == wire.MYSQL_TYPE_GEOMETRY || field.Type == wire.MYSQL_TYPE_VECTOR || field.Flag&(wire.ENUM_FLAG|wire.SET_FLAG) != 0
	// FLOAT's text formatter can collapse adjacent float32 values. TIMESTAMP
	// is rendered in the session time zone, which may change during a query.
	unresolved = unresolved || field.Type == wire.MYSQL_TYPE_FLOAT || field.Type == wire.MYSQL_TYPE_TIMESTAMP || field.Type == wire.MYSQL_TYPE_TIMESTAMP2 || field.Type == wire.MYSQL_TYPE_DOUBLE && field.Decimal < 31
	switch field.Type {
	case wire.MYSQL_TYPE_VARCHAR, wire.MYSQL_TYPE_VAR_STRING, wire.MYSQL_TYPE_STRING, wire.MYSQL_TYPE_BLOB, wire.MYSQL_TYPE_TINY_BLOB, wire.MYSQL_TYPE_MEDIUM_BLOB, wire.MYSQL_TYPE_LONG_BLOB, wire.MYSQL_TYPE_JSON:
		// Protocol_classic caches its result charset at start_result_metadata;
		// its UTF8mb4 conversion therefore stays lossless even if a routine
		// changes the session setting while producing subsequent rows.
		unresolved = unresolved || field.Charset != 63 && !mysqlUTF8MB4Collation(field.Charset)
	}
	if unresolved {
		return "unresolved:" + string(identity)
	}
	return string(identity)
}

func mysqlUTF8MB4Collation(id uint16) bool {
	if id == 45 || id == 46 || id >= 224 && id <= 247 {
		return true
	}
	if id >= 255 && id <= 309 {
		switch id {
		case 272, 276, 295, 299, 301, 302:
			return false
		}
		return true
	}
	return false
}
