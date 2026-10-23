package postgres

import sc "dbeer/helper/internal/schemacompare"

// Structural metadata can identify every defined type without proving that an
// arbitrary user output function preserves every stored bit. Builtin container
// output is exact only when all recursively contained values have known output.
func postgresLosslessUse(u sc.TypeUse, definitions []sc.TypeDefinition, visited map[sc.Ref]bool) bool {
	return postgresOutputUse(u, definitions, visited, false)
}

// Ordinary Execute retains caller-controlled rendering and search_path. Those
// settings can also change inside caller SQL, so a preflight setting fingerprint
// cannot prove exact values for contextual/precision-sensitive output routines.
func postgresQueryLosslessUse(u sc.TypeUse, definitions []sc.TypeDefinition, visited map[sc.Ref]bool) bool {
	return postgresOutputUse(u, definitions, visited, true)
}
func postgresOutputUse(u sc.TypeUse, definitions []sc.TypeDefinition, visited map[sc.Ref]bool, userRendering bool) bool {
	if u.Kind == "array" {
		return u.Element != nil && postgresOutputUse(*u.Element, definitions, visited, userRendering)
	}
	if u.Kind == "builtin" {
		return u.Ref.Schema == "pg_catalog" && (!userRendering || !postgresOutputSensitiveBuiltin(u.Ref.Name))
	}
	if visited[u.Ref] {
		return true
	}
	visited[u.Ref] = true
	for _, d := range definitions {
		if d.Ref != u.Ref {
			continue
		}
		if d.Kind.State != "known" || d.Kind.Value == nil {
			return false
		}
		switch *d.Kind.Value {
		case "e":
			return d.Labels.Complete
		case "d", "m":
			return d.Base.Value != nil && postgresOutputUse(*d.Base.Value, definitions, visited, userRendering)
		case "r":
			return d.Range != nil && postgresOutputUse(d.Range.Subtype, definitions, visited, userRendering)
		case "c":
			if !d.Attributes.Complete {
				return false
			}
			for _, c := range d.Attributes.Items {
				if c.Type.Value == nil || !postgresOutputUse(*c.Type.Value, definitions, visited, userRendering) {
					return false
				}
			}
			return true
		default:
			return false
		}
	}
	return false
}

func postgresOutputSensitiveBuiltin(name string) bool {
	switch name {
	case "date", "time", "timetz", "timestamp", "timestamptz", "interval", "money",
		"float4", "float8", "point", "line", "lseg", "box", "path", "polygon", "circle",
		"regclass", "regtype", "regproc", "regprocedure", "regoper", "regoperator",
		"regnamespace", "regrole", "regcollation", "regconfig", "regdictionary":
		return true
	}
	return false
}
