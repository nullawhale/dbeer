package mongodb

import (
	"context"
	"encoding/json"
	"errors"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
)

const maxResultBytes = 3 * 1024 * 1024

var errDocumentLimit = errors.New("MongoDB document exceeds display limit")

func documentColumns() []protocol.Column {
	return []protocol.Column{{Index: 0, Name: "document", Engine: "mongodb", NativeType: "BSON document", TypeIdentity: "mongodb:bson:canonicalExtendedJSON:v1"}}
}

// CanonicalDocument never passes through map[string]any or float64 JSON decoding.
// The official BSON encoder preserves every scalar tag and nested value.
func CanonicalDocument(raw bson.Raw) (string, error) {
	if err := raw.Validate(); err != nil {
		return "", err
	}
	encoded, err := bson.MarshalExtJSON(raw, true, false)
	return string(encoded), err
}

func readDocuments(ctx context.Context, cursor *mongo.Cursor, sink adapter.ResultSink, full bool, rowLimit int, tag string) (protocol.ResultSet, error) {
	known := false
	r := protocol.ResultSet{Columns: documentColumns(), Rows: [][]*string{}, CommandTag: tag, AffectedRowCountKnown: &known}
	if sink != nil {
		if err := sink.Begin(0, r.Columns); err != nil {
			return r, err
		}
	}
	bytes := 0
	for cursor.Next(ctx) {
		text, err := CanonicalDocument(cursor.Current)
		if err != nil {
			return r, err
		}
		row := []*string{&text}
		encoded, _ := json.Marshal(row)
		fits := len(r.Rows) < rowLimit && bytes+len(encoded) < maxResultBytes
		if !full && !fits {
			r.Truncated = true
			if len(r.Rows) == 0 {
				return r, errDocumentLimit
			}
			break
		}
		r.RowCount++
		if fits {
			r.Rows = append(r.Rows, row)
			bytes += len(encoded)
		} else {
			r.Truncated = true
		}
		if sink != nil {
			if err := sink.Row(0, row); err != nil {
				return r, err
			}
		}
		if !full && len(r.Rows) == rowLimit {
			r.Truncated = cursor.ID() != 0 || cursor.RemainingBatchLength() > 0
			break
		}
	}
	if err := cursor.Err(); err != nil {
		return r, err
	}
	r.DisplayedRowCount = len(r.Rows)
	if r.Truncated {
		r.DisplayNotice = "MongoDB display limit reached. Run to File exports the complete result."
	}
	if sink != nil {
		if err := sink.End(0, r); err != nil {
			return r, err
		}
	}
	return r, nil
}

func resultResponse(command protocol.Command, result protocol.ResultSet) protocol.Response {
	return protocol.Response{Type: "query.result", RequestID: command.RequestID, SessionID: command.SessionID, QueryID: command.QueryID,
		Connected: true, TransactionStatus: "unsupported", Columns: result.Columns, Rows: result.Rows, ResultSets: []protocol.ResultSet{result},
		RowCount: result.RowCount, DisplayedRowCount: result.DisplayedRowCount, CommandTag: result.CommandTag, Truncated: result.Truncated,
		DisplayNotice: result.DisplayNotice, NextCursor: result.NextCursor, AffectedRowCountKnown: result.AffectedRowCountKnown}
}
