package mariadb

import (
	"encoding/base64"
	"encoding/hex"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"dbeer/helper/internal/mysql"
	sc "dbeer/helper/internal/schemacompare"
)

var mariaCatalogNumber = regexp.MustCompile(`^[+-]?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$`)

// Native I_S quotes literal defaults to distinguish them from expressions.
// Decode only the catalog's fixed append_unescaped representation, never SQL.
func mariaCatalogLiteral(input string) (string, bool) {
	if len(input) < 2 || input[0] != '\'' || input[len(input)-1] != '\'' {
		return "", false
	}
	var out strings.Builder
	for i := 1; i < len(input)-1; i++ {
		c := input[i]
		if c == '\'' {
			if i+1 >= len(input)-1 || input[i+1] != '\'' {
				return "", false
			}
			i++
			out.WriteByte(c)
			continue
		}
		if c == '\\' {
			i++
			if i >= len(input)-1 {
				return "", false
			}
			switch input[i] {
			case '0':
				c = 0
			case 'n':
				c = '\n'
			case 'r':
				c = '\r'
			case 'b':
				c = '\b'
			case 't':
				c = '\t'
			case 'Z':
				c = 26
			case '\\', '\'', '"':
				c = input[i]
			default:
				return "", false
			}
		}
		out.WriteByte(c)
	}
	return out.String(), true
}

func mariaSchemaDefault(raw *string, typ sc.TypeUse, charset string) sc.Fact[sc.Default] {
	if raw == nil {
		return sc.Known(sc.Default{Kind: "none"})
	}
	text := *raw
	if text == "NULL" {
		return sc.Known(sc.Default{Kind: "sqlNull"})
	}
	if value, ok := mariaCatalogLiteral(text); ok {
		encoding := "text"
		if charset == "binary" || typ.Ref.Name == "binary" || typ.Ref.Name == "varbinary" || strings.Contains(typ.Ref.Name, "blob") {
			value = base64.StdEncoding.EncodeToString([]byte(value))
			encoding = "base64"
		} else if !utf8.ValidString(value) {
			return sc.Unknown[sc.Default]("nativeDefaultEncoding")
		}
		return sc.Known(sc.Default{Kind: "literal", Type: &typ, Encoding: encoding, Value: &value})
	}
	if typ.Ref.Name == "bit" && len(text) >= 4 && (text[0] == 'b' || text[0] == 'B') && text[1] == '\'' && text[len(text)-1] == '\'' {
		value, e := strconv.ParseUint(text[2:len(text)-1], 2, 64)
		if e != nil {
			return sc.Unknown[sc.Default]("nativeBitDefault")
		}
		decimal := strconv.FormatUint(value, 10)
		return sc.Known(sc.Default{Kind: "literal", Type: &typ, Encoding: "text", Value: &decimal})
	}
	if strings.HasPrefix(text, "0x") || strings.HasPrefix(text, "0X") {
		bytes, err := hex.DecodeString(text[2:])
		if err != nil {
			return sc.Unknown[sc.Default]("nativeHexDefault")
		}
		value := base64.StdEncoding.EncodeToString(bytes)
		return sc.Known(sc.Default{Kind: "literal", Type: &typ, Encoding: "base64", Value: &value})
	}
	if mariaCatalogNumber.MatchString(text) {
		return sc.Known(sc.Default{Kind: "literal", Type: &typ, Encoding: "text", Value: &text})
	}
	return sc.Known(sc.Default{Kind: "expression", Expression: &sc.Expression{Text: text, Dependencies: sc.Collection[sc.Ref]{Items: []sc.Ref{}, State: "unavailable", Code: "expressionDependencies"}}})
}

func mariaSchemaType(dataType, definition, charset, length, precision, scale, datetimePrecision string) sc.TypeUse {
	// Only the pure shared column-type grammar is reused; MariaDB eligibility and
	// catalog SQL remain native. Integer display widths remain exact.
	typ := mysql.CatalogTypeShape(dataType, definition, charset, length, precision, scale, datetimePrecision, "")
	if (dataType == "inet4" || dataType == "inet6") && definition == dataType {
		typ.Modifiers = sc.Known(sc.TypeModifiers{Length: mariaNumber(length), Precision: mariaNumber(precision), Scale: mariaNumber(scale), DatetimePrecision: mariaNumber(datetimePrecision)})
	}
	// MariaDB converts binary ENUM/SET labels to system UTF-8 before exposing
	// COLUMN_TYPE, so that text cannot prove the original binary label universe.
	if (dataType == "enum" || dataType == "set") && (charset == "" || charset == "binary") {
		typ.LabelEncoding = "base64"
		typ.Labels = sc.Collection[string]{Items: []string{}, State: "unavailable", Code: "nativeBinaryLabels", Complete: false}
	}
	if (dataType == "enum" || dataType == "set") && (charset == "utf8mb4" || charset == "utf16" || charset == "utf16le" || charset == "utf32") {
		for _, label := range typ.Labels.Items {
			if strings.Contains(label, "?") {
				typ.Labels = sc.Collection[string]{Items: []string{}, State: "unavailable", Code: "nativeWideLabels", Complete: false}
				break
			}
		}
	}
	return typ
}
