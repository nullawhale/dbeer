package postgres

import (
	"errors"
	"fmt"
	"reflect"
	"sort"
	"strings"

	"dbeer/helper/internal/tableedit"
	"github.com/jackc/pgx/v5"
)

// Lifecycle SQL only. The existing composer renders columns/native properties;
// its existing transaction runner owns locks, bound proofs, DROP and COMMIT.
type pgAdvancedCopyFamilySteps struct {
	Destinations  map[string]tableedit.Target
	RowSources    map[string]tableedit.Target
	InlineNotNull map[string]map[string]string
	BeforeCreate  []string
	BeforeCopy    []string
	BeforeDrop    []string
	AfterDrop     []string
	AfterIndexes  []string
	AfterRestore  []string
}

func pgAdvancedCopyFamilyPlan(before tableedit.Baseline, layout *pgAdvancedCopyLayout, definitions pgAdvancedCopyDefinitions) (*pgAdvancedCopyFamilySteps, error) {
	if before.Engine != "postgresql" || before.Facts == nil || before.AdvancedEvidence == nil || layout == nil {
		return nil, tableedit.ErrUnsupported
	}
	canonical, err := pgAdvancedCopyGraph(before, layout.Orders[before.Identity], layout.NameSeed)
	if err != nil || !reflect.DeepEqual(canonical, layout) {
		return nil, errors.New("The exact reviewed family replacement layout is incomplete or changed.")
	}
	if _, err = pgAdvancedCopyTargets(before.AdvancedEvidence); err != nil {
		return nil, err
	}
	out := &pgAdvancedCopyFamilySteps{Destinations: map[string]tableedit.Target{}, RowSources: map[string]tableedit.Target{}, InlineNotNull: map[string]map[string]string{}}
	used := map[tableedit.Target]bool{}
	for _, target := range layout.Targets {
		used[target] = true
	}
	for _, id := range layout.CreateOrder {
		original, temporary := layout.Targets[id], layout.Temporary[id]
		if !original.Valid() || original.Create || !temporary.Valid() || temporary.Create || temporary.Schema != original.Schema || used[temporary] {
			return nil, errors.New("Every family backup/destination must have its own exact reviewed same-schema name.")
		}
		used[temporary] = true
		out.Destinations[id], out.RowSources[id] = temporary, original
		out.InlineNotNull[id] = map[string]string{}
		classes := before.AdvancedEvidence.Rows[id+"/class"]
		if len(classes) != 1 {
			return nil, tableedit.ErrUnsupported
		}
		if !layout.CreateInherits[id] && len(layout.Parents[id]) > 0 && classes[0]["relispartition"] != true {
			for _, constraint := range before.AdvancedEvidence.Rows[id+"/constraints"] {
				if constraint["contype"] == "c" && pgPhysicalOID(constraint["conrelid"]) == id && constraint["conislocal"] != true {
					return nil, errors.New("This client cannot yet restore a nonlocal CHECK on a reordered locally declared inheritance child; review the complete declaring-parent migration.")
				}
			}
		}
		for _, attr := range before.AdvancedEvidence.Rows[id+"/attributes"] {
			name, ok := attr["attname"].(string)
			if !ok || !tableedit.Identifier(name) || attr["attisdropped"] != false {
				return nil, tableedit.ErrUnsupported
			}
			if attr["attnotnull"] != true {
				continue
			}
			clause, nn, err := pgAdvancedCopyFamilyNotNull(before, id, attr)
			if err != nil {
				return nil, err
			}
			if layout.CreateInherits[id] && attr["attislocal"] == false {
				inherited := false
				for _, parent := range layout.Parents[id] {
					for _, p := range before.AdvancedEvidence.Rows[parent+"/attributes"] {
						inherited = inherited || p["attname"] == name && p["attnotnull"] == true
					}
				}
				if !inherited {
					return nil, errors.New("This client cannot yet restore a locally added NOT NULL condition on a nonlocal inherited column during reordered recreation.")
				}
				if before.Facts.ServerVersion >= 180000 {
					// CREATE INHERITS retains the first parent's native name;
					// collision-generated or independently renamed children stay guarded.
					inheritedName := ""
					for _, parent := range layout.Parents[id] {
						for _, p := range before.AdvancedEvidence.Rows[parent+"/attributes"] {
							if p["attname"] != name || p["attnotnull"] != true {
								continue
							}
							_, parentNN, err := pgAdvancedCopyFamilyNotNull(before, parent, p)
							if err != nil {
								return nil, err
							}
							if parentNN["connoinherit"] == false && inheritedName == "" {
								inheritedName, _ = parentNN["conname"].(string)
							}
						}
					}
					if nn == nil || nn["conislocal"] != false || nn["connoinherit"] != false || inheritedName == "" || nn["conname"] != inheritedName {
						return nil, errors.New("This client cannot yet recreate this inherited NOT NULL name/locality exactly; review its explicit native constraint migration.")
					}
				}
				continue
			}
			if nn != nil && nn["conislocal"] != true && classes[0]["relispartition"] != true {
				return nil, errors.New("This client cannot yet recreate a nonlocal NOT NULL constraint on a locally declared inherited column without changing its native locality.")
			}
			out.InlineNotNull[id][name] = clause
		}
	}
	for _, id := range layout.CreateOrder {
		if out.Destinations[id] != layout.Targets[id] {
			out.AfterDrop = append(out.AfterDrop, "ALTER TABLE "+pgPhysicalName(out.Destinations[id])+" RENAME TO "+pgx.Identifier{layout.Targets[id].Table}.Sanitize()+";")
		}
	}
	ids := make([]string, 0, len(layout.Targets))
	for id := range layout.Targets {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		cl := before.AdvancedEvidence.Rows[id+"/class"][0]
		if cl["relispartition"] == true {
			if len(layout.Parents[id]) != 1 {
				return nil, tableedit.ErrUnsupported
			}
			parent := layout.Parents[id][0]
			if !layout.Replaced[id] && !layout.Replaced[parent] {
				continue
			}
			bound := definitions.PartitionBound[id]
			if bound == "" || len(bound) > tableedit.MaxSQLBytes || bound != "DEFAULT" && !strings.HasPrefix(bound, "FOR VALUES ") {
				return nil, errors.New("The exact reviewed native partition bound is unavailable.")
			}
			out.BeforeDrop = append(out.BeforeDrop, "ALTER TABLE "+pgPhysicalName(layout.Targets[parent])+" DETACH PARTITION "+pgPhysicalName(layout.Targets[id])+";")
			out.AfterIndexes = append(out.AfterIndexes, "ALTER TABLE "+pgPhysicalName(layout.Targets[parent])+" ATTACH PARTITION "+pgPhysicalName(layout.Targets[id])+" "+bound+";")
		}
	}
	// Restore traditional parent order only after both sides' CHECK/key/index
	// definitions exist. CREATE INHERITS already establishes nonlocal columns.
	for _, id := range layout.CreateOrder {
		if layout.CreateInherits[id] || before.AdvancedEvidence.Rows[id+"/class"][0]["relispartition"] == true {
			continue
		}
		for _, parent := range layout.Parents[id] {
			out.AfterIndexes = append(out.AfterIndexes, "ALTER TABLE "+pgPhysicalName(layout.Targets[id])+" INHERIT "+pgPhysicalName(layout.Targets[parent])+";")
		}
	}
	return out, nil
}

func pgAdvancedCopyFamilyNotNull(before tableedit.Baseline, id string, attr map[string]any) (string, map[string]any, error) {
	if before.Facts == nil {
		return "", nil, tableedit.ErrUnsupported
	}
	if before.Facts.ServerVersion < 180000 {
		return "NOT NULL", nil, nil
	}
	var found map[string]any
	for _, c := range before.AdvancedEvidence.Rows[id+"/constraints"] {
		if c["contype"] != "n" || pgPhysicalOID(c["conrelid"]) != id || !reflect.DeepEqual(c["conkey"], []any{attr["attnum"]}) {
			continue
		}
		if found != nil || c["convalidated"] != true || !tableedit.Identifier(fmt.Sprint(c["conname"])) {
			return "", nil, errors.New("The complete original native NOT NULL constraint is unavailable.")
		}
		found = c
	}
	if found == nil {
		return "", nil, errors.New("The original PostgreSQL NOT NULL constraint name is missing.")
	}
	clause := "CONSTRAINT " + pgx.Identifier{fmt.Sprint(found["conname"])}.Sanitize() + " NOT NULL"
	if found["connoinherit"] == true {
		clause += " NO INHERIT"
	} else if found["connoinherit"] != false {
		return "", nil, tableedit.ErrUnsupported
	}
	return clause, found, nil
}
