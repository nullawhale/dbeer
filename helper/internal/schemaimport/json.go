package schemaimport

import (
	"bytes"
	"context"
	"dbeer/helper/internal/protocol"
	"encoding/json"
	"io"
	"reflect"
	"strconv"
	"strings"
)

// strictJSON keeps duplicate keys and lexical integer spelling visible before
// decoding into typed metadata. Neither json.Unmarshal nor a checksum proves
// that an artifact was created by DBeer.
func strictJSON(ctx context.Context, data []byte, out any) error {
	if !protocol.JSONUnicodeValid(data) || bytes.IndexByte(data, 0) >= 0 {
		return ErrInvalid
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	nodes := 0
	var value func(int) error
	value = func(depth int) error {
		if depth > 128 || nodes > 1_000_000 {
			return ErrLimit
		}
		nodes++
		if nodes%1024 == 0 {
			if err := ctx.Err(); err != nil {
				return err
			}
		}
		t, err := d.Token()
		if err != nil {
			return ErrInvalid
		}
		switch t := t.(type) {
		case json.Delim:
			if t == '{' {
				seen := map[string]bool{}
				for d.More() {
					k, e := d.Token()
					s, ok := k.(string)
					if e != nil || !ok || seen[s] || strings.ContainsRune(s, 0) {
						return ErrInvalid
					}
					seen[s] = true
					if e = value(depth + 1); e != nil {
						return e
					}
				}
				if end, e := d.Token(); e != nil || end != json.Delim('}') {
					return ErrInvalid
				}
			} else if t == '[' {
				for d.More() {
					if e := value(depth + 1); e != nil {
						return e
					}
				}
				if end, e := d.Token(); e != nil || end != json.Delim(']') {
					return ErrInvalid
				}
			} else {
				return ErrInvalid
			}
		case json.Number:
			if _, err := strconv.ParseInt(string(t), 10, 64); err != nil || strings.ContainsAny(string(t), ".eE+") {
				return ErrInvalid
			}
		case string:
			if len(t) > 1<<20 || strings.ContainsRune(t, 0) {
				return ErrLimit
			}
		}
		return nil
	}
	if err := value(0); err != nil {
		return err
	}
	if _, err := d.Token(); err != io.EOF {
		return ErrInvalid
	}
	if err := closedShape(ctx, data, reflect.TypeOf(out).Elem(), 0); err != nil {
		return err
	}
	d = json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if d.Decode(out) != nil {
		return ErrInvalid
	}
	return ctx.Err()
}

func closedShape(ctx context.Context, raw json.RawMessage, typ reflect.Type, depth int) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if depth > 128 {
		return ErrLimit
	}
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return nil
	}
	if typ.Kind() == reflect.Pointer {
		return closedShape(ctx, raw, typ.Elem(), depth+1)
	}
	switch typ.Kind() {
	case reflect.Struct:
		var fields map[string]json.RawMessage
		if json.Unmarshal(raw, &fields) != nil || fields == nil {
			return ErrInvalid
		}
		known := map[string]reflect.StructField{}
		for i := 0; i < typ.NumField(); i++ {
			f := typ.Field(i)
			if f.PkgPath != "" {
				continue
			}
			tag := strings.Split(f.Tag.Get("json"), ",")
			name := tag[0]
			if name == "-" {
				continue
			}
			if name == "" {
				name = f.Name
			}
			known[name] = f
			_, optional := f.Tag.Lookup("json")
			optional = optional && strings.Contains(f.Tag.Get("json"), ",omitempty")
			if !optional {
				if _, ok := fields[name]; !ok {
					return ErrInvalid
				}
			}
		}
		for name, value := range fields {
			f, ok := known[name]
			if !ok {
				return ErrInvalid
			}
			if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
				// Fact's known-null value is semantically significant. Other
				// optional nulls are not equivalent to an absent payload.
				knownNull := strings.HasPrefix(typ.Name(), "Fact[") && name == "value"
				optional := strings.Contains(f.Tag.Get("json"), ",omitempty")
				if !knownNull && !(f.Type.Kind() == reflect.Pointer && !optional) {
					return ErrInvalid
				}
				continue
			}
			if e := closedShape(ctx, value, f.Type, depth+1); e != nil {
				return e
			}
		}
	case reflect.Slice:
		var items []json.RawMessage
		if json.Unmarshal(raw, &items) != nil || items == nil {
			return ErrInvalid
		}
		if len(items) > 100000 {
			return ErrLimit
		}
		for _, item := range items {
			if e := closedShape(ctx, item, typ.Elem(), depth+1); e != nil {
				return e
			}
		}
	}
	return nil
}
