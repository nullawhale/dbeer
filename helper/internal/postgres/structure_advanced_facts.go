package postgres

import (
	"dbeer/helper/internal/tableedit"
	"errors"
	"fmt"
	"sort"
)

func pgAdvancedPublicFacts(support *tableedit.AdvancedKindSupport, proof *tableedit.AdvancedEvidence) error {
	if support == nil {
		return nil
	}
	roleNames := map[string]string{"0": "PUBLIC"}
	for _, role := range proof.Rows["global/roles"] {
		name, ok := role["rolname"].(string)
		if !ok {
			return tableedit.ErrUnsupported
		}
		roleNames[pgPhysicalOID(role["oid"])] = name
	}
	ids := map[tableedit.Target]string{}
	for id, facts := range proof.Facts {
		ids[tableedit.Target{Schema: facts.Table.Ref.Schema, Table: facts.Table.Ref.Name}] = id
	}
	support.Relations = []tableedit.AdvancedRelationFact{}
	for _, target := range proof.Targets {
		id := ids[target]
		classes := proof.Rows[id+"/class"]
		if len(classes) != 1 {
			return tableedit.ErrUnsupported
		}
		class := classes[0]
		kind := "table"
		if class["relkind"] == "p" {
			kind = "partitionedTable"
		}
		persistence := "permanent"
		if class["relpersistence"] == "u" {
			persistence = "unlogged"
		}
		relation := tableedit.AdvancedRelationFact{Target: target, Kind: kind, Persistence: persistence, PartitionMember: class["relispartition"] == true, Parents: []tableedit.Target{}, RowSecurity: class["relrowsecurity"] == true, ForceRowSecurity: class["relforcerowsecurity"] == true, Policies: []tableedit.AdvancedPolicyFact{}}
		parents := map[string]bool{}
		for _, link := range proof.Rows[id+"/inherits"] {
			if pgPhysicalOID(link["inhrelid"]) == id {
				parent := pgPhysicalOID(link["inhparent"])
				if fact := proof.Facts[parent]; fact != nil && !parents[parent] {
					parents[parent] = true
					relation.Parents = append(relation.Parents, tableedit.Target{Schema: fact.Table.Ref.Schema, Table: fact.Table.Ref.Name})
				}
			}
		}
		sort.Slice(relation.Parents, func(i, j int) bool {
			if relation.Parents[i].Schema != relation.Parents[j].Schema {
				return relation.Parents[i].Schema < relation.Parents[j].Schema
			}
			return relation.Parents[i].Table < relation.Parents[j].Table
		})
		binding := proof.Rows[id+"/typeBinding"]
		if len(binding) > 1 {
			return tableedit.ErrUnsupported
		}
		if len(binding) == 1 {
			schema, sok := binding[0]["schema"].(string)
			name, nok := binding[0]["name"].(string)
			if !sok || !nok {
				return tableedit.ErrUnsupported
			}
			relation.TypeBinding = &tableedit.TypeReference{Schema: schema, Name: name}
		}
		for _, policy := range proof.Rows[id+"/policies"] {
			name, ok := policy["polname"].(string)
			command := map[string]string{"*": "all", "r": "select", "a": "insert", "w": "update", "d": "delete"}[fmt.Sprint(policy["polcmd"])]
			permissive, pok := policy["polpermissive"].(bool)
			if !ok || !pok || command == "" {
				return tableedit.ErrUnsupported
			}
			fact := tableedit.AdvancedPolicyFact{Name: name, Command: command, Permissive: permissive, Roles: []string{}}
			for _, id := range pgAdvancedAttnums(policy["polroles"]) {
				role, ok := roleNames[id]
				if !ok {
					return errors.New("A retained row-security policy role could not be described completely.")
				}
				fact.Roles = append(fact.Roles, role)
			}
			sort.Strings(fact.Roles)
			relation.Policies = append(relation.Policies, fact)
		}
		support.Relations = append(support.Relations, relation)
	}
	return nil
}
