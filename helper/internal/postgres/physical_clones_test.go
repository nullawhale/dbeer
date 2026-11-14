package postgres

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"testing"
)

func TestPhysicalPostgresMappedClonesAndMutationRejectionLive(t *testing.T) {
	f := newChangeFixture(t)
	s := &Session{conn: f.conn}
	f.exec("CREATE TABLE " + f.table("ref") + "(id int PRIMARY KEY)")
	f.exec("CREATE TABLE " + f.table("p") + "(id int NOT NULL,owner int,note text,CONSTRAINT positive CHECK(id>=0),CONSTRAINT pk PRIMARY KEY(id),CONSTRAINT fk FOREIGN KEY(owner) REFERENCES " + f.table("ref") + "(id) DEFERRABLE INITIALLY DEFERRED) PARTITION BY RANGE(id)")
	f.exec("CREATE INDEX p_note ON " + f.table("p") + "(note)")
	f.exec("CREATE FUNCTION " + f.table("trigger_f") + "() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RETURN NEW; END$$")
	f.exec("CREATE TRIGGER keep BEFORE INSERT ON " + f.table("p") + " FOR EACH ROW WHEN(NEW.id>0) EXECUTE FUNCTION " + f.table("trigger_f") + "()")
	f.exec("CREATE TABLE " + f.table("incoming") + "(pid int REFERENCES " + f.table("p") + "(id))")
	f.exec("CREATE TABLE " + f.table("c") + "(note text,id int NOT NULL,owner int,CONSTRAINT positive CHECK(id>=0))")
	f.exec("CREATE INDEX own_note ON " + f.table("c") + "(note)")
	f.exec("CREATE TRIGGER own BEFORE UPDATE ON " + f.table("c") + " FOR EACH ROW EXECUTE FUNCTION " + f.table("trigger_f") + "()")
	d := tableedit.PhysicalDraft{Version: 1, Target: tableedit.Target{Schema: f.schema, Table: "p"}, Intent: tableedit.PhysicalIntent{Kind: "attachPartition", Child: &tableedit.Target{Schema: f.schema, Table: "c"}, Bound: &tableedit.PhysicalBound{Kind: "range", From: []tableedit.PhysicalValue{pgE6Value("0")}, To: []tableedit.PhysicalValue{pgE6Value("10")}}}}
	plan, e := s.PhysicalPrepare(context.Background(), d)
	if e != nil {
		t.Fatal(e)
	}
	before, ok := plan.Evidence.(pgPhysicalEvidence)
	if !ok {
		t.Fatal("private proof unavailable")
	}
	executions := s.PhysicalExecute(context.Background(), plan, func(int, string) {})
	if len(executions) != 1 || executions[0].State != "applied" || executions[0].Message != "" {
		t.Fatal("mapped nonempty clone execution/preservation failed")
	}
	after, e := s.pgPhysicalInspect(context.Background(), d)
	if e != nil || !pgPhysicalCloneChanges(before, after, d.Intent.Kind) {
		t.Fatal("mapped native clone proof rejected")
	}
	clone := func() pgPhysicalEvidence {
		raw, _ := json.Marshal(after)
		var v pgPhysicalEvidence
		_ = json.Unmarshal(raw, &v)
		return v
	}
	childIndex := -1
	for i, r := range after.Relations {
		if r.Target == *d.Intent.Child {
			childIndex = i
		}
	}
	if childIndex < 0 {
		t.Fatal("child metadata absent")
	}
	mutate := func(v *pgPhysicalEvidence, category, key string, value any) {
		r := &v.Relations[childIndex]
		var records *[]json.RawMessage
		switch category {
		case "constraint":
			records = &r.Constraints
		case "index", "indexClass":
			records = &r.Indexes
		case "trigger":
			records = &r.Triggers
		}
		for i, raw := range *records {
			m, ok := pgPhysicalMap(raw)
			if !ok {
				t.Fatal("fixture catalog malformed")
			}
			if category == "constraint" && (m["contype"] != "f" || pgPhysicalOID(m["conrelid"]) != strconv.FormatUint(uint64(r.OID), 10)) {
				continue
			}
			if category == "trigger" && (fmt.Sprint(m["tgconstraint"]) != "0" || pgPhysicalOID(m["tgparentid"]) == "") {
				continue
			}
			if category == "index" {
				nested, _ := m["index"].(map[string]any)
				if old, ok := nested[key].(bool); ok && old == value {
					value = !old
				}
				nested[key] = value
			} else if category == "indexClass" {
				nested, _ := m["class"].(map[string]any)
				nested[key] = value
			} else {
				if old, ok := m[key].(bool); ok && old == value {
					value = !old
				}
				m[key] = value
			}
			(*records)[i], _ = json.Marshal(m)
			return
		}
		t.Fatal("mutation category had no nonempty fixture")
	}
	mutations := map[string]func(*pgPhysicalEvidence){}
	for key, value := range map[string]any{"conrelid": "1", "confrelid": "1", "conkey": []any{float64(1)}, "confkey": []any{float64(999)}, "convalidated": false, "condeferrable": false, "condeferred": false, "confupdtype": "c", "confdeltype": "c", "confmatchtype": "f", "conpfeqop": []any{float64(1)}, "connamespace": "1", "conparentid": "1", "connoinherit": true} {
		key, value := key, value
		mutations["constraint-"+key] = func(v *pgPhysicalEvidence) { mutate(v, "constraint", key, value) }
	}
	for key, value := range map[string]any{"indrelid": "1", "indkey": []any{float64(999)}, "indisunique": true, "indclass": []any{float64(1)}, "indoption": []any{float64(99)}, "indpred": "{CONST :consttype 16 :constvalue 1 [ 1 ]}", "unknownProperty": true} {
		key, value := key, value
		mutations["index-"+key] = func(v *pgPhysicalEvidence) { mutate(v, "index", key, value) }
	}
	for key, value := range map[string]any{"relnamespace": "1", "relowner": "1", "reloptions": []any{"fillfactor=10"}, "unknownProperty": true} {
		key, value := key, value
		mutations["index-class-"+key] = func(v *pgPhysicalEvidence) { mutate(v, "indexClass", key, value) }
	}
	for key, value := range map[string]any{"tgrelid": "1", "tgparentid": "1", "tgisinternal": false, "tgfoid": "1", "tgtype": float64(0), "tgenabled": "D", "tgargs": "\\x01", "tgqual": "{VAR :varno 2 :varattno 1 :vartype 23}", "tgconstraint": "1", "unknownProperty": true} {
		key, value := key, value
		mutations["trigger-"+key] = func(v *pgPhysicalEvidence) { mutate(v, "trigger", key, value) }
	}
	mutations["missing-index-clone"] = func(v *pgPhysicalEvidence) { r := &v.Relations[childIndex]; r.Indexes = r.Indexes[1:] }
	mutations["missing-constraint-clone"] = func(v *pgPhysicalEvidence) {
		r := &v.Relations[childIndex]
		for i, raw := range r.Constraints {
			m, _ := pgPhysicalMap(raw)
			if pgPhysicalOID(m["conparentid"]) != "" {
				r.Constraints = append(r.Constraints[:i], r.Constraints[i+1:]...)
				return
			}
		}
		t.Fatal("missing fixture")
	}
	mutations["missing-trigger-clone"] = func(v *pgPhysicalEvidence) {
		r := &v.Relations[childIndex]
		for i, raw := range r.Triggers {
			m, _ := pgPhysicalMap(raw)
			if pgPhysicalOID(m["tgparentid"]) != "" {
				r.Triggers = append(r.Triggers[:i], r.Triggers[i+1:]...)
				return
			}
		}
		t.Fatal("missing fixture")
	}
	mutations["extra-index-without-origin"] = func(v *pgPhysicalEvidence) {
		r := &v.Relations[childIndex]
		m, _ := pgPhysicalMap(r.Indexes[0])
		c := m["class"].(map[string]any)
		i := m["index"].(map[string]any)
		c["oid"] = "999999"
		c["relname"] = "unreviewed"
		i["indexrelid"] = "999999"
		m["parents"] = []any{}
		raw, _ := json.Marshal(m)
		r.Indexes = append(r.Indexes, raw)
	}
	mutations["extra-trigger-without-origin"] = func(v *pgPhysicalEvidence) {
		r := &v.Relations[childIndex]
		m, _ := pgPhysicalMap(r.Triggers[0])
		m["oid"] = "999999"
		m["tgparentid"] = "0"
		m["tgname"] = "unreviewed"
		raw, _ := json.Marshal(m)
		r.Triggers = append(r.Triggers, raw)
	}
	if before.Version < 150000 {
		for key, value := range map[string]any{"tgparentid": "1", "tgfoid": "1", "tgconstraint": "1", "tgconstrrelid": "1", "tgconstrindid": "1", "tgisinternal": false, "tgenabled": "D", "tgtype": float64(0), "tgdeferrable": false, "tginitdeferred": false, "tgargs": "\\x01", "tgqual": "unreviewed", "unknownProperty": true} {
			key, value := key, value
			mutations["legacy-FK-"+key] = func(v *pgPhysicalEvidence) {
				r := &v.Relations[childIndex]
				for i, raw := range r.Triggers {
					m, _ := pgPhysicalMap(raw)
					if pgPhysicalOID(m["tgparentid"]) == "" && pgPhysicalOID(m["tgconstraint"]) != "" {
						if old, ok := m[key].(bool); ok && old == value {
							value = !old
						}
						m[key] = value
						r.Triggers[i], _ = json.Marshal(m)
						return
					}
				}
				t.Fatal("legacy FK trigger fixture absent")
			}
		}
		mutations["legacy-FK-missing-pair"] = func(v *pgPhysicalEvidence) {
			r := &v.Relations[childIndex]
			for i, raw := range r.Triggers {
				m, _ := pgPhysicalMap(raw)
				if pgPhysicalOID(m["tgparentid"]) == "" && pgPhysicalOID(m["tgconstraint"]) != "" {
					r.Triggers = append(r.Triggers[:i], r.Triggers[i+1:]...)
					return
				}
			}
			t.Fatal("legacy FK trigger fixture absent")
		}
	}
	for name, change := range mutations {
		t.Run(name, func(t *testing.T) {
			v := clone()
			change(&v)
			if pgPhysicalCloneChanges(before, v, d.Intent.Kind) {
				t.Fatal("unproven clone mutation was admitted")
			}
		})
	}
	// The check's mapped VAR must refer to child ordinal 2, never parent ordinal 1.
	for _, raw := range after.Relations[childIndex].Constraints {
		m, _ := pgPhysicalMap(raw)
		if m["contype"] == "c" {
			node, _ := m["conbin"].(string)
			if !strings.Contains(node, ":varattno 2 ") {
				t.Fatal("reordered CHECK fixture did not exercise attribute mapping")
			}
		}
	}
}
