// Licensed to the Apache Software Foundation (ASF) under one or more
// contributor license agreements. See LICENSE and NOTICE for details.
// DBeer local change: optional per-session wire custom-type resolution.

package gocql

import (
	"errors"
	"strings"
	"unicode"
	"unicode/utf8"
)

// CustomWireTypeResolver preserves the original wire custom-class identity.
// resolved is the registered decoder, or nil when resolveErr reports an
// unknown class. Other resolver errors and malformed syntax are not passed to
// this hook. A nil hook retains the upstream driver's behavior.
type CustomWireTypeResolver func(proto int, name string, resolved TypeInfo, resolveErr error) (TypeInfo, error)

func (r *RegisteredTypes) resolveWireCustomType(proto int, name string) (TypeInfo, error) {
	if r.customWireTypeResolver == nil {
		return r.typeInfoFromString(proto, name)
	}
	if !validWireCustomType(name) {
		return nil, errors.New("invalid custom type metadata")
	}
	resolved, err := r.typeInfoFromString(proto, name)
	if err != nil {
		var unknown unknownTypeError
		if !errors.As(err, &unknown) {
			return nil, err
		}
	}
	if err == nil && !validResolvedCustomType(resolved, 0) {
		return nil, errors.New("invalid custom type parameters")
	}
	info, err := r.customWireTypeResolver(proto, name, resolved, err)
	if err == nil && info == nil {
		return nil, errors.New("custom type resolver returned no type")
	}
	return info, err
}

func validResolvedCustomType(info TypeInfo, depth int) bool {
	if info == nil || depth >= 64 {
		return false
	}
	switch t := info.(type) {
	case VectorType:
		return t.Dimensions > 0 && t.Dimensions <= 65535 && validResolvedCustomType(t.SubType, depth+1)
	case CollectionType:
		return (t.Key == nil || validResolvedCustomType(t.Key, depth+1)) && validResolvedCustomType(t.Elem, depth+1)
	case TupleTypeInfo:
		for _, element := range t.Elems {
			if !validResolvedCustomType(element, depth+1) {
				return false
			}
		}
	case UDTTypeInfo:
		for _, field := range t.Elements {
			if !validResolvedCustomType(field.Type, depth+1) {
				return false
			}
		}
	}
	return true
}

// Custom classes may have Java-style (...) or CQL-style <...> parameters.
// Reject broken framing without trying to interpret external class semantics.
func validWireCustomType(name string) bool {
	name = strings.TrimSpace(name)
	if name == "" || !utf8.ValidString(name) || strings.ContainsRune(name, 0) {
		return false
	}
	base := name
	if opening := strings.IndexAny(name, "(<"); opening >= 0 {
		base = strings.TrimSpace(name[:opening])
	}
	for _, segment := range strings.Split(base, ".") {
		if segment == "" {
			return false
		}
		for i, c := range segment {
			if !(unicode.IsLetter(c) || c == '_' || c == '$' || i > 0 && unicode.IsDigit(c)) {
				return false
			}
		}
	}
	var stack []byte
	for i := 0; i < len(name); i++ {
		switch c := name[i]; c {
		case '(', '<':
			stack = append(stack, c)
		case ')', '>':
			// DynamicCompositeType uses aliases such as a=>UUIDType.
			if c == '>' && i > 0 && name[i-1] == '=' {
				continue
			}
			if len(stack) == 0 || c == ')' && stack[len(stack)-1] != '(' || c == '>' && stack[len(stack)-1] != '<' {
				return false
			}
			stack = stack[:len(stack)-1]
			if len(stack) == 0 && i != len(name)-1 {
				return false
			}
		}
	}
	return len(stack) == 0
}
