package sqlcomplete

import "strings"

// Keep CQL suggestions separate from SQL: JOIN, OFFSET, RETURNING and SQL
// transaction commands are not valid Cassandra constructs. No completion
// silently adds ALLOW FILTERING to a generated query.
var cqlKeywords = strings.Fields("SELECT FROM WHERE AND IN CONTAINS KEY AS DISTINCT JSON ORDER BY ASC DESC LIMIT PER PARTITION GROUP INSERT INTO VALUES UPDATE SET DELETE USING TTL TIMESTAMP IF EXISTS NOT NULL TRUE FALSE CREATE ALTER DROP TRUNCATE TABLE COLUMNFAMILY KEYSPACE KEYSPACES TYPE INDEX CUSTOM MATERIALIZED VIEW PRIMARY CLUSTERING STATIC WITH COMPACT STORAGE BEGIN UNLOGGED COUNTER BATCH APPLY USE GRANT REVOKE LIST ROLE ROLES USER USERS PERMISSION PERMISSIONS ALL ON TO OF NORECURSIVE AUTHORIZE MODIFY EXECUTE SELECT_MASKED UNMASK PASSWORD LOGIN NOLOGIN SUPERUSER NOSUPERUSER OPTIONS ADD RENAME FUNCTION AGGREGATE OR REPLACE RETURNS CALLED INPUT LANGUAGE SFUNC STYPE FINALFUNC INITCOND MASKED DEFAULT UNSET TRIGGER DESCRIBE SCHEMA ANN ALLOW FILTERING")

var cqlTypes = strings.Fields("ASCII BIGINT BLOB BOOLEAN COUNTER DATE DECIMAL DOUBLE DURATION FLOAT INET INT SMALLINT TEXT TIME TIMESTAMP TIMEUUID TINYINT UUID VARCHAR VARINT VECTOR LIST SET MAP TUPLE FROZEN")

func (r *request) cql() {
	last := token{}
	if len(r.before) > 0 {
		last = r.before[len(r.before)-1]
	}
	if word(last, "USE") {
		for _, entry := range r.context.Catalog {
			if entry.Schema != "" {
				r.add(entry.Schema, quoteIdentifier(entry.Schema, "cassandra"), "Keyspace", 9, 0)
			}
		}
		return
	}
	if r.cqlObjectNames() || r.cqlTypeNames() {
		return
	}
	insertColumns := r.cqlInsertColumnList()
	insertValues := false
	if len(r.before) > 0 && word(r.before[0], "INSERT") {
		for _, t := range r.before {
			if word(t, "VALUES") {
				insertValues = true
				r.clause, r.table = generalClause, false
				break
			}
		}
	}
	for _, rule := range []struct {
		trigger string
		words   []string
	}{
		{"ORDER", []string{"BY"}}, {"GROUP", []string{"BY"}}, {"PER", []string{"PARTITION"}},
		{"INSERT", []string{"INTO"}},
		{"BEGIN", []string{"BATCH", "UNLOGGED BATCH", "COUNTER BATCH"}}, {"APPLY", []string{"BATCH"}},
		{"USING", []string{"TTL", "TIMESTAMP"}}, {"CONTAINS", []string{"KEY"}},
		{"ANN", []string{"OF"}},
	} {
		if word(last, rule.trigger) {
			for _, name := range rule.words {
				r.add(name, name, "CQL keyword", 14, 3)
			}
			return
		}
	}
	// Table names after FROM/INTO/UPDATE and keyspace-qualified prefixes.
	if r.table && !insertColumns {
		var qualifier *token
		if r.qualified {
			qualifier = &r.before[len(r.before)-2]
		}
		for _, entry := range r.context.Catalog {
			if entry.Kind != "table" && entry.Kind != "view" {
				continue
			}
			if qualifier != nil && !identifierEqual(*qualifier, entry.Schema, "cassandra") {
				continue
			}
			insertion := qualifiedName(entry, "cassandra")
			if qualifier != nil {
				insertion = quoteIdentifier(entry.Name, "cassandra")
			}
			r.add(entry.Name, insertion, entry.Kind+" · "+entry.Schema, 7, 1)
			if qualifier == nil && entry.Schema != "" {
				r.add(entry.Schema, quoteIdentifier(entry.Schema, "cassandra"), "Keyspace", 9, 2)
			}
		}
		return
	}
	if r.clause == fromClause && !insertColumns {
		for _, name := range []string{"WHERE", "GROUP BY", "ORDER BY", "PER PARTITION LIMIT", "LIMIT"} {
			r.add(name, name, "CQL keyword", 14, 3)
		}
		return
	}
	if r.clause == limitClause {
		return
	}
	if r.qualified {
		qualifier := r.before[len(r.before)-2]
		if identifierEqual(qualifier, "system", "cassandra") {
			for _, name := range functions("cassandra") {
				if !cqlSpecialSelector(name) && r.cqlFunctionAllowed(name) {
					r.add(name, name, "Native function · Cassandra", 3, 2)
				}
			}
			return
		}
		r.members()
		return
	}
	for _, src := range r.scope.visible("cassandra") {
		for _, column := range src.columns {
			detail := sourceDetail(src)
			for _, entry := range src.entries {
				for _, key := range entry.PartitionKeys {
					if key == column {
						detail = "Partition key · " + entry.Schema + "." + entry.Name
					}
				}
				for _, key := range entry.ClusteringColumns {
					if key == column {
						detail = "Clustering column · " + entry.Schema + "." + entry.Name
					}
				}
				for _, key := range entry.StaticColumns {
					if key == column {
						detail = "Static column · " + entry.Schema + "." + entry.Name
					}
				}
			}
			r.add(column, quoteIdentifier(column, "cassandra"), detail, 5, 0)
		}
	}
	if insertColumns {
		return
	}
	if len(r.before) > 0 && word(r.before[0], "DELETE") && r.clause == generalClause {
		r.add("FROM", "FROM", "CQL keyword", 14, 3)
		return
	}
	words := cqlKeywords
	switch r.clause {
	case selectClause:
		words = strings.Fields("AS DISTINCT JSON FROM WHERE GROUP ORDER LIMIT PER PARTITION")
	case predicateClause:
		words = strings.Fields("AND IN CONTAINS KEY")
	case orderClause:
		words = strings.Fields("ASC DESC ANN LIMIT PER PARTITION")
	case groupClause:
		words = strings.Fields("ORDER BY LIMIT PER PARTITION")
	case setClause:
		words = strings.Fields("NULL WHERE IF USING TTL TIMESTAMP")
	}
	if insertValues {
		words = strings.Fields("NULL TRUE FALSE")
	}
	for _, name := range words {
		r.add(name, name, "CQL keyword", 14, 3)
	}
	if r.clause != orderClause && r.clause != groupClause {
		for _, name := range functions("cassandra") {
			if !r.cqlFunctionAllowed(name) {
				continue
			}
			insertion := name
			if !cqlSpecialSelector(name) && !(name == "TOKEN" && r.clause == predicateClause) {
				insertion = "system." + name
			}
			r.add(name, insertion, "Function · Cassandra", 3, 2)
		}
		for _, entry := range r.context.Catalog {
			if entry.Kind == "function" {
				r.add(entry.Name, qualifiedName(entry, "cassandra"), "Function · "+entry.Schema, 3, 2)
			}
		}
	}
}

func (r *request) cqlFunctionAllowed(name string) bool {
	if name == "TOJSON" {
		return r.clause == selectClause
	}
	if name == "FROMJSON" {
		return r.clause != selectClause
	}
	return r.clause != setClause
}

func (r *request) cqlInsertColumnList() bool {
	if len(r.before) < 3 || !word(r.before[0], "INSERT") || !word(r.before[1], "INTO") {
		return false
	}
	depth := 0
	for _, t := range r.before[2:] {
		if word(t, "VALUES") || word(t, "JSON") {
			return false
		}
		if punct(t, "(") {
			depth++
		} else if punct(t, ")") {
			depth--
		}
	}
	return depth == 1
}

// DDL names come from the same bounded catalog as DML. Only existing objects
// are suggested: CREATE's new object names must not be replaced by old ones.
func (r *request) cqlObjectNames() bool {
	tokens := r.before
	if len(tokens) == 0 {
		return false
	}
	position, kind := 1, ""
	switch {
	case word(tokens[0], "ALTER"), word(tokens[0], "DROP"):
		if len(tokens) <= position {
			return false
		}
		switch {
		case word(tokens[position], "TABLE"), word(tokens[position], "COLUMNFAMILY"):
			kind = "table"
		case word(tokens[position], "TYPE"):
			kind = "type"
		case word(tokens[position], "KEYSPACE"):
			kind = "keyspace"
		case word(tokens[position], "FUNCTION"), word(tokens[position], "AGGREGATE"):
			kind = "function"
		case word(tokens[position], "MATERIALIZED") && len(tokens) > position+1 && word(tokens[position+1], "VIEW"):
			kind = "view"
			position++
		default:
			return false
		}
		position++
	case word(tokens[0], "TRUNCATE"):
		kind = "table"
		if len(tokens) > position && word(tokens[position], "TABLE") {
			position++
		}
	default:
		return false
	}
	if len(tokens) >= position+2 && word(tokens[position], "IF") && word(tokens[position+1], "EXISTS") {
		position += 2
	}
	var qualifier *token
	if len(tokens) == position+2 && identifier(tokens[position]) && punct(tokens[position+1], ".") {
		qualifier = &tokens[position]
	} else if len(tokens) != position {
		return false
	}
	for _, entry := range r.context.Catalog {
		if kind == "keyspace" {
			if qualifier == nil && entry.Schema != "" {
				r.add(entry.Schema, quoteIdentifier(entry.Schema, "cassandra"), "Keyspace", 9, 0)
			}
			continue
		}
		if entry.Kind != kind || qualifier != nil && !identifierEqual(*qualifier, entry.Schema, "cassandra") {
			continue
		}
		insertion := qualifiedName(entry, "cassandra")
		if qualifier != nil {
			insertion = quoteIdentifier(entry.Name, "cassandra")
		}
		r.add(entry.Name, insertion, kind+" · "+entry.Schema, 7, 0)
		if qualifier == nil && entry.Schema != "" {
			r.add(entry.Schema, quoteIdentifier(entry.Schema, "cassandra"), "Keyspace", 9, 1)
		}
	}
	return true
}

func (r *request) cqlTypeNames() bool {
	tokens := r.before
	if len(tokens) == 0 || !(word(tokens[0], "CREATE") || word(tokens[0], "ALTER") || word(tokens[0], "DROP")) {
		return false
	}
	// An unfinished keyspace qualifier is retained while completing a UDT.
	var qualifier *token
	if len(tokens) >= 2 && identifier(tokens[len(tokens)-2]) && punct(tokens[len(tokens)-1], ".") {
		qualifier = &tokens[len(tokens)-2]
		tokens = tokens[:len(tokens)-2]
	}
	if len(tokens) == 0 {
		return false
	}
	last := tokens[len(tokens)-1]
	expectsType := word(last, "RETURNS") || word(last, "STYPE")
	// Column/UDT field and function argument declarations consist of one name
	// followed by a type, inside the first declaration list. Nested collection
	// arguments use angle brackets; commas there are not new column names.
	depth, segment := 0, -1
	angleTypes := []string{}
	declaration, unnamedParameters := false, false
	for _, t := range tokens[1:] {
		if word(t, "TABLE") || word(t, "COLUMNFAMILY") || word(t, "TYPE") || word(t, "FUNCTION") || word(t, "AGGREGATE") {
			declaration = true
		}
		if word(t, "AGGREGATE") || word(tokens[0], "DROP") && word(t, "FUNCTION") {
			unnamedParameters = true
		}
	}
	for i, t := range tokens {
		switch {
		case punct(t, "("):
			depth++
			if depth == 1 {
				segment = i + 1
			}
		case punct(t, ")"):
			depth--
			if depth == 0 {
				segment = -1
			}
		case punct(t, "<"):
			name := ""
			if i > 0 {
				name = strings.ToUpper(tokens[i-1].value)
			}
			angleTypes = append(angleTypes, name)
		case punct(t, ">"):
			if len(angleTypes) > 0 {
				angleTypes = angleTypes[:len(angleTypes)-1]
			}
		case punct(t, ",") && depth == 1 && len(angleTypes) == 0:
			segment = i + 1
		}
	}
	if declaration && depth == 1 && segment >= 0 && len(tokens)-segment == 1 && identifier(tokens[segment]) {
		expectsType = true
	}
	if declaration && unnamedParameters && depth == 1 && segment == len(tokens) {
		expectsType = true
	}
	if declaration && len(angleTypes) > 0 && (punct(last, "<") || punct(last, ",")) {
		expectsType = true
		if punct(last, ",") && angleTypes[len(angleTypes)-1] == "VECTOR" {
			// VECTOR's second argument is a numeric dimension, not a type.
			return true
		}
	}
	if word(tokens[0], "ALTER") && len(tokens) >= 2 && identifier(last) && word(tokens[len(tokens)-2], "ADD") {
		expectsType = true
	}
	if !expectsType {
		return false
	}
	keyspace := cqlDeclarationKeyspace(tokens, r.context.Keyspace)
	if qualifier == nil {
		for _, name := range cqlTypes {
			r.add(name, strings.ToLower(name), "CQL type", 25, 0)
		}
	}
	for _, entry := range r.context.Catalog {
		if entry.Kind != "type" || entry.Schema != keyspace || qualifier != nil && !identifierEqual(*qualifier, entry.Schema, "cassandra") {
			continue
		}
		insertion := qualifiedName(entry, "cassandra")
		if qualifier != nil {
			insertion = quoteIdentifier(entry.Name, "cassandra")
		}
		r.add(entry.Name, insertion, "User-defined type · "+entry.Schema, 25, 0)
	}
	return true
}

// CQL types belong to the enclosing declaration's keyspace. A UDT from
// another keyspace cannot be used by explicitly qualifying its name.
func cqlDeclarationKeyspace(tokens []token, current string) string {
	if len(tokens) < 3 || !(word(tokens[0], "CREATE") || word(tokens[0], "ALTER") || word(tokens[0], "DROP")) {
		return current
	}
	i := 1
	if len(tokens) > i+1 && word(tokens[i], "OR") && word(tokens[i+1], "REPLACE") {
		i += 2
	}
	if i >= len(tokens) || !(word(tokens[i], "TABLE") || word(tokens[i], "COLUMNFAMILY") || word(tokens[i], "TYPE") || word(tokens[i], "FUNCTION") || word(tokens[i], "AGGREGATE")) {
		return current
	}
	i++
	if i < len(tokens) && word(tokens[i], "IF") {
		i++
		if i < len(tokens) && word(tokens[i], "NOT") {
			i++
		}
		if i < len(tokens) && word(tokens[i], "EXISTS") {
			i++
		}
	}
	if len(tokens) > i+2 && identifier(tokens[i]) && punct(tokens[i+1], ".") && identifier(tokens[i+2]) {
		return identifierName(tokens[i], "cassandra")
	}
	return current
}

// These names are CQL parser selectors, not namespace-qualified function calls.
func cqlSpecialSelector(name string) bool {
	switch name {
	case "COUNT", "TTL", "WRITETIME", "MAXWRITETIME", "CAST":
		return true
	default:
		return false
	}
}
