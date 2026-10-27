package mongodb

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"regexp"
	"strings"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/mongoscript"
	"dbeer/helper/internal/protocol"
	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
)

type browseCursor struct {
	cursor    *mongo.Cursor
	signature [32]byte
	expires   time.Time
	pending   *string
}

func (s *Session) clearCursors(ctx context.Context) {
	for token, c := range s.cursors {
		_ = c.cursor.Close(ctx)
		delete(s.cursors, token)
	}
}

func browseScript(r protocol.CatalogRequest) (mongoscript.Script, error) {
	s := mongoscript.Script{Database: r.Schema, Collection: r.Object, Filter: bson.D{}}
	validField := func(name string) bool {
		for _, part := range strings.Split(name, ".") {
			if !mongoscript.ValidName(part) || strings.HasPrefix(part, "$") {
				return false
			}
		}
		return true
	}
	compileCondition := func(f protocol.CatalogFilter) (bson.D, error) {
		if !validField(f.Column) {
			return nil, mongoscript.ErrInvalid
		}
		var value any
		if f.Value != nil {
			var err error
			value, err = mongoscript.Value(*f.Value)
			if err != nil {
				return nil, err
			}
		}
		var condition bson.D
		switch f.Operator {
		case "eq", "ne", "lt", "lte", "gt", "gte":
			condition = bson.D{{Key: "$" + f.Operator, Value: value}}
		case "isNull":
			condition = bson.D{{Key: "$type", Value: 10}}
		case "isNotNull":
			condition = bson.D{{Key: "$exists", Value: true}, {Key: "$ne", Value: nil}}
		case "contains":
			text, ok := value.(string)
			if !ok {
				return nil, mongoscript.ErrInvalid
			}
			condition = bson.D{{Key: "$regex", Value: regexp.QuoteMeta(text)}}
		default:
			return nil, mongoscript.ErrInvalid
		}
		return bson.D{{Key: f.Column, Value: condition}}, nil
	}
	if _, valid := r.EffectiveFilterExpression(); !valid {
		return s, mongoscript.ErrInvalid
	}
	if r.FilterExpression != nil {
		var compile func(protocol.CatalogFilterExpression) (bson.D, error)
		compile = func(expression protocol.CatalogFilterExpression) (bson.D, error) {
			if expression.Kind == "condition" {
				return compileCondition(*expression.Condition)
			}
			conditions := bson.A{}
			for _, child := range expression.Children {
				condition, err := compile(child)
				if err != nil {
					return nil, err
				}
				conditions = append(conditions, condition)
			}
			return bson.D{{Key: "$" + expression.Kind, Value: conditions}}, nil
		}
		var err error
		s.Filter, err = compile(*r.FilterExpression)
		if err != nil {
			return s, err
		}
	} else {
		conditions := bson.A{}
		for _, filter := range r.Filters {
			condition, err := compileCondition(filter)
			if err != nil {
				return s, err
			}
			conditions = append(conditions, condition)
		}
		if len(conditions) > 0 {
			s.Filter = bson.D{{Key: "$and", Value: conditions}}
		}
	}
	seenSort := make(map[string]bool)
	for _, order := range r.Sort {
		if !validField(order.Column) || seenSort[order.Column] {
			return s, mongoscript.ErrInvalid
		}
		seenSort[order.Column] = true
		direction := int32(1)
		if order.Direction == "desc" {
			direction = -1
		} else if order.Direction != "asc" {
			return s, mongoscript.ErrInvalid
		}
		s.Sort = append(s.Sort, bson.E{Key: order.Column, Value: direction})
	}
	if len(s.Sort) == 0 {
		s.Sort = bson.D{{Key: "_id", Value: int32(1)}}
	}
	return s, nil
}

func (s *Session) browse(ctx context.Context, command protocol.Command, sink adapter.ResultSink) protocol.Response {
	r := *command.Catalog
	if r.Page != 0 {
		return s.failure(command, "unsupported", "MongoDB browsing uses sequential cursors. Refresh the first page.")
	}
	script, err := browseScript(r)
	if err != nil {
		return s.failure(command, "validation", "MongoDB filter values require JSON or Extended JSON. Quote string values, for example \"hello\".")
	}
	encoded, _ := json.Marshal(struct {
		Database, Collection string
		Filter, Sort         bson.D
	}{script.Database, script.Collection, script.Filter, script.Sort})
	signature := sha256.Sum256(encoded)
	var c browseCursor
	if r.Cursor != "" {
		var ok bool
		c, ok = s.cursors[r.Cursor]
		delete(s.cursors, r.Cursor)
		if !ok || c.signature != signature || time.Now().After(c.expires) {
			if c.cursor != nil {
				closeCursor(c.cursor)
			}
			return s.failure(command, "cursor", "This MongoDB cursor expired or no longer matches the collection, filters, or sort. Refresh the first page.")
		}
	} else {
		s.clearCursors(ctx)
		c.cursor, err = s.openCursor(ctx, script)
		if err != nil {
			return safeError(command, ctx, err, false, nil)
		}
		c.signature = signature
	}
	keep := false
	defer func() {
		if !keep {
			closeCursor(c.cursor)
		}
	}()
	known := false
	result := protocol.ResultSet{Columns: documentColumns(), Rows: [][]*string{}, CommandTag: "FIND", AffectedRowCountKnown: &known}
	if sink != nil {
		if err = sink.Begin(0, result.Columns); err != nil {
			return safeError(command, ctx, err, false, nil)
		}
	}
	bytes := 0
	for len(result.Rows) < 200 {
		var text string
		if c.pending != nil {
			text = *c.pending
			c.pending = nil
		} else {
			if !c.cursor.Next(ctx) {
				break
			}
			text, err = CanonicalDocument(c.cursor.Current)
			if err != nil {
				return safeError(command, ctx, err, false, nil)
			}
		}
		row := []*string{&text}
		encoded, _ := json.Marshal(row)
		if bytes+len(encoded) > maxResultBytes {
			c.pending = &text
			if len(result.Rows) == 0 {
				return safeError(command, ctx, errDocumentLimit, false, nil)
			}
			break
		}
		bytes += len(encoded)
		result.Rows = append(result.Rows, row)
		if sink != nil {
			if err = sink.Row(0, row); err != nil {
				return safeError(command, ctx, err, false, nil)
			}
		}
	}
	if err = c.cursor.Err(); err != nil {
		return safeError(command, ctx, err, false, nil)
	}
	if c.pending != nil || c.cursor.ID() != 0 || c.cursor.RemainingBatchLength() > 0 {
		var random [24]byte
		if _, err = rand.Read(random[:]); err != nil {
			return safeError(command, ctx, errors.New("cursor"), false, nil)
		}
		result.NextCursor = hex.EncodeToString(random[:])
		c.expires = time.Now().Add(5 * time.Minute)
		s.cursors[result.NextCursor] = c
		keep = true
	}
	result.RowCount, result.DisplayedRowCount = int64(len(result.Rows)), len(result.Rows)
	result.DisplayNotice = "Canonical Extended JSON preserves BSON types. Pages are sequential and do not provide a snapshot."
	if sink != nil {
		if err = sink.End(0, result); err != nil {
			return safeError(command, ctx, err, false, nil)
		}
	}
	source, _ := bson.MarshalExtJSON(bson.D{{Key: "database", Value: script.Database}, {Key: "collection", Value: script.Collection}, {Key: "find", Value: script.Filter}, {Key: "sort", Value: script.Sort}}, true, false)
	return resultResponse(command, result).WithReadSQL(string(source))
}
