package postgres

import (
	"errors"
	"fmt"
	"reflect"
	"strconv"
	"strings"

	"dbeer/helper/internal/tableedit"
)

// The typed native index definition binds the new tuple's names/types. Admit
// only complete native ordinals and default independently mutable properties;
// existing/attached index attributes always remain in the exact raw comparison.
func pgAdvancedCreatedIndexAttributes(rows []map[string]any, record map[string]any, source []map[string]any) error {
	cl, cok := record["class"].(map[string]any)
	ix, iok := record["index"].(map[string]any)
	if !cok || !iok || len(source) == 0 {
		return errors.New("native index record")
	}
	natts, err := strconv.Atoi(fmt.Sprint(ix["indnatts"]))
	keys := pgAdvancedAttnums(ix["indkey"])
	if err != nil || natts < 1 || natts > tableedit.MaxColumns || len(keys) != natts {
		return errors.New("native index term count")
	}
	fields := strings.Fields("attrelid attname atttypid attstattarget attlen attnum attndims attcacheoff atttypmod attbyval attalign attstorage attcompression attnotnull atthasdef atthasmissing attidentity attgenerated attisdropped attislocal attinhcount attcollation attacl attoptions attfdwoptions attmissingval")
	allowed := map[string]bool{}
	for _, key := range fields {
		allowed[key] = true
	}
	seen := map[int]bool{}
	for _, row := range rows {
		if pgPhysicalOID(row["attrelid"]) != pgPhysicalOID(cl["oid"]) {
			continue
		}
		for key := range row {
			if !allowed[key] {
				return errors.New("unknown native attribute field: " + key)
			}
		}
		for _, key := range fields {
			_, expected := source[0][key]
			_, exists := row[key]
			if expected != exists {
				return errors.New("native attribute field presence differs from its captured server catalog: " + key)
			}
		}
		n, err := strconv.Atoi(fmt.Sprint(row["attnum"]))
		if err != nil || n < 1 || n > natts || seen[n] || !tableedit.Identifier(fmt.Sprint(row["attname"])) || pgPhysicalOID(row["atttypid"]) == "" {
			return errors.New("native attribute ordinal/name/type")
		}
		seen[n] = true
		for key, expected := range map[string]any{"atthasdef": false, "atthasmissing": false, "attidentity": "", "attgenerated": "", "attisdropped": false, "attislocal": true, "attinhcount": float64(0), "attnotnull": false, "attndims": float64(0), "attcacheoff": float64(-1), "attacl": nil, "attfdwoptions": nil, "attmissingval": nil} {
			if _, present := source[0][key]; !present {
				continue
			}
			if !reflect.DeepEqual(row[key], expected) {
				return errors.New("nondefault native attribute field: " + key)
			}
		}
		if row["attstattarget"] != nil && fmt.Sprint(row["attstattarget"]) != "-1" || tableedit.SemanticPostgresAttributeOptions(row["attoptions"]) != nil {
			return errors.New("native attribute statistics/options")
		}
		if keys[n-1] != "0" {
			found := false
			for _, attr := range source {
				if fmt.Sprint(attr["attnum"]) != keys[n-1] {
					continue
				}
				found = true
				for _, key := range []string{"attname", "atttypid", "atttypmod", "attlen", "attbyval", "attalign"} {
					if !reflect.DeepEqual(row[key], attr[key]) {
						return errors.New("native attribute source field: " + key)
					}
				}
			}
			if !found {
				return errors.New("native attribute source binding")
			}
		}
	}
	if len(seen) != natts {
		return errors.New("native index attributes are incomplete")
	}
	return nil
}
