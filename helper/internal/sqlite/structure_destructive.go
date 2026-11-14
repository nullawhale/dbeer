package sqlite

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"dbeer/helper/internal/tableedit"
)

type structureSchemaRow struct{ Kind, Name, Table, SQL string }

func (s *Session) structureSchema(ctx context.Context, temp bool) ([]structureSchemaRow, error) {
	schema := "main.sqlite_schema"
	if temp {
		schema = "temp.sqlite_schema"
	}
	rows, _, err := s.query(ctx, "SELECT type,name,tbl_name,COALESCE(sql,'') FROM "+schema+" ORDER BY type,name")
	if err != nil {
		return nil, err
	}
	out := []structureSchemaRow{}
	for _, r := range rows {
		out = append(out, structureSchemaRow{cellText(r[0]), cellText(r[1]), cellText(r[2]), cellText(r[3])})
	}
	return out, nil
}
func ddlMentions(raw, name string) bool {
	tokens, err := ddlScan(raw)
	if err != nil {
		return true
	}
	for _, t := range tokens {
		if t.group {
			if ddlMentions(raw[t.start+1:t.end-1], name) {
				return true
			}
			continue
		}
		value, ok := ddlName(raw, t)
		if ok && ddlFold(value) == ddlFold(name) {
			return true
		}
	}
	return false
}
func (s *Session) prepareStructureDestructive(ctx context.Context, b tableedit.Baseline, d tableedit.Draft) (tableedit.Prepared, error) {
	p := tableedit.Prepared{DroppedTarget: d.DropTable, Risks: []string{"DROP permanently removes the selected data after COMMIT. Apply runs all displayed SQLite steps in one BEGIN IMMEDIATE transaction; cancellation before COMMIT rolls back the transaction, and a lost COMMIT acknowledgement is never replayed.", "DROP COLUMN can rewrite the entire table and take the database write lock. Preview reads schema metadata only. Separate validation scans rows only after explicit authorization; its historical count cannot authorize Apply or prove later values."}}
	if b.Target.Create || len(d.Columns) > 0 || len(d.Keys) > 0 || d.RenameTable != nil {
		return p, errors.New("Review SQLite DROP separately from additions, renames and key reconstruction.")
	}
	dropped := map[string]bool{}
	for _, c := range d.Changes {
		if !c.Drop {
			return p, errors.New("SQLite has no direct ALTER COLUMN TYPE, USING, signedness or per-column encoding conversion; use a separately reviewed reconstruction plan.")
		}
		found := false
		for _, old := range b.Columns {
			found = found || old.Name == c.Name
		}
		if !found {
			return p, tableedit.ErrInvalid
		}
		dropped[c.Name] = true
	}
	if !d.DropTable && len(dropped) == 0 {
		return p, tableedit.ErrInvalid
	}
	if !d.DropTable && len(dropped) >= len(b.Columns) {
		return p, errors.New("Keep at least one column; review DROP TABLE separately.")
	}
	foreignKeys, _, foreignErr := s.query(ctx, "PRAGMA foreign_keys")
	if foreignErr != nil || len(foreignKeys) != 1 || cellInt(foreignKeys[0][0]) != 1 {
		return p, errors.New("Native SQLite DROP requires foreign_keys=ON; the setting is never disabled for destructive operations.")
	}
	version, _, err := s.query(ctx, "SELECT sqlite_version()")
	if err != nil || len(version) != 1 {
		return p, tableedit.ErrUnsupported
	}
	components := strings.Split(cellText(version[0][0]), ".")
	if len(components) < 2 {
		return p, tableedit.ErrUnsupported
	}
	major, _ := strconv.Atoi(components[0])
	minor, _ := strconv.Atoi(components[1])
	if !d.DropTable && (major < 3 || major == 3 && minor < 35) {
		return p, errors.New("Native SQLite DROP COLUMN requires SQLite 3.35 or later; this engine requires an explicit reconstruction.")
	}
	raw, _ := b.Attributes["sqlite"]["sql"].(string)
	parsed, err := parseDDLTable(raw)
	if err != nil {
		return p, errors.New("Native DROP requires a complete ordinary SQLite table definition.")
	}
	for _, k := range b.Keys {
		for _, n := range k.Columns {
			if dropped[n] {
				return p, fmt.Errorf("Column %s belongs to primary key %s; key reconstruction requires a separate reviewed plan.", n, k.Name)
			}
		}
	}
	removedIndexes := map[string]bool{}
	for _, x := range d.Indexes {
		if x.Action != "drop" {
			return p, errors.New("Review index additions and replacements separately from native SQLite DROP COLUMN.")
		}
		found := false
		for _, old := range b.Indexes {
			found = found || old.Name == x.Name && old.Supported
		}
		if !found {
			return p, tableedit.ErrUnsupported
		}
		removedIndexes[x.Name] = true
		p.SQL = append(p.SQL, "DROP INDEX main."+quote(x.Name)+";")
		edit := x
		p.Conditions = append(p.Conditions, tableedit.Condition{Operation: tableedit.Operation{Kind: "dropIndex", Index: &edit}})
	}
	schema, err := s.structureSchema(ctx, false)
	if err != nil {
		return p, err
	}
	temp, err := s.structureSchema(ctx, true)
	if err != nil {
		return p, err
	}
	for _, row := range append(append([]structureSchemaRow{}, schema...), temp...) {
		if row.Kind == "view" || row.Kind == "trigger" {
			if d.DropTable && row.Kind == "trigger" && row.Table == b.Target.Table {
				p.Consequences = append(p.Consequences, tableedit.Consequence{Kind: "dependency", Object: row.Name, Message: "This table-owned trigger is removed with the table."})
				continue
			}
			if ddlMentions(row.SQL, b.Target.Table) {
				return p, fmt.Errorf("Native DROP requires explicit repair of dependent %s %s; its definition refers to the selected table.", row.Kind, row.Name)
			}
		}
		if row.Kind == "table" && !strings.HasPrefix(row.Name, "sqlite_") {
			foreign, _, e := s.query(ctx, "PRAGMA main.foreign_key_list("+quote(row.Name)+")")
			if e != nil {
				return p, e
			}
			for _, fk := range foreign {
				if ddlFold(cellText(fk[2])) != ddlFold(b.Target.Table) {
					continue
				}
				if d.DropTable && row.Name == b.Target.Table {
					continue
				}
				if d.DropTable || dropped[cellText(fk[4])] {
					return p, fmt.Errorf("Native DROP is blocked by an incoming foreign key from table %s.", row.Name)
				}
			}
		}
		if !d.DropTable && row.Kind == "index" && row.Table == b.Target.Table && !removedIndexes[row.Name] {
			for name := range dropped {
				if ddlMentions(row.SQL, name) {
					return p, fmt.Errorf("Explicitly remove dependent index %s before dropping column %s.", row.Name, name)
				}
			}
		}
	}
	if !d.DropTable {
		for _, term := range parsed.terms {
			if dropped[term.name] {
				for _, t := range term.tokens {
					if t.word == "PRIMARY" || t.word == "UNIQUE" || t.word == "REFERENCES" {
						return p, fmt.Errorf("Column %s contains a key or reference clause; native DROP requires explicit reconstruction.", term.name)
					}
				}
				continue
			}
			for name := range dropped {
				if ddlMentions(term.raw, name) {
					return p, fmt.Errorf("Column %s is referenced by a retained CHECK, generated expression or table constraint; repair it explicitly.", name)
				}
			}
		}
	}
	target := "main." + quote(b.Target.Table)
	if d.DropTable {
		p.SQL = []string{"DROP TABLE " + target + ";"}
		p.Conditions = []tableedit.Condition{{Operation: tableedit.Operation{Kind: "dropTable"}}}
		p.Consequences = append(p.Consequences, tableedit.Consequence{Kind: "dataLoss", Object: b.Target.Table, Message: "All rows, column definitions, table-owned indexes, keys and triggers are permanently removed after COMMIT. SQLite DROP with foreign keys enabled can otherwise perform implicit DELETE actions; incoming references block this plan and foreign-key enforcement stays enabled."})
		for _, x := range b.Indexes {
			p.Consequences = append(p.Consequences, tableedit.Consequence{Kind: "dependency", Object: x.Name, Message: "This table-owned index is removed with the table."})
		}
	} else {
		for _, c := range d.Changes {
			p.SQL = append(p.SQL, "ALTER TABLE "+target+" DROP COLUMN "+quote(c.Name)+";")
			change := c
			p.Conditions = append(p.Conditions, tableedit.Condition{Operation: tableedit.Operation{Kind: "dropColumn", Change: &change}})
			p.Consequences = append(p.Consequences, tableedit.Consequence{Kind: "dataLoss", Object: c.Name, Message: "Every stored value in this column is permanently removed after COMMIT; the remaining exact native values are verified during Apply."})
		}
	}
	sql := "SELECT count(*) FROM " + target + ";"
	p.ValidationChecks = []tableedit.ValidationCheck{{ID: "rows-at-risk", Summary: "Count rows whose selected table or column values would be permanently removed", SQL: &sql, Risks: []string{"Explicit validation reads stored data in a read-only transaction with a 30-second operation limit and may scan the whole table. Only an exact row count is retained; no row samples or values are returned. The count is historical and is not Apply authorization."}}}
	return p, nil
}
func structureDroppedColumns(p tableedit.Plan) map[string]bool {
	out := map[string]bool{}
	for _, c := range p.Conditions {
		if c.Operation.Kind == "dropColumn" && c.Operation.Change != nil {
			out[c.Operation.Change.Name] = true
		}
	}
	return out
}
func (s *Session) StructureValidate(ctx context.Context, b tableedit.Baseline, p tableedit.Plan) []tableedit.ValidationResult {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	out := make([]tableedit.ValidationResult, len(p.ValidationChecks))
	for i, c := range p.ValidationChecks {
		out[i] = tableedit.ValidationResult{ID: c.ID, State: "notStarted"}
	}
	fail := func(msg string) []tableedit.ValidationResult {
		if len(out) > 0 {
			out[0].State = "failed"
			out[0].Message = msg
		}
		return out
	}
	if ctx.Err() != nil {
		return out
	}
	if s.TransactionStatus() != "idle" || s.checkIdentity() != nil {
		return fail("Validation requires the original idle SQLite session.")
	}
	previous, _, previousErr := s.query(ctx, "PRAGMA query_only")
	if previousErr != nil || len(previous) != 1 {
		return fail("The original SQLite read-only setting could not be captured.")
	}
	if err := s.exec(ctx, "PRAGMA query_only=ON"); err != nil {
		return fail("The read-only validation scope could not be established.")
	}
	defer func() {
		if cellInt(previous[0][0]) == 0 {
			_ = s.exec(context.Background(), "PRAGMA query_only=OFF")
		}
	}()
	if err := s.exec(ctx, "BEGIN"); err != nil {
		return fail("The read-only validation transaction could not begin.")
	}
	defer func() { _ = s.exec(context.Background(), "ROLLBACK") }()
	fresh, err := s.StructureLoad(ctx, b.Target)
	if err != nil || fresh.Fingerprint != b.Fingerprint {
		return fail("The captured schema changed. Prepare a new preview before validation.")
	}
	for i, c := range p.ValidationChecks {
		if ctx.Err() != nil {
			out[i].State = "cancelled"
			break
		}
		if c.SQL == nil {
			out[i].State = "unavailable"
			out[i].Message = *c.UnavailableReason
			continue
		}
		rows, _, err := s.query(ctx, *c.SQL)
		if err != nil || len(rows) != 1 || len(rows[0]) != 1 {
			out[i].State = "failed"
			out[i].Message = "The read-only data validation could not complete. No Apply was authorized."
			break
		}
		value := rows[0][0].Value
		out[i].InvalidRows = &value
		out[i].State = "passed"
		if value != "0" {
			out[i].State = "failed"
		}
	}
	return out
}
