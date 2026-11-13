package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"math"
	"strconv"
	"strings"
	"unicode/utf8"
)

const BrowseFilterTreeCapability = "browseFilterTreeV1"
const SQLiteCellFilterCapability = "sqliteCellFilterV1"

// CatalogFilterExpression is a bounded predicate, never executable SQL/CQL.
// A condition has only Condition; an and/or group has only nonempty Children.
type CatalogFilterExpression struct {
	Kind      string                    `json:"kind"`
	Condition *CatalogFilter            `json:"condition,omitempty"`
	Children  []CatalogFilterExpression `json:"children,omitempty"`
}

type filterBudget struct{ nodes, conditions, nativeBytes int }

func (expression CatalogFilterExpression) Valid() bool {
	return expression.valid(1, &filterBudget{})
}

func (expression CatalogFilterExpression) valid(depth int, budget *filterBudget) bool {
	budget.nodes++
	if depth > 4 || budget.nodes > 64 {
		return false
	}
	switch expression.Kind {
	case "condition":
		budget.conditions++
		if budget.conditions > 32 || expression.Children != nil || expression.Condition == nil || !expression.Condition.Valid() {
			return false
		}
		if expression.Condition.NativeValue != nil {
			budget.nativeBytes += expression.Condition.NativeValue.encodedSize()
		}
		return budget.nativeBytes <= NativeCellFilterBudget
	case "and", "or":
		if expression.Condition != nil || len(expression.Children) == 0 {
			return false
		}
		for _, child := range expression.Children {
			if !child.valid(depth+1, budget) {
				return false
			}
		}
		return true
	default:
		return false
	}
}

func (filter CatalogFilter) Valid() bool {
	if filter.Column == "" || len(filter.Column) > 1024 || !utf8.ValidString(filter.Column) || strings.ContainsRune(filter.Column, 0) {
		return false
	}
	if filter.NativeValue != nil {
		return filter.Value == nil && filter.SQLiteValue == nil && filter.NativeValue.Valid() && (filter.Operator == "eq" || filter.Operator == "ne")
	}
	if filter.SQLiteValue != nil {
		value := *filter.SQLiteValue
		if filter.Value != nil || !value.Valid() || value.Type == "null" || len(value.Value) > 1024*1024 || filter.Operator != "eq" && filter.Operator != "ne" {
			return false
		}
		if value.Type == "real" {
			bits, err := strconv.ParseUint(value.Value, 16, 64)
			return err == nil && !math.IsNaN(math.Float64frombits(bits))
		}
		return true
	}
	switch filter.Operator {
	case "eq", "ne", "lt", "lte", "gt", "gte", "contains":
		return filter.Value != nil && len(*filter.Value) <= 1024*1024 && utf8.ValidString(*filter.Value) && !strings.ContainsRune(*filter.Value, 0)
	case "isNull", "isNotNull":
		return filter.Value == nil
	default:
		return false
	}
}

// Typed cell predicates retain SQLite storage values; existing text operands
// retain their original browse semantics.
func (filter *CatalogFilter) UnmarshalJSON(data []byte) error {
	var fields map[string]json.RawMessage
	if !utf8.Valid(data) || !uniqueObjectKeys(data) || json.Unmarshal(data, &fields) != nil || fields == nil {
		return errors.New("invalid filter condition")
	}
	for name := range fields {
		if name != "column" && name != "operator" && name != "value" && name != "sqliteValue" && name != "nativeValue" {
			return errors.New("unknown filter condition field")
		}
	}
	if _, native := fields["nativeValue"]; native && !nativeJSONUnicodeValid(data) {
		return errors.New("invalid native filter Unicode")
	}
	var parsed CatalogFilter
	if !stringField(fields, "column", &parsed.Column) || !stringField(fields, "operator", &parsed.Operator) {
		return errors.New("invalid filter condition identity")
	}
	if raw, exists := fields["nativeValue"]; exists {
		if _, found := fields["value"]; found {
			return errors.New("ambiguous filter operands")
		}
		if _, found := fields["sqliteValue"]; found {
			return errors.New("ambiguous filter operands")
		}
		var value NativeCellFilterValue
		if json.Unmarshal(raw, &value) != nil {
			return errors.New("invalid native cell filter operand")
		}
		parsed.NativeValue = &value
	} else if raw, exists := fields["sqliteValue"]; exists {
		if _, hasText := fields["value"]; hasText {
			return errors.New("ambiguous filter operands")
		}
		var valueFields map[string]json.RawMessage
		var value SQLiteValue
		if !uniqueObjectKeys(raw) || json.Unmarshal(raw, &valueFields) != nil || valueFields == nil || !stringField(valueFields, "type", &value.Type) {
			return errors.New("invalid SQLite filter operand")
		}
		for name := range valueFields {
			if name != "type" && name != "value" {
				return errors.New("unknown SQLite filter operand field")
			}
		}
		if _, exists := valueFields["value"]; exists && !stringField(valueFields, "value", &value.Value) {
			return errors.New("invalid SQLite filter operand value")
		}
		parsed.SQLiteValue = &value
	} else if raw, exists := fields["value"]; exists && !bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		var value string
		if !stringField(fields, "value", &value) {
			return errors.New("invalid filter operand")
		}
		parsed.Value = &value
	}
	if !parsed.Valid() {
		return errors.New("invalid filter condition")
	}
	*filter = parsed
	return nil
}

// EffectiveFilterExpression normalizes the legacy AND list without modifying it.
// An absent expression means an unfiltered browse; a false result rejects
// malformed predicates and ambiguous requests containing both representations.
func (request CatalogRequest) EffectiveFilterExpression() (*CatalogFilterExpression, bool) {
	if request.FilterExpression != nil {
		return request.FilterExpression, len(request.Filters) == 0 && request.FilterExpression.Valid()
	}
	if len(request.Filters) == 0 {
		return nil, true
	}
	if len(request.Filters) > 32 {
		return nil, false
	}
	children := make([]CatalogFilterExpression, 0, len(request.Filters))
	nativeBytes := 0
	for _, filter := range request.Filters {
		if !filter.Valid() {
			return nil, false
		}
		if filter.NativeValue != nil {
			nativeBytes += filter.NativeValue.encodedSize()
			if nativeBytes > NativeCellFilterBudget {
				return nil, false
			}
		}
		copy := filter
		children = append(children, CatalogFilterExpression{Kind: "condition", Condition: &copy})
	}
	if len(children) == 1 {
		return &children[0], true
	}
	return &CatalogFilterExpression{Kind: "and", Children: children}, true
}

// FlattenAND exposes the existing Cassandra subset without simulating OR with
// several reads or changing its key restrictions and paging semantics.
func (expression CatalogFilterExpression) FlattenAND() ([]CatalogFilter, bool) {
	if !expression.Valid() {
		return nil, false
	}
	var filters []CatalogFilter
	var visit func(CatalogFilterExpression) bool
	visit = func(node CatalogFilterExpression) bool {
		if node.Kind == "condition" {
			filters = append(filters, *node.Condition)
			return true
		}
		if node.Kind != "and" {
			return false
		}
		for _, child := range node.Children {
			if !visit(child) {
				return false
			}
		}
		return true
	}
	if !visit(expression) {
		return nil, false
	}
	return filters, true
}

func (expression *CatalogFilterExpression) UnmarshalJSON(data []byte) error {
	parsed, ok := parseFilterExpression(data, 1, &filterBudget{})
	if !ok {
		return errors.New("invalid browse filter expression")
	}
	*expression = parsed
	return nil
}

func parseFilterExpression(data []byte, depth int, budget *filterBudget) (CatalogFilterExpression, bool) {
	var expression CatalogFilterExpression
	budget.nodes++
	if depth > 4 || budget.nodes > 64 {
		return expression, false
	}
	var fields map[string]json.RawMessage
	if !utf8.Valid(data) || json.Unmarshal(data, &fields) != nil || fields == nil || !uniqueObjectKeys(data) || !stringField(fields, "kind", &expression.Kind) {
		return expression, false
	}
	switch expression.Kind {
	case "condition":
		budget.conditions++
		if budget.conditions > 32 || len(fields) != 2 || !required(fields, "condition") {
			return expression, false
		}
		var condition CatalogFilter
		decoder := json.NewDecoder(bytes.NewReader(fields["condition"]))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&condition) != nil || !condition.Valid() {
			return expression, false
		}
		if condition.NativeValue != nil {
			budget.nativeBytes += condition.NativeValue.encodedSize()
			if budget.nativeBytes > NativeCellFilterBudget {
				return expression, false
			}
		}
		expression.Condition = &condition
	case "and", "or":
		if len(fields) != 2 || !required(fields, "children") {
			return expression, false
		}
		var children []json.RawMessage
		if json.Unmarshal(fields["children"], &children) != nil || len(children) == 0 || len(children) > 64 {
			return expression, false
		}
		for _, raw := range children {
			child, ok := parseFilterExpression(raw, depth+1, budget)
			if !ok {
				return expression, false
			}
			expression.Children = append(expression.Children, child)
		}
	default:
		return expression, false
	}
	return expression, true
}
