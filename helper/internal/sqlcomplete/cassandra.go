package sqlcomplete

import "strings"

// Keep CQL suggestions separate from SQL: JOIN, OFFSET, RETURNING and SQL
// transaction commands are not valid Cassandra constructs. No completion
// silently adds ALLOW FILTERING to a generated query.
var cqlKeywords = strings.Fields("SELECT FROM WHERE AND IN CONTAINS KEY AS DISTINCT JSON ORDER BY ASC DESC LIMIT PER PARTITION GROUP INSERT INTO VALUES UPDATE SET DELETE USING TTL TIMESTAMP IF EXISTS NOT NULL TRUE FALSE CREATE ALTER DROP TRUNCATE TABLE KEYSPACE TYPE INDEX MATERIALIZED VIEW PRIMARY CLUSTERING STATIC WITH COMPACT STORAGE BEGIN UNLOGGED COUNTER BATCH APPLY USE GRANT REVOKE LIST ROLES USERS PERMISSIONS")

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
	for _, rule := range []struct {
		trigger string
		words   []string
	}{
		{"ORDER", []string{"BY"}}, {"GROUP", []string{"BY"}}, {"PER", []string{"PARTITION"}},
		{"INSERT", []string{"INTO"}}, {"DELETE", []string{"FROM"}},
		{"BEGIN", []string{"BATCH", "UNLOGGED BATCH", "COUNTER BATCH"}}, {"APPLY", []string{"BATCH"}},
		{"USING", []string{"TTL", "TIMESTAMP"}}, {"CONTAINS", []string{"KEY"}},
	} {
		if word(last, rule.trigger) {
			for _, name := range rule.words {
				r.add(name, name, "CQL keyword", 14, 3)
			}
			return
		}
	}
	// Table names after FROM/INTO/UPDATE and keyspace-qualified prefixes.
	if r.table {
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
	if r.clause == fromClause {
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
				if !cqlSpecialSelector(name) {
					r.add(name, name, "Native function · Cassandra", 3, 2)
				}
			}
			return
		}
		r.members()
		return
	}
	for _, src := range r.visible() {
		for _, column := range src.columns {
			detail := sourceDetail(src)
			for _, entry := range r.context.Catalog {
				if identifierEqual(src.name, entry.Name, "cassandra") {
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
			}
			r.add(column, quoteIdentifier(column, "cassandra"), detail, 5, 0)
		}
	}
	words := cqlKeywords
	switch r.clause {
	case selectClause:
		words = strings.Fields("AS DISTINCT JSON FROM WHERE GROUP ORDER LIMIT PER PARTITION")
	case predicateClause:
		words = strings.Fields("AND IN CONTAINS KEY")
	case orderClause:
		words = strings.Fields("ASC DESC LIMIT PER PARTITION")
	case groupClause:
		words = strings.Fields("ORDER BY LIMIT PER PARTITION")
	case setClause:
		words = strings.Fields("NULL WHERE IF USING TTL TIMESTAMP")
	}
	for _, name := range words {
		r.add(name, name, "CQL keyword", 14, 3)
	}
	if r.clause != orderClause && r.clause != groupClause && r.clause != setClause {
		for _, name := range functions("cassandra") {
			insertion := name
			if !cqlSpecialSelector(name) {
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

// These names are CQL parser selectors, not namespace-qualified function calls.
func cqlSpecialSelector(name string) bool {
	switch name {
	case "COUNT", "TTL", "WRITETIME", "MAXWRITETIME", "CAST":
		return true
	default:
		return false
	}
}
