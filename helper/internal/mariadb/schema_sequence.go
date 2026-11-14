package mariadb

import (
	sc "dbeer/helper/internal/schemacompare"
	"strconv"
	"strings"
)

func (r *mariaSchemaCapture) sequence(ref sc.Ref) error {
	rows, e := r.track("SHOW CREATE SEQUENCE "+QuoteIdentifier(ref.Schema)+"."+QuoteIdentifier(ref.Name), true)
	if e != nil {
		return e
	}
	if len(rows) != 1 || len(rows[0]) < 2 || rows[0][1] == nil {
		return sc.ErrInvalid
	}
	sequence, known := mariaSequenceDefinition(ref, *rows[0][1], r.sqlMode)
	if !known {
		if e = r.issue(&sequence.Ref, "sequence", "nativeSequenceProperties", "Native sequence properties are not completely represented by the portable sequence facts."); e != nil {
			return e
		}
	}
	return r.sink.Sequence(sequence)
}

func mariaSequenceDefinition(ref sc.Ref, raw, mode string) (sc.Sequence, bool) {
	ref.Kind = "sequence"
	unknown := sc.Unknown[string]("nativeSequenceDefinition")
	seq := sc.Sequence{Ref: ref, Type: sc.Known(sc.TypeUse{Ref: sc.Ref{Kind: "type", Name: "bigint"}, Kind: "builtin", Modifiers: sc.Known(sc.TypeModifiers{}), Labels: sc.Complete[string](nil)}), Start: unknown, Increment: unknown, Min: unknown, Max: unknown, Cache: unknown, Cycle: sc.Unknown[bool]("nativeSequenceDefinition"), Owner: sc.Absent[sc.Ref]()}
	tokens, ok := mariaIndexMetadataTokens(raw, mode, 0)
	if !ok || len(tokens) < 3 {
		return seq, false
	}
	word := func(i int, value string) bool {
		return i < len(tokens) && tokens[i].kind == "word" && strings.EqualFold(tokens[i].value, value)
	}
	if !word(0, "CREATE") || !word(1, "SEQUENCE") || (tokens[2].kind != "identifier" && tokens[2].kind != "word") || tokens[2].value != ref.Name {
		return seq, false
	}
	seen := map[string]bool{}
	known := true
	for i := 3; i < len(tokens); {
		key := ""
		switch {
		case word(i, "START") && word(i+1, "WITH"):
			key = "start"
			i += 2
		case word(i, "MINVALUE"):
			key = "min"
			i++
		case word(i, "MAXVALUE"):
			key = "max"
			i++
		case word(i, "INCREMENT") && word(i+1, "BY"):
			key = "increment"
			i += 2
		case word(i, "CACHE"):
			key = "cache"
			i++
		case word(i, "NOCACHE"):
			if seen["cache"] {
				return seq, false
			}
			seq.Cache = sc.Known("0")
			seen["cache"] = true
			i++
			continue
		case word(i, "CYCLE"), word(i, "NOCYCLE"):
			if seen["cycle"] {
				return seq, false
			}
			seq.Cycle = sc.Known(word(i, "CYCLE"))
			seen["cycle"] = true
			i++
			continue
		case word(i, "ENGINE"):
			if i+2 >= len(tokens) || tokens[i+1].value != "=" {
				return seq, false
			}
			known = known && strings.EqualFold(tokens[i+2].value, "InnoDB")
			i += 3
			continue
		default:
			return seq, false
		}
		if seen[key] || i >= len(tokens) {
			return seq, false
		}
		seen[key] = true
		value := tokens[i].value
		i++
		if value == "-" || value == "+" {
			if i >= len(tokens) {
				return seq, false
			}
			value += tokens[i].value
			i++
		}
		if _, e := strconv.ParseInt(value, 10, 64); e != nil {
			return seq, false
		}
		switch key {
		case "start":
			seq.Start = sc.Known(value)
		case "min":
			seq.Min = sc.Known(value)
		case "max":
			seq.Max = sc.Known(value)
		case "increment":
			seq.Increment = sc.Known(value)
		case "cache":
			seq.Cache = sc.Known(value)
		}
	}
	return seq, known && len(seen) == 6
}
