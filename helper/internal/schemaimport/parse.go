package schemaimport

import (
	"context"
	"regexp"
	"strconv"

	sc "dbeer/helper/internal/schemacompare"
)

type columnAST struct {
	name      string
	typ       []token
	attrs     map[string][]token
	raw       []token
	supported bool
}
type tableAST struct {
	ref            sc.Ref
	columns        []columnAST
	members        [][]token
	prefix, suffix []token
	statements     [][]token
	unlogged       bool
}
type definitionAST struct {
	tables []tableAST
	other  [][]token
	safe   bool
}

func parseDefinition(ctx context.Context, sql, engine, defaultSchema string, noBackslash bool) (definitionAST, error) {
	var result definitionAST
	ts, err := lex(ctx, sql, engine, noBackslash)
	if err != nil {
		return result, err
	}
	stmts, err := statements(ts)
	if err != nil {
		return result, err
	}
	result.safe = true
	for _, stmt := range stmts {
		c := cursor{ts: stmt, engine: engine}
		if c.take("CREATE") {
			prefixEnd := c.i
			unlogged := c.take("UNLOGGED")
			if unlogged && engine != "postgresql" {
				return result, ErrUnsupported
			}
			if c.take("TABLE") {
				if c.take("IF") {
					if !c.take("NOT") || !c.take("EXISTS") {
						return result, ErrUnsupported
					}
				}
				schema, name, e := c.qualified(defaultSchema)
				if e != nil || !sc.ValidName(schema) || !sc.ValidName(name) {
					return result, ErrUnsupported
				}
				body, e := c.group()
				if e != nil {
					return result, e
				}
				terms, e := commaTerms(body)
				if e != nil || len(terms) == 0 {
					return result, ErrUnsupported
				}
				table := tableAST{ref: sc.Ref{Kind: "table", Schema: schema, Name: name}, prefix: stmt[:prefixEnd], suffix: stmt[c.i:], statements: [][]token{stmt}, unlogged: unlogged}
				seen := map[string]bool{}
				for _, term := range terms {
					if len(term) == 0 {
						return result, ErrUnsupported
					}
					if term[0].is("CONSTRAINT") || term[0].is("PRIMARY") || term[0].is("UNIQUE") || term[0].is("FOREIGN") || term[0].is("CHECK") || term[0].is("KEY") || term[0].is("INDEX") || term[0].is("FULLTEXT") || term[0].is("SPATIAL") {
						table.members = append(table.members, term)
						continue
					}
					column, e := parseColumn(term, engine)
					if e != nil || seen[column.name] {
						return result, ErrUnsupported
					}
					seen[column.name] = true
					table.columns = append(table.columns, column)
				}
				if len(table.columns) == 0 || len(table.columns) > 1600 {
					return result, ErrLimit
				}
				result.tables = append(result.tables, table)
				continue
			}
			c.i = 1
			if c.take("UNIQUE") {
			}
			if c.take("INDEX") || c.take("TYPE") || c.take("SEQUENCE") || c.take("SCHEMA") || c.take("DATABASE") || engine == "sqlite" && c.take("TRIGGER") {
				result.other = append(result.other, stmt)
				continue
			}
			return result, ErrUnsupported
		}
		if c.take("ALTER") && c.take("TABLE") {
			_, _, e := c.qualified(defaultSchema)
			if e != nil || !c.take("ADD") {
				return result, ErrUnsupported
			}
			result.other = append(result.other, stmt)
			continue
		}
		if engine == "postgresql" && c.take("COMMENT") && c.take("ON") {
			if !c.take("COLUMN") && !c.take("TABLE") && !c.take("TYPE") {
				return result, ErrUnsupported
			}
			result.other = append(result.other, stmt)
			continue
		}
		return result, ErrUnsupported
	}
	return result, nil
}
func attrStart(ts []token, i int) bool {
	t := ts[i]
	for _, s := range []string{"NOT", "NULL", "DEFAULT", "GENERATED", "PRIMARY", "UNIQUE", "REFERENCES", "COLLATE", "CHARSET", "COMMENT", "ON", "VISIBLE", "INVISIBLE", "AUTO_INCREMENT", "CONSTRAINT", "CHECK"} {
		if t.is(s) {
			return true
		}
	}
	return t.is("CHARACTER") && i+1 < len(ts) && ts[i+1].is("SET")
}
func parseColumn(ts []token, engine string) (columnAST, error) {
	result := columnAST{attrs: map[string][]token{}, raw: ts, supported: true}
	c := cursor{ts: ts, engine: engine}
	name, e := c.ident()
	if e != nil {
		return result, e
	}
	result.name = name
	start := c.i
	depth := 0
	for c.i < len(ts) {
		t := ts[c.i]
		if depth == 0 && attrStart(ts, c.i) {
			break
		}
		if t.kind == 'p' && t.value == "(" {
			depth++
		}
		if t.kind == 'p' && t.value == ")" {
			depth--
		}
		if depth < 0 {
			return result, ErrInvalid
		}
		c.i++
	}
	result.typ = ts[start:c.i]
	if len(result.typ) == 0 {
		return result, ErrUnsupported
	}
	for c.i < len(ts) {
		start = c.i
		key := ""
		switch {
		case c.take("NOT"):
			if !c.take("NULL") {
				return result, ErrUnsupported
			}
			key = "nullable"
			result.attrs[key] = ts[start:c.i]
		case c.take("NULL"):
			key = "nullable"
			result.attrs[key] = ts[start:c.i]
		case c.take("DEFAULT"):
			key = "default"
			valueStart := c.i
			depth = 0
			for c.i < len(ts) {
				t := ts[c.i]
				if depth == 0 && c.i > valueStart && attrStart(ts, c.i) {
					break
				}
				if t.kind == 'p' && t.value == "(" {
					depth++
				}
				if t.kind == 'p' && t.value == ")" {
					depth--
				}
				c.i++
			}
			if c.i == valueStart {
				return result, ErrUnsupported
			}
			result.attrs[key] = ts[valueStart:c.i]
		case c.take("COLLATE"):
			key = "collation"
			if _, _, e = c.qualified(""); e != nil {
				return result, e
			}
			result.attrs[key] = ts[start+1 : c.i]
		case c.take("CHARACTER"):
			if !c.take("SET") {
				return result, ErrUnsupported
			}
			fallthrough
		case c.take("CHARSET"):
			key = "charset"
			if _, e = c.ident(); e != nil {
				return result, e
			}
			result.attrs[key] = ts[c.i-1 : c.i]
		case c.take("COMMENT"):
			key = "comment"
			if c.i >= len(ts) || ts[c.i].kind != 's' {
				return result, ErrUnsupported
			}
			c.i++
			result.attrs[key] = ts[c.i-1 : c.i]
		case c.take("AUTO_INCREMENT"):
			key = "identity"
			result.attrs[key] = ts[start:c.i]
		case c.take("VISIBLE"), c.take("INVISIBLE"):
			key = "visible"
			result.attrs[key] = ts[start:c.i]
		default:
			// Unknown clauses remain visible for a byte-equivalent historical
			// definition, but are never inferred or modified by this parser.
			result.supported = false
			result.attrs["opaque"] = ts[c.i:]
			c.i = len(ts)
		}
		if key != "" {
			if result.attrs["seen:"+key] != nil {
				return result, ErrUnsupported
			}
			result.attrs["seen:"+key] = []token{{}}
		}
	}
	return result, nil
}

var numberPattern = regexp.MustCompile(`^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$`)

func pureDefault(ts []token, engine string) (sc.Default, error) {
	if len(ts) == 0 {
		return sc.Default{Kind: "none"}, nil
	}
	if len(ts) == 1 && ts[0].is("NULL") {
		return sc.Default{Kind: "sqlNull"}, nil
	}
	if len(ts) == 1 && ts[0].kind == 's' {
		value := ts[0].value
		return sc.Default{Kind: "literal", Encoding: "text", Value: &value}, nil
	}
	if engine == "postgresql" && len(ts) == 6 && ts[0].is("NEXTVAL") && ts[1].value == "(" && ts[2].kind == 's' && ts[3].value == "::" && ts[4].is("REGCLASS") && ts[5].value == ")" {
		nameTokens, e := lex(context.Background(), ts[2].value, "postgresql", false)
		if e != nil {
			return sc.Default{}, e
		}
		c := cursor{ts: nameTokens, engine: "postgresql"}
		schema, name, e := c.qualified("")
		if e != nil || schema == "" || c.i != len(nameTokens) {
			return sc.Default{}, ErrUnsupported
		}
		ref := sc.Ref{Kind: "sequence", Schema: schema, Name: name}
		return sc.Default{Kind: "sequence", Sequence: &ref}, nil
	}
	text, numeric := numericText(ts)
	if numeric || len(ts) == 1 && (ts[0].is("TRUE") || ts[0].is("FALSE")) {
		if !numeric {
			text = asciiUpper(ts[0].value)
		}
		if engine == "mysql" {
			return sc.Default{Kind: "literal", Encoding: "text", Value: &text}, nil
		}
		return sc.Default{Kind: "expression", Expression: &sc.Expression{Text: text, Dependencies: sc.Complete[sc.Ref](nil)}}, nil
	}
	return sc.Default{}, ErrUnsupported
}

// Separate numeric tokens must not turn invalid SQL such as "1 2" into 12.
func numericText(ts []token) (string, bool) {
	start, sign := 0, ""
	if len(ts) > 0 && ts[0].kind == 'p' && (ts[0].value == "+" || ts[0].value == "-") {
		start, sign = 1, ts[0].value
	}
	body := ts[start:]
	text := ""
	if len(body) == 1 && body[0].kind == 'n' {
		text = body[0].value
	} else if len(body) == 2 && body[0].value == "." && body[1].kind == 'n' && body[0].end == body[1].start {
		text = "." + body[1].value
	} else {
		return "", false
	}
	text = sign + text
	return text, numberPattern.MatchString(text)
}
func intLiteral(ts []token) (int64, error) {
	text, ok := numericText(ts)
	if !ok {
		return 0, ErrUnsupported
	}
	n, e := strconv.ParseInt(text, 10, 64)
	if e != nil {
		return 0, ErrUnsupported
	}
	return n, nil
}

func builtinType(ts []token, engine string) (sc.TypeUse, error) {
	c := cursor{ts: ts, engine: engine}
	schema, name, e := c.qualified("")
	if e != nil {
		return sc.TypeUse{}, e
	}
	quoted := ts[c.i-1].kind == 'q'
	keyword := schema == "" && !quoted
	if engine == "mysql" && quoted {
		return sc.TypeUse{}, ErrUnsupported
	}
	if !quoted {
		name = asciiLower(name)
	}
	if schema != "" && !(engine == "postgresql" && schema == "pg_catalog") {
		return sc.TypeUse{}, ErrUnsupported
	}
	// Renderers use multiword standard aliases for these builtins.
	if keyword && name == "character" && c.take("VARYING") {
		name = "varchar"
	}
	if keyword && name == "bit" && c.take("VARYING") {
		name = "varbit"
	}
	if keyword && name == "double" && c.take("PRECISION") {
		name = "float8"
	}
	var args []int64
	if c.i < len(ts) && ts[c.i].kind == 'p' && ts[c.i].value == "(" {
		group, e := c.group()
		if e != nil {
			return sc.TypeUse{}, e
		}
		parts, e := commaTerms(group)
		if e != nil || len(parts) > 2 {
			return sc.TypeUse{}, ErrUnsupported
		}
		for _, p := range parts {
			n, e := intLiteral(p)
			if e != nil {
				return sc.TypeUse{}, e
			}
			args = append(args, n)
		}
	}
	if keyword && (name == "timestamp" || name == "time") && c.take("WITH") {
		if !c.take("TIME") || !c.take("ZONE") {
			return sc.TypeUse{}, ErrUnsupported
		}
		name += "tz"
	} else if keyword && (name == "timestamp" || name == "time") && c.take("WITHOUT") {
		if !c.take("TIME") || !c.take("ZONE") {
			return sc.TypeUse{}, ErrUnsupported
		}
	}
	m := sc.TypeModifiers{}
	if engine == "postgresql" {
		aliases := map[string]string{"smallint": "int2", "integer": "int4", "int": "int4", "bigint": "int8", "real": "float4", "double": "float8", "boolean": "bool", "decimal": "numeric", "character": "bpchar"}
		if a := aliases[name]; keyword && a != "" {
			name = a
		}
		allowed := map[string]bool{"int2": true, "int4": true, "int8": true, "float4": true, "float8": true, "bool": true, "numeric": true, "text": true, "varchar": true, "bpchar": true, "bytea": true, "uuid": true, "date": true, "timestamp": true, "timestamptz": true, "time": true, "timetz": true, "json": true, "jsonb": true, "bit": true, "varbit": true, "money": true, "oid": true, "inet": true, "cidr": true, "macaddr": true, "macaddr8": true}
		if !allowed[name] {
			return sc.TypeUse{}, ErrUnsupported
		}
		if len(args) > 0 {
			switch name {
			case "numeric":
				if args[0] < 1 || args[0] > 1000 {
					return sc.TypeUse{}, ErrUnsupported
				}
				m.Precision = &args[0]
				v := int64(0)
				if len(args) == 2 {
					v = args[1]
				}
				if v < -1000 || v > 1000 {
					return sc.TypeUse{}, ErrUnsupported
				}
				m.Scale = &v
			case "varchar", "bpchar", "bit", "varbit":
				if len(args) != 1 || args[0] < 1 || args[0] > 1_000_000 {
					return sc.TypeUse{}, ErrUnsupported
				}
				m.Length = &args[0]
			case "timestamp", "timestamptz", "time", "timetz":
				if len(args) != 1 || args[0] < 0 || args[0] > 6 {
					return sc.TypeUse{}, ErrUnsupported
				}
				m.DatetimePrecision = &args[0]
			default:
				return sc.TypeUse{}, ErrUnsupported
			}
		}
		u := sc.TypeUse{Ref: sc.Ref{Kind: "type", Schema: "pg_catalog", Name: name}, Kind: "builtin", Modifiers: sc.Known(m), Labels: sc.Complete[string](nil)}
		if c.take("[") {
			if !c.take("]") {
				return sc.TypeUse{}, ErrUnsupported
			}
			element := u
			u = sc.TypeUse{Ref: u.Ref, Kind: "array", Element: &element, Modifiers: sc.Known(sc.TypeModifiers{ArrayDimensions: 1}), Labels: sc.Complete[string](nil)}
		}
		if c.i != len(ts) {
			return sc.TypeUse{}, ErrUnsupported
		}
		return u, nil
	}
	aliases := map[string]string{"integer": "int", "numeric": "decimal", "bool": "tinyint", "boolean": "tinyint", "double precision": "double"}
	if a := aliases[name]; a != "" {
		name = a
	}
	if name == "float8" {
		name = "double"
	}
	allowed := map[string]bool{"tinyint": true, "smallint": true, "mediumint": true, "int": true, "bigint": true, "float": true, "double": true, "decimal": true, "char": true, "varchar": true, "binary": true, "varbinary": true, "text": true, "tinytext": true, "mediumtext": true, "longtext": true, "blob": true, "tinyblob": true, "mediumblob": true, "longblob": true, "json": true, "date": true, "time": true, "datetime": true, "timestamp": true, "year": true, "bit": true}
	if !allowed[name] {
		return sc.TypeUse{}, ErrUnsupported
	}
	if len(args) > 0 {
		switch name {
		case "decimal", "float", "double":
			if args[0] < 1 || args[0] > 1000 {
				return sc.TypeUse{}, ErrUnsupported
			}
			m.Precision = &args[0]
			if len(args) == 2 {
				m.Scale = &args[1]
			} else if name == "decimal" {
				v := int64(0)
				m.Scale = &v
			}
		case "time", "datetime", "timestamp":
			if len(args) != 1 || args[0] < 0 || args[0] > 6 {
				return sc.TypeUse{}, ErrUnsupported
			}
			m.DatetimePrecision = &args[0]
		default:
			if len(args) != 1 || args[0] < 1 || args[0] > 1_000_000 {
				return sc.TypeUse{}, ErrUnsupported
			}
			m.Length = &args[0]
		}
	}
	if c.take("UNSIGNED") {
		m.Unsigned = true
	}
	if c.take("ZEROFILL") {
		m.Zerofill = true
		m.Unsigned = true
	}
	if c.i != len(ts) {
		return sc.TypeUse{}, ErrUnsupported
	}
	return sc.TypeUse{Ref: sc.Ref{Kind: "type", Name: name}, Kind: "builtin", Modifiers: sc.Known(m), Labels: sc.Complete[string](nil)}, nil
}

func namedType(ts []token, engine string) (sc.TypeUse, error) {
	if engine != "postgresql" {
		return sc.TypeUse{}, ErrUnsupported
	}
	c := cursor{ts: ts, engine: engine}
	schema, name, e := c.qualified("")
	if e != nil || schema == "" || schema == "pg_catalog" || c.i != len(ts) {
		return sc.TypeUse{}, ErrUnsupported
	}
	return sc.TypeUse{Ref: sc.Ref{Kind: "type", Schema: schema, Name: name}, Kind: "offlineNamed", Modifiers: sc.Known(sc.TypeModifiers{}), Labels: sc.Complete[string](nil)}, nil
}
