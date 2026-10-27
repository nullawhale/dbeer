package safety

// Metadata statements have no value expressions. Function-resource arguments
// are type signatures; describing or listing a function never invokes it.
func cqlDescribe(ts []token) bool {
	if len(ts) >= 2 && words(ts[len(ts)-2:], "WITH", "INTERNALS") {
		ts = ts[:len(ts)-2]
	}
	if len(ts) == 0 {
		return false
	}
	if len(ts) == 1 && ts[0].kind == word && oneOf(ts[0].text, "CLUSTER", "SCHEMA", "KEYSPACES", "KEYSPACE", "TABLES", "COLUMNFAMILIES", "TYPES", "FUNCTIONS", "AGGREGATES") {
		return true
	}
	if words(ts, "FULL", "SCHEMA") {
		return true
	}
	if ts[0].text == "ONLY" {
		ts = ts[1:]
		return len(ts) >= 1 && ts[0].text == "KEYSPACE" && (len(ts) == 1 || len(ts) == 2 && isName(ts[1]))
	}
	if ts[0].kind == word && ts[0].text == "KEYSPACE" {
		return len(ts) == 2 && isName(ts[1])
	}
	if len(ts) >= 2 && words(ts[:2], "MATERIALIZED", "VIEW") {
		return cqlQualifiedName(ts[2:])
	}
	if ts[0].kind == word && oneOf(ts[0].text, "TABLE", "COLUMNFAMILY", "INDEX", "TYPE", "FUNCTION", "AGGREGATE") {
		return cqlQualifiedName(ts[1:])
	}
	return cqlQualifiedName(ts)
}

func cqlList(ts []token) bool {
	if len(ts) == 0 {
		return false
	}
	if words(ts, "USERS") {
		return true
	}
	if ts[len(ts)-1].kind == word && ts[len(ts)-1].text == "NORECURSIVE" {
		ts = ts[:len(ts)-1]
	}
	if len(ts) >= 2 && ts[len(ts)-2].kind == word && ts[len(ts)-2].text == "OF" && cqlRoleName(ts[len(ts)-1]) {
		ts = ts[:len(ts)-2]
	}
	if words(ts, "ROLES") {
		return true
	}
	for i, t := range ts {
		if t.kind == word && t.text == "ON" {
			return cqlPermissions(ts[:i]) && cqlResource(ts[i+1:])
		}
	}
	return cqlPermissions(ts)
}

func cqlPermissions(ts []token) bool {
	if words(ts, "ALL") || words(ts, "ALL", "PERMISSIONS") {
		return true
	}
	for i := 0; i < len(ts); {
		if ts[i].kind != word || !oneOf(ts[i].text, "CREATE", "ALTER", "DROP", "SELECT", "MODIFY", "AUTHORIZE", "DESCRIBE", "EXECUTE", "UNMASK", "SELECT_MASKED") {
			return false
		}
		i++
		if i < len(ts) && ts[i].kind == word && ts[i].text == "PERMISSION" {
			i++
		}
		if i == len(ts) {
			return true
		}
		if ts[i].text != "," || i+1 == len(ts) {
			return false
		}
		i++
	}
	return false
}

func cqlResource(ts []token) bool {
	if len(ts) == 0 {
		return false
	}
	if words(ts, "ALL", "KEYSPACES") || words(ts, "ALL", "ROLES") || words(ts, "ALL", "FUNCTIONS") || words(ts, "ALL", "MBEANS") {
		return true
	}
	if len(ts) == 5 && words(ts[:4], "ALL", "FUNCTIONS", "IN", "KEYSPACE") && isName(ts[4]) {
		return true
	}
	if ts[0].kind != word {
		return cqlQualifiedName(ts)
	}
	switch ts[0].text {
	case "KEYSPACE":
		return len(ts) == 2 && isName(ts[1])
	case "TABLE":
		return cqlQualifiedName(ts[1:])
	case "ROLE":
		return len(ts) == 2 && cqlRoleName(ts[1])
	case "MBEAN", "MBEANS":
		return len(ts) == 2 && ts[1].kind == literal && ts[1].text == ""
	case "FUNCTION":
		last := ts[len(ts)-1]
		return len(ts) >= 3 && cqlQualifiedName(ts[1:len(ts)-1]) && last.kind == group && last.text == "(" && cqlTypeSignature(last.children)
	}
	return cqlQualifiedName(ts)
}

func cqlQualifiedName(ts []token) bool {
	return len(ts) == 1 && isName(ts[0]) || len(ts) == 3 && isName(ts[0]) && ts[1].text == "." && isName(ts[2])
}

func cqlRoleName(t token) bool {
	return isName(t) || t.kind == literal && t.text == ""
}

func cqlTypeSignature(ts []token) bool {
	// CQL type arguments use angle brackets, including nested collections and
	// vector dimensions. Parenthesized expressions/functions are never types.
	for _, t := range ts {
		if isName(t) || t.kind == literal || t.kind == symbol && oneOf(t.text, ",", ".", "<", ">") {
			continue
		}
		return false
	}
	return true
}
