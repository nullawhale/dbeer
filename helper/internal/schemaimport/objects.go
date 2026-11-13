package schemaimport

import (
	"context"
	"strconv"
	"strings"

	sc "dbeer/helper/internal/schemacompare"
)

func parseEnum(stmt []token, defaultSchema string) (sc.TypeDefinition, error) {
	c := cursor{ts: stmt, engine: "postgresql"}
	if !c.take("CREATE") || !c.take("TYPE") {
		return sc.TypeDefinition{}, ErrUnsupported
	}
	schema, name, e := c.qualified(defaultSchema)
	if e != nil || !sc.ValidName(schema) || !c.take("AS") || !c.take("ENUM") {
		return sc.TypeDefinition{}, ErrUnsupported
	}
	body, e := c.group()
	if e != nil || c.i != len(stmt) {
		return sc.TypeDefinition{}, ErrUnsupported
	}
	terms, e := commaTerms(body)
	if e != nil || len(terms) == 0 {
		return sc.TypeDefinition{}, ErrUnsupported
	}
	labels := []string{}
	seen := map[string]bool{}
	for _, term := range terms {
		if len(term) != 1 || term[0].kind != 's' || seen[term[0].value] {
			return sc.TypeDefinition{}, ErrUnsupported
		}
		labels = append(labels, term[0].value)
		seen[term[0].value] = true
	}
	comment := ""
	return sc.TypeDefinition{Ref: sc.Ref{Kind: "type", Schema: schema, Name: name}, Kind: sc.Known("e"), Labels: sc.Complete(labels), Base: sc.Absent[sc.TypeUse](), Default: sc.Known(sc.Default{Kind: "none"}), Nullable: sc.Known(true), Checks: sc.Complete[sc.Constraint](nil), Attributes: sc.Complete[sc.Column](nil), Comment: &comment}, nil
}
func parseSequence(stmt []token, defaultSchema string) (sc.Sequence, error) {
	c := cursor{ts: stmt, engine: "postgresql"}
	if !c.take("CREATE") || !c.take("SEQUENCE") {
		return sc.Sequence{}, ErrUnsupported
	}
	schema, name, e := c.qualified(defaultSchema)
	if e != nil || !sc.ValidName(schema) || !c.take("AS") {
		return sc.Sequence{}, ErrUnsupported
	}
	start := c.i
	for c.i < len(stmt) && !stmt[c.i].is("START") {
		c.i++
	}
	typ, e := builtinType(stmt[start:c.i], "postgresql")
	if e != nil || typ.Kind != "builtin" || (typ.Ref.Name != "int2" && typ.Ref.Name != "int4" && typ.Ref.Name != "int8") {
		return sc.Sequence{}, ErrUnsupported
	}
	sequence := sc.Sequence{Ref: sc.Ref{Kind: "sequence", Schema: schema, Name: name}, Type: sc.Known(typ), Cycle: sc.Known(false), Owner: sc.Absent[sc.Ref]()}
	number := func() (string, error) {
		i := c.i
		if c.i < len(stmt) && (stmt[c.i].value == "-" || stmt[c.i].value == "+") {
			c.i++
		}
		if c.i >= len(stmt) || stmt[c.i].kind != 'n' {
			return "", ErrUnsupported
		}
		c.i++
		n, e := intLiteral(stmt[i:c.i])
		if e != nil {
			return "", e
		}
		return strconv.FormatInt(n, 10), nil
	}
	if !c.take("START") || !c.take("WITH") {
		return sequence, ErrUnsupported
	}
	value, e := number()
	if e != nil {
		return sequence, e
	}
	sequence.Start = sc.Known(value)
	if !c.take("INCREMENT") || !c.take("BY") {
		return sequence, ErrUnsupported
	}
	value, e = number()
	if e != nil || value == "0" {
		return sequence, ErrUnsupported
	}
	sequence.Increment = sc.Known(value)
	if !c.take("MINVALUE") {
		return sequence, ErrUnsupported
	}
	value, e = number()
	if e != nil {
		return sequence, e
	}
	sequence.Min = sc.Known(value)
	if !c.take("MAXVALUE") {
		return sequence, ErrUnsupported
	}
	value, e = number()
	if e != nil {
		return sequence, e
	}
	sequence.Max = sc.Known(value)
	if !c.take("CACHE") {
		return sequence, ErrUnsupported
	}
	value, e = number()
	if e != nil || strings.HasPrefix(value, "-") || value == "0" {
		return sequence, ErrUnsupported
	}
	sequence.Cache = sc.Known(value)
	if c.take("NO") {
		if !c.take("CYCLE") {
			return sequence, ErrUnsupported
		}
	} else if c.take("CYCLE") {
		sequence.Cycle = sc.Known(true)
	} else {
		return sequence, ErrUnsupported
	}
	if c.take("OWNED") {
		if !c.take("BY") {
			return sequence, ErrUnsupported
		}
		if !c.take("NONE") {
			ownerSchema, ownerTable, e := c.qualified(schema)
			if e != nil || !c.take(".") {
				return sequence, ErrUnsupported
			}
			column, e := c.ident()
			if e != nil {
				return sequence, e
			}
			sequence.Owner = sc.Known(sc.Ref{Kind: "column", Schema: ownerSchema, Table: ownerTable, Name: column})
		}
	}
	if c.i != len(stmt) {
		return sequence, ErrUnsupported
	}
	min, _ := strconv.ParseInt(*sequence.Min.Value, 10, 64)
	max, _ := strconv.ParseInt(*sequence.Max.Value, 10, 64)
	initial, _ := strconv.ParseInt(*sequence.Start.Value, 10, 64)
	low, high := int64(-9223372036854775807-1), int64(9223372036854775807)
	if typ.Ref.Name == "int2" {
		low, high = -32768, 32767
	} else if typ.Ref.Name == "int4" {
		low, high = -2147483648, 2147483647
	}
	if min < low || max > high || min >= max || initial < min || initial > max {
		return sequence, ErrUnsupported
	}
	return sequence, nil
}

type objectEdits struct {
	types                        map[string]sc.TypeDefinition
	sequences                    map[string]sc.Sequence
	removeTypes, removeSequences map[string]bool
}

func newObjectEdits() *objectEdits {
	return &objectEdits{types: map[string]sc.TypeDefinition{}, sequences: map[string]sc.Sequence{}, removeTypes: map[string]bool{}, removeSequences: map[string]bool{}}
}
func (e *objectEdits) remove(ref sc.Ref) error {
	switch ref.Kind {
	case "type":
		if ref.RowType {
			return ErrUnsupported
		}
		e.removeTypes[refKey(ref)] = true
	case "sequence":
		e.removeSequences[refKey(ref)] = true
	default:
		return ErrUnsupported
	}
	return nil
}
func (e *objectEdits) apply(ctx context.Context, file SQLFile, ast definitionAST, original sc.Capture, defaultSchema string, seen map[string]bool) (bool, error) {
	if original.Context.Engine != "postgresql" {
		return false, ErrUnsupported
	}
	if file.Ref != nil {
		if err := e.remove(*file.Ref); err != nil {
			return false, err
		}
	}
	objects := 0
	var primary *sc.Ref
	for _, stmt := range ast.other {
		if err := ctx.Err(); err != nil {
			return false, err
		}
		if len(stmt) >= 2 && stmt[0].is("CREATE") && stmt[1].is("TYPE") {
			typ, err := parseEnum(stmt, defaultSchema)
			if err != nil {
				return false, err
			}
			key := refKey(typ.Ref)
			if seen[key] {
				return false, ErrInvalid
			}
			seen[key] = true
			e.types[key] = typ
			objects++
			r := typ.Ref
			primary = &r
		} else if len(stmt) >= 2 && stmt[0].is("CREATE") && stmt[1].is("SEQUENCE") {
			sequence, err := parseSequence(stmt, defaultSchema)
			if err != nil {
				return false, err
			}
			key := refKey(sequence.Ref)
			if seen[key] {
				return false, ErrInvalid
			}
			seen[key] = true
			e.sequences[key] = sequence
			objects++
			r := sequence.Ref
			primary = &r
		} else if len(stmt) >= 3 && stmt[0].is("COMMENT") && stmt[1].is("ON") && stmt[2].is("TYPE") {
			c := cursor{ts: stmt, engine: "postgresql", i: 3}
			schema, name, err := c.qualified(defaultSchema)
			if err != nil || !c.take("IS") || c.i+1 != len(stmt) || stmt[c.i].kind != 's' {
				return false, ErrUnsupported
			}
			key := refKey(sc.Ref{Kind: "type", Schema: schema, Name: name})
			typ, ok := e.types[key]
			if !ok {
				return false, ErrUnsupported
			}
			comment := stmt[c.i].value
			typ.Comment = &comment
			e.types[key] = typ
		} else {
			return false, ErrUnsupported
		}
	}
	if file.Ref != nil && !file.Changed {
		if objects != 1 || primary == nil || *primary != *file.Ref {
			return false, ErrInvalid
		}
		if primary.Kind == "type" {
			for _, old := range original.Types {
				if old.Ref == *primary {
					if !sameJSON(old, e.types[refKey(*primary)]) {
						return false, ErrInvalid
					}
					return true, nil
				}
			}
		} else {
			for _, old := range original.Sequences {
				if old.Ref == *primary {
					if !sameJSON(old, e.sequences[refKey(*primary)]) {
						return false, ErrInvalid
					}
					return true, nil
				}
			}
		}
		return false, ErrInvalid
	}
	return true, nil
}
func (e *objectEdits) finish(c *sc.Capture) {
	types := []sc.TypeDefinition{}
	for _, old := range c.Types {
		key := refKey(old.Ref)
		if current, ok := e.types[key]; ok {
			types = append(types, current)
			delete(e.types, key)
		} else if !e.removeTypes[key] {
			types = append(types, old)
		}
	}
	for _, current := range e.types {
		types = append(types, current)
	}
	c.Types = types
	sequences := []sc.Sequence{}
	for _, old := range c.Sequences {
		key := refKey(old.Ref)
		if current, ok := e.sequences[key]; ok {
			sequences = append(sequences, current)
			delete(e.sequences, key)
		} else if !e.removeSequences[key] {
			sequences = append(sequences, old)
		}
	}
	for _, current := range e.sequences {
		sequences = append(sequences, current)
	}
	c.Sequences = sequences
	schemas := map[string]bool{}
	for _, i := range c.Inventories {
		schemas[i.Schema] = true
	}
	for _, t := range c.Types {
		if !schemas[t.Ref.Schema] {
			c.Inventories = append(c.Inventories, sc.Inventory{Schema: t.Ref.Schema, Existence: "present", Tables: sc.Complete[sc.Ref](nil), Types: sc.Complete[sc.Ref](nil)})
			schemas[t.Ref.Schema] = true
		}
	}
	for _, s := range c.Sequences {
		if !schemas[s.Ref.Schema] {
			c.Inventories = append(c.Inventories, sc.Inventory{Schema: s.Ref.Schema, Existence: "present", Tables: sc.Complete[sc.Ref](nil), Types: sc.Complete[sc.Ref](nil)})
			schemas[s.Ref.Schema] = true
		}
	}
	for i := range c.Inventories {
		refs := []sc.Ref{}
		for _, typ := range c.Types {
			if typ.Ref.Schema == c.Inventories[i].Schema && !typ.Ref.RowType {
				refs = append(refs, typ.Ref)
			}
		}
		c.Inventories[i].Types.Items = refs
	}
}
