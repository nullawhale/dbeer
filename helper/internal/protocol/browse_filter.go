package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"unicode/utf8"
)

const BrowseFilterTreeCapability = "browseFilterTreeV1"

// CatalogFilterExpression is a bounded predicate, never executable SQL/CQL.
// A condition has only Condition; an and/or group has only nonempty Children.
type CatalogFilterExpression struct {
	Kind      string                    `json:"kind"`
	Condition *CatalogFilter            `json:"condition,omitempty"`
	Children  []CatalogFilterExpression `json:"children,omitempty"`
}

type filterBudget struct{ nodes, conditions int }

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
		return budget.conditions <= 32 && expression.Children == nil && expression.Condition != nil && expression.Condition.Valid()
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
	switch filter.Operator {
	case "eq", "ne", "lt", "lte", "gt", "gte", "contains":
		return filter.Value != nil && len(*filter.Value) <= 1024*1024 && utf8.ValidString(*filter.Value) && !strings.ContainsRune(*filter.Value, 0)
	case "isNull", "isNotNull":
		return filter.Value == nil
	default:
		return false
	}
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
	for _, filter := range request.Filters {
		if !filter.Valid() {
			return nil, false
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
