package mysql

import (
	sc "dbeer/helper/internal/schemacompare"
	"encoding/base64"
	"encoding/hex"
	"regexp"
	"strings"
	"unicode/utf8"
)

var schemaTypePattern = regexp.MustCompile(`^([a-z]+)(?:\(([0-9]+)(?:,([0-9]+))?\))?( unsigned)?( zerofill)?$`)

// COLUMN_TYPE uses the server's fixed catalog escaping, including when the
// session enables NO_BACKSLASH_ESCAPES. It is not an arbitrary SQL expression.
// MySQL's Field_enum/Field_set::sql_type call append_unescaped in sql/table.cc.
func mysqlTypeLabels(definition, kind string) ([]string, bool) {
	if !strings.HasPrefix(definition, kind+"(") || !strings.HasSuffix(definition, ")") {
		return nil, false
	}
	input := definition[len(kind)+1 : len(definition)-1]
	labels := []string{}
	for len(input) > 0 {
		if strings.HasPrefix(input, "x'") || strings.HasPrefix(input, "X'") {
			end := strings.IndexByte(input[2:], '\'')
			if end < 0 {
				return nil, false
			}
			decoded, err := hex.DecodeString(input[2 : 2+end])
			if err != nil {
				return nil, false
			}
			labels = append(labels, string(decoded))
			input = input[3+end:]
			if len(input) == 0 {
				return labels, true
			}
			if input[0] != ',' || len(input) == 1 {
				return nil, false
			}
			input = input[1:]
			continue
		}
		if input[0] != '\'' {
			return nil, false
		}
		input = input[1:]
		var label strings.Builder
		closed := false
		for len(input) > 0 {
			c := input[0]
			input = input[1:]
			if c == '\'' {
				if len(input) > 0 && input[0] == '\'' {
					label.WriteByte('\'')
					input = input[1:]
					continue
				}
				closed = true
				break
			}
			if c == '\\' {
				if len(input) == 0 {
					return nil, false
				}
				switch input[0] {
				case '0':
					c = 0
				case 'n':
					c = '\n'
				case 'r':
					c = '\r'
				case '\\':
					c = '\\'
				default:
					return nil, false
				}
				input = input[1:]
			}
			label.WriteByte(c)
		}
		if !closed {
			return nil, false
		}
		labels = append(labels, label.String())
		if len(input) == 0 {
			return labels, true
		}
		if input[0] != ',' || len(input) == 1 {
			return nil, false
		}
		input = input[1:]
	}
	return nil, false
}

func mysqlAmbiguousChoiceLabels(kind string, labels []string) bool {
	seen := map[string]bool{}
	for _, label := range labels {
		if seen[label] || kind == "set" && (label == "" || strings.Contains(label, ",")) {
			return true
		}
		seen[label] = true
	}
	return false
}

func mysqlSchemaType(datatype, definition, charset, length, precision, scale, datetimePrecision, srid string) sc.TypeUse {
	m := sc.TypeModifiers{Length: myNumber(length), Precision: myNumber(precision), Scale: myNumber(scale), DatetimePrecision: myNumber(datetimePrecision), SpatialReferenceID: myNumber(srid)}
	u := sc.TypeUse{Ref: sc.Ref{Kind: "type", Name: datatype}, Kind: "builtin", Modifiers: sc.Known(m), Labels: sc.Complete[string](nil)}
	if datatype == "enum" || datatype == "set" {
		u.Kind = datatype
		// I_S reports NULL character set/collation for the binary character set.
		if charset == "" {
			charset = "binary"
		}
		labels, ok := mysqlTypeLabels(definition, datatype)
		if ok {
			for i, label := range labels {
				if charset == "binary" {
					labels[i] = base64.StdEncoding.EncodeToString([]byte(label))
				} else if !utf8.ValidString(label) {
					ok = false
				}
			}
		}
		if !ok {
			u.Labels = sc.Collection[string]{Items: []string{}, State: "unsupported", Code: "inlineTypeLabels", Complete: false}
		} else {
			u.Labels = sc.Complete(labels)
			if charset == "binary" {
				u.LabelEncoding = "base64"
			}
		}
		return u
	}
	parts := schemaTypePattern.FindStringSubmatch(definition)
	if parts == nil || parts[1] != datatype {
		u.Modifiers = sc.Unknown[sc.TypeModifiers]("typeModifiers")
		return u
	}
	m.Unsigned, m.Zerofill = parts[4] != "", parts[5] != ""
	switch datatype {
	case "bit", "vector":
		// BIT precision and VECTOR dimensions are not character lengths.
		m.Length = myNumber(parts[2])
	case "tinyint", "smallint", "mediumint", "int", "bigint", "year":
		// Preserve display widths reported by the catalog, including TINYINT(1).
		m.Length = myNumber(parts[2])
	case "float", "double":
		// Only COLUMN_TYPE retains the declared FLOAT/DOUBLE(M,D) attributes;
		// NUMERIC_PRECISION also reports widths for unparameterized types.
		m.Precision, m.Scale = myNumber(parts[2]), myNumber(parts[3])
	}
	u.Modifiers = sc.Known(m)
	return u
}

func spatialType(kind string) bool {
	switch kind {
	case "geometry", "point", "linestring", "polygon", "multipoint", "multilinestring", "multipolygon", "geometrycollection", "geomcollection":
		return true
	}
	return false
}

// JSON replaces invalid UTF-8 bytes. Encode catalog scalars before hashing so
// different binary-character-set labels can never share a metadata digest.
func mysqlRawRows(rows [][]*string) [][]*string {
	encoded := make([][]*string, len(rows))
	for i, row := range rows {
		encoded[i] = make([]*string, len(row))
		for j, value := range row {
			if value != nil {
				scalar := base64.StdEncoding.EncodeToString([]byte(*value))
				encoded[i][j] = &scalar
			}
		}
	}
	return encoded
}
