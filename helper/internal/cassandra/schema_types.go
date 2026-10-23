package cassandra

import (
	"encoding/json"
	"strconv"
	"strings"
	"unicode/utf8"

	sc "dbeer/helper/internal/schemacompare"
	gocql "github.com/apache/cassandra-gocql-driver/v2"
)

// Parse catalog CQL types into typed references, so schema/name mappings also
// apply inside frozen collections, tuples, vectors and user-defined types.
func cassandraType(text, keyspace string) (sc.TypeUse, error) {
	if len(text) == 0 || len(text) > 65536 || !utf8.ValidString(text) {
		return sc.TypeUse{}, sc.ErrInvalid
	}
	p := cqlTypeParser{text: text, keyspace: keyspace}
	u, err := p.typ(0)
	p.space()
	if err != nil || p.offset != len(text) {
		return sc.TypeUse{}, sc.ErrInvalid
	}
	return u, nil
}

// Protocol result metadata includes UDT field definitions, unlike its display
// name. Preserve that graph for saved-result comparisons as well as catalogs.
func cassandraResultTypeIdentity(info gocql.TypeInfo) string {
	definitions := map[sc.Ref]sc.TypeDefinition{}
	wireClasses := []string{}
	unresolved := false
	var convert func(gocql.TypeInfo, int) (sc.TypeUse, error)
	convert = func(info gocql.TypeInfo, depth int) (sc.TypeUse, error) {
		if info == nil || depth >= 64 {
			return sc.TypeUse{}, sc.ErrInvalid
		}
		u, err := cassandraType(typeName(info), "")
		if err != nil {
			return u, err
		}
		switch typ := info.(type) {
		case gocql.UDTTypeInfo:
			if _, seen := definitions[u.Ref]; seen {
				return u, nil
			}
			d := sc.TypeDefinition{Ref: u.Ref, Kind: sc.Known("udt"), Labels: sc.Complete[string](nil), Base: sc.Absent[sc.TypeUse](), Default: sc.Known(sc.Default{Kind: "none"}), Nullable: sc.Known(true), Checks: sc.Complete[sc.Constraint](nil), Attributes: sc.Complete[sc.Column](nil)}
			definitions[u.Ref] = d
			for i, field := range typ.Elements {
				child, err := convert(field.Type, depth+1)
				if err != nil {
					return u, err
				}
				d.Attributes.Items = append(d.Attributes.Items, cassandraColumn(u.Ref, field.Name, i, child, true))
			}
			definitions[u.Ref] = d
		case gocql.TupleTypeInfo:
			u.Arguments = nil
			for _, element := range typ.Elems {
				child, err := convert(element, depth+1)
				if err != nil {
					return u, err
				}
				u.Arguments = append(u.Arguments, child)
			}
		case gocql.CollectionType:
			child, err := convert(typ.Elem, depth+1)
			if err != nil {
				return u, err
			}
			if typ.Type() == gocql.TypeMap {
				key, err := convert(typ.Key, depth+1)
				if err != nil {
					return u, err
				}
				u.Arguments = []sc.TypeUse{key, child}
			} else {
				u.Element = &child
			}
		case gocql.VectorType:
			if typ.WireCustomClass != "" {
				wireClasses = append(wireClasses, typ.WireCustomClass)
			}
			child, err := convert(typ.SubType, depth+1)
			if err != nil {
				return u, err
			}
			u.Element = &child
		default:
			if info.Type() == gocql.TypeCustom {
				unresolved = true
			}
		}
		return u, nil
	}
	u, err := convert(info, 0)
	if err != nil {
		return "unresolved:" + typeName(info)
	}
	defs := make([]sc.TypeDefinition, 0, len(definitions))
	for _, definition := range definitions {
		defs = append(defs, definition)
	}
	identity, err := cassandraTypeIdentity(u, defs)
	if err != nil {
		return "unresolved:" + typeName(info)
	}
	if len(wireClasses) > 0 {
		encoded, err := json.Marshal(struct {
			StructuralType    string   `json:"structuralType"`
			WireCustomClasses []string `json:"wireCustomClasses"`
		}{identity, wireClasses})
		if err != nil {
			return "unresolved:" + typeName(info)
		}
		identity = string(encoded)
	}
	if unresolved {
		return "unresolved:" + identity
	}
	return identity
}

type cqlTypeParser struct {
	text, keyspace string
	offset         int
}

func (p *cqlTypeParser) space() {
	for p.offset < len(p.text) && strings.ContainsRune(" \n\r\t", rune(p.text[p.offset])) {
		p.offset++
	}
}
func (p *cqlTypeParser) token(c byte) bool {
	p.space()
	if p.offset < len(p.text) && p.text[p.offset] == c {
		p.offset++
		return true
	}
	return false
}
func (p *cqlTypeParser) name(quote byte) (string, bool, error) {
	p.space()
	start := p.offset
	if p.offset < len(p.text) && p.text[p.offset] == quote {
		p.offset++
		var b strings.Builder
		for p.offset < len(p.text) {
			c := p.text[p.offset]
			p.offset++
			if c == quote {
				if p.offset < len(p.text) && p.text[p.offset] == quote {
					p.offset++
				} else {
					if b.Len() == 0 || strings.ContainsRune(b.String(), 0) {
						return "", true, sc.ErrInvalid
					}
					return b.String(), true, nil
				}
			}
			b.WriteByte(c)
		}
		return "", true, sc.ErrInvalid
	}
	for p.offset < len(p.text) {
		c := p.text[p.offset]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_' || p.offset > start && c >= '0' && c <= '9') {
			break
		}
		p.offset++
	}
	if p.offset == start {
		return "", false, sc.ErrInvalid
	}
	return strings.ToLower(p.text[start:p.offset]), false, nil
}
func (p *cqlTypeParser) typ(depth int) (sc.TypeUse, error) {
	u := sc.TypeUse{Modifiers: sc.Known(sc.TypeModifiers{}), Labels: sc.Complete[string](nil)}
	if depth >= 64 {
		return u, sc.ErrLimit
	}
	p.space()
	if p.offset < len(p.text) && p.text[p.offset] == '\'' {
		name, _, err := p.name('\'')
		u.Kind, u.Ref = "custom", sc.Ref{Kind: "type", Name: name}
		return u, err
	}
	name, quoted, err := p.name('"')
	if err != nil {
		return u, err
	}
	u.Ref = sc.Ref{Kind: "type", Name: name}
	if p.token('.') {
		member, _, err := p.name('"')
		u.Kind, u.Ref = "udt", sc.Ref{Kind: "type", Schema: name, Name: member}
		return u, err
	}
	if !quoted && p.token('<') {
		u.Kind = name
		switch name {
		case "list", "set", "frozen", "vector":
			child, err := p.typ(depth + 1)
			if err != nil {
				return u, err
			}
			u.Element = &child
			if name == "vector" {
				if !p.token(',') {
					return u, sc.ErrInvalid
				}
				p.space()
				start := p.offset
				for p.offset < len(p.text) && p.text[p.offset] >= '0' && p.text[p.offset] <= '9' {
					p.offset++
				}
				dimensions, err := strconv.ParseInt(p.text[start:p.offset], 10, 64)
				if err != nil || dimensions < 1 || dimensions > 65535 {
					return u, sc.ErrInvalid
				}
				u.Modifiers.Value.Length = &dimensions
			}
		case "map", "tuple":
			for {
				child, err := p.typ(depth + 1)
				if err != nil {
					return u, err
				}
				u.Arguments = append(u.Arguments, child)
				if len(u.Arguments) > 1024 {
					return u, sc.ErrLimit
				}
				if !p.token(',') {
					break
				}
			}
			if name == "map" && len(u.Arguments) != 2 {
				return u, sc.ErrInvalid
			}
		default:
			return u, sc.ErrInvalid
		}
		if !p.token('>') {
			return u, sc.ErrInvalid
		}
		return u, nil
	}
	if !quoted && browseScalarType(name) {
		u.Kind = "builtin"
		if name == "varchar" {
			u.Ref.Name = "text"
		}
	} else {
		u.Kind, u.Ref.Schema = "udt", p.keyspace
	}
	return u, nil
}

func visitCassandraType(u sc.TypeUse, visit func(sc.TypeUse) error) error {
	if err := visit(u); err != nil {
		return err
	}
	if u.Element != nil {
		if err := visitCassandraType(*u.Element, visit); err != nil {
			return err
		}
	}
	for _, argument := range u.Arguments {
		if err := visitCassandraType(argument, visit); err != nil {
			return err
		}
	}
	return nil
}

// Resolve identifiers without rewriting captured CQL. Unrecognized syntax or
// names remain explicitly incomplete instead of claiming mapped equivalence.
func cassandraViewExpression(text string, table sc.Ref, columns []sc.Column) sc.Expression {
	e := sc.Expression{Text: text, Dependencies: sc.Complete[sc.Ref](nil)}
	byName := map[string]sc.Ref{}
	for _, column := range columns {
		byName[column.Ref.Name] = column.Ref
	}
	seen := map[sc.Ref]bool{}
	p := cqlTypeParser{text: text}
	complete := text != ""
	for p.offset < len(text) {
		p.space()
		if p.offset == len(text) {
			break
		}
		c := text[p.offset]
		if c == '\'' {
			if _, _, err := p.name('\''); err != nil {
				complete = false
				break
			}
			continue
		}
		if c == '"' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_' {
			name, quoted, err := p.name('"')
			if err != nil {
				complete = false
				break
			}
			if !quoted && strings.Contains("|is|not|null|and|or|in|true|false|", "|"+name+"|") {
				continue
			}
			if ref, ok := byName[name]; ok {
				if !seen[ref] {
					seen[ref] = true
					e.Dependencies.Items = append(e.Dependencies.Items, ref)
				}
			} else {
				complete = false
			}
			continue
		}
		if c >= '0' && c <= '9' {
			for p.offset < len(text) && !strings.ContainsRune(" \t\r\n,()[]{}=<>!", rune(text[p.offset])) {
				p.offset++
			}
			continue
		}
		if !strings.ContainsRune("=<>!+-.,()[]{}:", rune(c)) {
			complete = false
		}
		p.offset++
	}
	if !complete {
		e.Dependencies.Complete = false
		e.Dependencies.State = "unsupported"
		e.Dependencies.Code = "viewPredicateDependencies"
	}
	return e
}
