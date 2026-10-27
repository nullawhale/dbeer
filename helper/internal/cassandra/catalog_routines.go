package cassandra

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"dbeer/helper/internal/protocol"
)

type routineParameter struct {
	Name     string `json:"name"`
	Type     string `json:"type"`
	Position int    `json:"position"`
}

type routineSignature struct {
	Parameters []routineParameter `json:"parameters"`
	ReturnType string             `json:"returnType"`
}

var errRoutineMetadata = errors.New("Cassandra routine metadata exceeds the supported bounds or is invalid")

// Collect declarations by name: the language protocol already represents
// scalar and aggregate calls as functions with an ordered list of overloads.
// Match its existing 32-overload and 256-parameter bounds.
type routineCollector struct {
	keyspace string
	objects  []catalogObject
	byName   map[string]int
	bytes    int
	rows     int
}

func (c *routineCollector) add(name string, argumentTypes, argumentNames []string, returnType string, aggregate bool) error {
	valid := func(value string, maximum int) bool {
		return value != "" && len(value) <= maximum && utf8.ValidString(value) && !strings.ContainsRune(value, 0)
	}
	if !valid(name, 1024) || !valid(returnType, 4096) || len(argumentTypes) > 256 ||
		(!aggregate && len(argumentNames) != len(argumentTypes)) {
		return errRoutineMetadata
	}
	signature := routineSignature{Parameters: []routineParameter{}, ReturnType: returnType}
	for i, typ := range argumentTypes {
		parameter := "arg" + strconv.Itoa(i+1)
		if !aggregate {
			parameter = argumentNames[i]
		}
		if !valid(typ, 1024) || !valid(parameter, 1024) {
			return errRoutineMetadata
		}
		signature.Parameters = append(signature.Parameters, routineParameter{Name: parameter, Type: typ, Position: i + 1})
	}
	encoded, _ := json.Marshal(signature)
	c.bytes += len(name) + len(encoded) + 128
	c.rows++
	if c.bytes > maxBytes || c.rows > 16384 {
		return errRoutineMetadata
	}
	if c.byName == nil {
		c.byName = map[string]int{}
	}
	index, exists := c.byName[name]
	if !exists {
		index = len(c.objects)
		c.byName[name] = index
		c.objects = append(c.objects, catalogObject{keyspace: c.keyspace, name: name, kind: "function"})
	}
	if len(c.objects[index].signatures) < 32 {
		c.objects[index].signatures = append(c.objects[index].signatures, signature)
	}
	return nil
}

func (s *Session) completionRoutines(ctx context.Context, command protocol.Command, keyspace string) ([]catalogObject, *protocol.Response) {
	collector := routineCollector{keyspace: keyspace}
	for _, aggregate := range []bool{false, true} {
		statement := "SELECT function_name, argument_types, argument_names, return_type FROM system_schema.functions WHERE keyspace_name = ?"
		if aggregate {
			statement = "SELECT aggregate_name, argument_types, return_type FROM system_schema.aggregates WHERE keyspace_name = ?"
		}
		var page []byte
		for {
			// Keep query context, transport, explicit pagination and no-retry
			// policy identical to other metadata reads. No UDF is executed.
			query := ConfigureQuery(s.driver.Query(statement, keyspace), s.keyspace).NoSkipMetadata().PageSize(pageRows).PageState(page)
			iter := query.IterContext(ctx)
			var name, returnType string
			var argumentTypes, argumentNames []string
			var scanErr error
			for {
				var scanned bool
				if aggregate {
					scanned = iter.Scan(&name, &argumentTypes, &returnType)
				} else {
					scanned = iter.Scan(&name, &argumentTypes, &argumentNames, &returnType)
				}
				if !scanned {
					break
				}
				if scanErr = collector.add(name, argumentTypes, argumentNames, returnType, aggregate); scanErr != nil {
					break
				}
			}
			page = append([]byte(nil), iter.PageState()...)
			err := iter.Close()
			if scanErr != nil {
				failure := s.failure(command, "result", "Cassandra routine metadata exceeds the supported size or could not be decoded.")
				return nil, &failure
			}
			if err != nil {
				failure := safeError(command, ctx, err, false, false)
				failure.Message = "Cassandra routine metadata is unavailable or access was denied."
				return nil, &failure
			}
			if len(page) == 0 {
				break
			}
		}
	}
	for i := range collector.objects {
		sort.SliceStable(collector.objects[i].signatures, func(a, b int) bool {
			left, _ := json.Marshal(collector.objects[i].signatures[a])
			right, _ := json.Marshal(collector.objects[i].signatures[b])
			return string(left) < string(right)
		})
	}
	return collector.objects, nil
}
