package postgres

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"errors"
	"fmt"
	"github.com/jackc/pgx/v5"
	"reflect"
	"strings"
	"time"
)

func (s *Session) prepareStructureReconstruction(ctx context.Context, b tableedit.Baseline, d tableedit.Draft, migration ...bool) (tableedit.Prepared, error) {
	order, err := tableedit.ReconstructionOrder(b, d)
	if err != nil {
		return tableedit.Prepared{}, err
	}
	if d.Reconstruct || len(d.ColumnOrder) > 0 {
		return s.preparePGRebuild(ctx, b, d, order, len(migration) > 0 && migration[0])
	}
	relaxed := tableedit.Draft{AuthoringVersion: 2, Columns: append([]tableedit.Column(nil), d.Columns...)}
	for i := range relaxed.Columns {
		relaxed.Columns[i].Nullable = true
	}
	p, err := s.StructurePrepare(ctx, b, relaxed)
	if err != nil {
		return p, err
	}
	target := pgx.Identifier{b.Target.Schema, b.Target.Table}.Sanitize()
	for _, x := range d.Backfills {
		expression, e := tableedit.ExpressionSlot("postgresql", x.Expression)
		if e != nil {
			return p, e
		}
		name := pgx.Identifier{x.Column}.Sanitize()
		p.SQL = append(p.SQL, "UPDATE "+target+" SET "+name+" = "+expression+" WHERE "+name+" IS NULL;", "ALTER TABLE "+target+" ALTER COLUMN "+name+" SET NOT NULL;")
		required := false
		p.Conditions = append(p.Conditions, tableedit.Condition{Operation: tableedit.Operation{Kind: "backfill"}}, tableedit.Condition{Operation: tableedit.Operation{Kind: "changeColumn", Change: &tableedit.ColumnChange{Name: x.Column, Nullable: &required}}})
	}
	p.Consequences, p.ValidationChecks = tableedit.ReconstructionReview(b, d)
	p.Risks = []string{"The displayed ADD, UPDATE and SET NOT NULL statements commit independently, each under the existing dedicated-session ACCESS EXCLUSIVE lock, metadata recheck and five-second lock wait. Earlier acknowledged steps survive later failure or Stop; no implicit replay occurs.", "Preview is catalog-only. Backfill reads and writes rows only during Apply. Expressions, triggers and constraints may run user code, change other values or external state, block or fail. Concurrent inserts between steps can make NOT NULL fail. Review every displayed statement and consequence."}
	return p, nil
}

// PostgreSQL has no ALTER COLUMN position. Only a positively proven ordinary
// subset can change physical order by transactional copy/drop/rename.
func (s *Session) preparePGRebuild(ctx context.Context, b tableedit.Baseline, d tableedit.Draft, order []string, migration bool) (tableedit.Prepared, error) {
	p := tableedit.Prepared{}
	if len(d.Columns) > 0 {
		return p, errors.New("Review PostgreSQL backfill separately from physical reconstruction.")
	}
	if err := pgRebuildFacts(b); err != nil {
		return p, err
	}
	if !pgRebuildCatalog(ctx, s.conn, b, migration) {
		return p, errors.New("Reconstruction requires a table owned by the active role, default privileges/storage/replica identity, no ACLs, comments, policies, rules, publications, security labels, table or event triggers, and no owned sequences. Preserve those properties in an explicit multi-object migration.")
	}
	temp := "__dbeer_rebuild_" + b.Fingerprint[:12]
	if _, err := s.StructureLoad(ctx, tableedit.Target{Schema: b.Target.Schema, Table: temp, Create: true}); err != nil {
		return p, errors.New("The exact reconstruction destination must be absent.")
	}
	quote := func(n string) string { return pgx.Identifier{n}.Sanitize() }
	target := pgx.Identifier{b.Target.Schema, b.Target.Table}.Sanitize()
	temporary := pgx.Identifier{b.Target.Schema, temp}.Sanitize()
	definitions := []string{}
	names := []string{}
	for _, n := range order {
		c, ok := tableedit.FindColumn(b, n)
		if !ok {
			return p, tableedit.ErrUnsupported
		}
		renderer := pgDefinition{w: &sc.DefinitionWriter{Context: ctx}}
		nullNames := []string{}
		for _, k := range b.Facts.Table.Constraints.Items {
			if k.Kind.Value != nil && *k.Kind.Value == "n" && len(k.Columns.Items) == 1 && k.Columns.Items[0] == c.Ref {
				nullNames = append(nullNames, k.Ref.Name)
			}
		}
		if len(nullNames) > 0 {
			c.Nullable = sc.Known(true)
		}
		renderer.column(c, false)
		for _, name := range nullNames {
			renderer.write(" CONSTRAINT ", quote(name), " NOT NULL")
		}
		def, e := renderer.w.Finish()
		if e != nil || def.Limited {
			return p, tableedit.ErrUnsupported
		}
		definitions = append(definitions, def.SQL)
		names = append(names, quote(n))
	}
	joined := strings.Join(names, ",")
	p.SQL = []string{"CREATE TABLE " + temporary + " (" + strings.Join(definitions, ",") + ");", "INSERT INTO " + temporary + " (" + joined + ") SELECT " + joined + " FROM " + target + ";", "DROP TABLE " + target + " RESTRICT;", "ALTER TABLE " + temporary + " RENAME TO " + quote(b.Target.Table) + ";"}
	// Retained keys and indexes are recreated only after the original relation is
	// gone, so their exact original names remain available without silent renames.
	for _, k := range b.Facts.Table.Constraints.Items {
		if k.Kind.Value != nil && *k.Kind.Value == "n" {
			continue
		}
		renderer := pgDefinition{w: &sc.DefinitionWriter{Context: ctx}}
		for i := range b.Facts.Table.Indexes.Items {
			x := &b.Facts.Table.Indexes.Items[i]
			if x.Constraint.Value != nil && *x.Constraint.Value == k.Ref {
				renderer.constraint(k, x, false)
				break
			}
		}
		definition, e := renderer.w.Finish()
		if e != nil || definition.Limited || definition.SQL == "" {
			return p, tableedit.ErrUnsupported
		}
		p.SQL = append(p.SQL, "ALTER TABLE "+target+" ADD "+definition.SQL+";")
	}
	for _, x := range b.Facts.Table.Indexes.Items {
		if x.Constraint.Value == nil {
			renderer := pgDefinition{w: &sc.DefinitionWriter{Context: ctx}}
			renderer.index(x, b.Facts.Table.Ref)
			definition, e := renderer.w.Finish()
			if e != nil || definition.Limited || definition.SQL == "" {
				return p, tableedit.ErrUnsupported
			}
			p.SQL = append(p.SQL, definition.SQL)
		}
	}
	p.Reconstruction = &tableedit.Reconstruction{Method: "postgresql-copy", ColumnOrder: order, TemporaryTable: temp}
	p.Consequences, p.ValidationChecks = tableedit.ReconstructionReview(b, d)
	p.Risks = []string{"PostgreSQL physical column order requires a new relation: CREATE, INSERT SELECT, exact-value verification, DROP RESTRICT, RENAME and retained key/index recreation run in one transaction under ACCESS EXCLUSIVE locking and a five-second lock wait. Relation OID and physical row locations change. No CASCADE or dependent-object repair is generated.", "Before COMMIT, binary representations of every retained value and duplicate multiplicity are compared in both directions, and all retained catalog facts and attributes are checked. Unknown COMMIT acknowledgement retires this physical connection; status retains uncertainty without replay."}
	return p, nil
}

func pgRebuildFacts(b tableedit.Baseline) error {
	fail := func() error {
		return errors.New("PostgreSQL reconstruction requires complete ordinary built-in column facts, plain retained primary/unique keys and btree indexes, with no generated/identity/default expressions, owned sequences, incoming foreign keys or dependent objects. The original table is never dropped with CASCADE.")
	}
	if b.Facts == nil || !b.Facts.Proof || !b.Facts.Table.Columns.Complete || !b.Facts.Table.Constraints.Complete || !b.Facts.Table.Indexes.Complete || len(b.Facts.Sequences) > 0 || len(b.Facts.Incoming) > 0 || len(b.Facts.RawExpressions) > 0 {
		return fmt.Errorf("Reconstruction lacks complete table facts: %w", fail())
	}
	for _, deps := range b.Facts.Dependents {
		if len(deps) > 0 {
			return fmt.Errorf("Reconstruction has a dependent object: %w", fail())
		}
	}
	if len(b.Columns) == 0 {
		return errors.New("Reconstruction requires at least one retained column.")
	}
	for _, a := range b.Attributes {
		if a["attisdropped"] == true || a["atthasmissing"] == true || a["attmissingval"] != nil {
			return errors.New("Dropped physical attributes or fast-default storage require an explicit reconstruction migration; their raw catalog evidence is never silently discarded.")
		}
	}
	for _, c := range b.Facts.Table.Columns.Items {
		typ, ok := tableedit.ColumnType(c)
		if !ok || !tableedit.PostgresBuiltinIdentity(c, b.Attributes[c.Ref.Name]) || c.Default.Value == nil || c.Default.Value.Kind != "none" || c.Generated.Value == nil || c.Generated.Value.Kind != "none" || c.Identity.Value == nil || c.Identity.Value.Kind != "none" || c.Comment.Value == nil || *c.Comment.Value != "" || c.OnUpdate.Value != nil {
			return fmt.Errorf("Column %s has an unpreservable type, default, generation, identity or comment: %w", c.Ref.Name, fail())
		}
		if c.Collation.Value != nil && (c.Collation.Value.Schema != "pg_catalog" || c.Collation.Value.Name != "default") {
			return fmt.Errorf("Column %s has a custom collation: %w", c.Ref.Name, fail())
		}
		a := b.Attributes[c.Ref.Name]
		checks := []struct {
			name string
			safe bool
		}{
			{"storage", a != nil && a["attstorage"] == b.Facts.TypeStorage[typ.Kind]},
			{"compression", a != nil && (a["attcompression"] == "" || a["attcompression"] == "\x00")},
			{"permissions", a != nil && a["attacl"] == nil},
			{"options", a != nil && tableedit.EmptyPostgresOptions(a["attoptions"]) && a["attfdwoptions"] == nil},
			{"statistics", a != nil && (a["attstattarget"] == nil || a["attstattarget"] == float64(-1))},
			{"dimensions", a != nil && a["attndims"] == float64(0)},
			{"inheritance", a != nil && a["attinhcount"] == float64(0) && a["attislocal"] == true},
		}
		for _, property := range checks {
			if !property.safe {
				return fmt.Errorf("Column %s has unpreservable %s: %w", c.Ref.Name, property.name, fail())
			}
		}
	}
	for _, k := range b.Keys {
		if !k.Supported || (k.Kind != "primary" && k.Kind != "unique") {
			return fmt.Errorf("Key %s requires manual reconstruction: %w", k.Name, fail())
		}
	}
	for _, x := range b.Indexes {
		if !x.Supported || !tableeditPlainPGIndex(b, x.Name) {
			return fmt.Errorf("Index %s requires manual reconstruction: %w", x.Name, fail())
		}
	}
	return nil
}
func tableeditPlainPGIndex(b tableedit.Baseline, name string) bool {
	if len(b.Facts.IndexAttributes[name]) > 0 {
		return false
	}
	for _, x := range b.Facts.Table.Indexes.Items {
		if x.Ref.Name == name {
			return tableedit.IndexSupported(x)
		}
	}
	return false
}
func pgRebuildCatalog(ctx context.Context, q structureReader, b tableedit.Baseline, selectedRepairs ...bool) bool {
	allowInternal := len(selectedRepairs) > 0 && selectedRepairs[0]
	var safe bool
	err := q.QueryRow(ctx, `SELECT c.relowner=(SELECT oid FROM pg_catalog.pg_roles WHERE rolname=current_user)
 AND c.relacl IS NULL AND c.reloptions IS NULL AND c.reltablespace=0 AND c.relreplident='d'
 AND c.relam=(SELECT oid FROM pg_catalog.pg_am WHERE amname='heap')
 AND NOT c.relhasrules AND NOT EXISTS(SELECT 1 FROM pg_catalog.pg_trigger WHERE tgrelid=c.oid AND (NOT $4 OR NOT tgisinternal)) AND NOT c.relrowsecurity AND NOT c.relforcerowsecurity
 AND NOT EXISTS(SELECT 1 FROM pg_catalog.pg_event_trigger WHERE evtenabled<>'D')
 AND pg_catalog.obj_description(c.oid,'pg_class') IS NULL
 AND NOT EXISTS(SELECT 1 FROM pg_catalog.pg_seclabel WHERE classoid='pg_catalog.pg_class'::pg_catalog.regclass AND objoid=c.oid)
 AND NOT EXISTS(SELECT 1 FROM pg_catalog.pg_publication_tables WHERE schemaname=$2 AND tablename=$3)
 AND NOT EXISTS(SELECT 1 FROM pg_catalog.pg_depend WHERE classid='pg_catalog.pg_class'::pg_catalog.regclass AND objid=c.oid AND deptype='e')
 AND NOT EXISTS(SELECT 1 FROM pg_catalog.pg_default_acl WHERE defaclrole=c.relowner AND defaclobjtype='r' AND defaclnamespace IN (0,c.relnamespace))
 AND NOT EXISTS(SELECT 1 FROM pg_catalog.pg_depend WHERE refobjid=c.oid AND classid='pg_catalog.pg_class'::pg_catalog.regclass AND deptype IN ('a','i') AND objsubid=0 AND objid IN (SELECT oid FROM pg_catalog.pg_class WHERE relkind='S'))
 FROM pg_catalog.pg_class c WHERE c.oid=$1::pg_catalog.oid`, b.Identity, b.Target.Schema, b.Target.Table, allowInternal).Scan(&safe)
	return err == nil && safe
}
func pgBinaryProjection(b tableedit.Baseline) string {
	out := []string{}
	for _, c := range b.Facts.Table.Columns.Items {
		fn := map[string]string{"int4": "int4send", "int8": "int8send", "bool": "boolsend", "numeric": "numeric_send", "varchar": "varcharsend", "text": "textsend"}[c.Type.Value.Ref.Name]
		if fn == "" {
			return ""
		}
		out = append(out, "pg_catalog."+fn+"("+pgx.Identifier{c.Ref.Name}.Sanitize()+")")
	}
	return strings.Join(out, ",")
}
func (s *Session) applyPGRebuild(ctx context.Context, b tableedit.Baseline, p tableedit.Plan) []tableedit.Execution {
	out := make([]tableedit.Execution, len(p.SQL))
	for i := range out {
		out[i].State = "notStarted"
	}
	fill := func(state, message string) []tableedit.Execution {
		for i := range out {
			out[i] = tableedit.Execution{State: state, Message: message}
		}
		return out
	}
	if ctx.Err() != nil || s.TransactionStatus() != "idle" || len(p.SQL) < 4 || p.Reconstruction == nil || pgRebuildFacts(b) != nil {
		return fill("notStarted", "The exact reconstruction plan is not applicable.")
	}
	tx, err := s.conn.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return fill("notStarted", "Cannot begin the reconstruction transaction.")
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if e := tx.Rollback(cleanup); e != nil && !errors.Is(e, pgx.ErrTxClosed) {
			closeConnection(s.conn)
		}
	}()
	if _, err = tx.Exec(ctx, "SET LOCAL lock_timeout='5s'"); err != nil {
		return fill("notStarted", "Cannot set the reviewed lock wait.")
	}
	target := pgx.Identifier{b.Target.Schema, b.Target.Table}.Sanitize()
	if _, err = tx.Exec(ctx, "LOCK TABLE "+target+" IN ACCESS EXCLUSIVE MODE"); err != nil {
		return fill("notStarted", "Cannot acquire the reconstruction lock.")
	}
	for _, ref := range p.References {
		if !ref.Target.Create {
			if _, err = tx.Exec(ctx, "LOCK TABLE "+pgx.Identifier{ref.Target.Schema, ref.Target.Table}.Sanitize()+" IN ACCESS EXCLUSIVE MODE"); err != nil {
				return fill("notStarted", "Cannot acquire a captured migration reference lock.")
			}
		}
		observed, e := readStructure(ctx, tx, ref.Target)
		if e != nil || observed.Fingerprint != ref.Fingerprint {
			return fill("notStarted", "A captured migration reference changed before reconstruction dispatch.")
		}
	}
	current, err := readStructure(ctx, tx, b.Target)
	if err != nil || current.Fingerprint != b.Fingerprint || !pgRebuildCatalog(ctx, tx, b) {
		return fill("notStarted", "The table or reconstruction prerequisites changed; prepare a new preview.")
	}
	temp := p.Reconstruction.TemporaryTable
	if temp == "" {
		temp = "__dbeer_rebuild_" + b.Fingerprint[:12]
	}
	temporary := pgx.Identifier{b.Target.Schema, temp}.Sanitize()
	fail := func(message string) []tableedit.Execution {
		cleanup, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if e := tx.Rollback(cleanup); e != nil {
			closeConnection(s.conn)
			return fill("unknown", "Reconstruction rollback could not be confirmed. Reconcile explicitly; no replay is authorized.")
		}
		for i := range out {
			if out[i].State == "applied" {
				out[i] = tableedit.Execution{State: "rolledBack", Message: message}
			}
		}
		return out
	}
	for i, sql := range p.SQL {
		if ctx.Err() != nil {
			return fail("Reconstruction was cancelled and rolled back.")
		}
		if _, err = tx.Exec(ctx, sql); err != nil {
			out[i] = tableedit.Execution{State: "rolledBack", Message: "The reconstruction statement failed."}
			return fail("Reconstruction failed and rolled back; no changes were committed.")
		}
		out[i].State = "applied"
		if s.afterStructureStep != nil {
			s.afterStructureStep(i)
		}
		if i == 1 {
			projection := pgBinaryProjection(b)
			if projection == "" {
				return fail("Exact retained values cannot be verified.")
			}
			a := "SELECT " + projection + " FROM " + target
			z := "SELECT " + projection + " FROM " + temporary
			var differs bool
			if err = tx.QueryRow(ctx, "SELECT EXISTS (("+a+" EXCEPT ALL "+z+") UNION ALL ("+z+" EXCEPT ALL "+a+"))").Scan(&differs); err != nil || differs {
				return fail("Binary values or duplicate multiplicity changed; reconstruction was rolled back.")
			}
		}
	}
	fresh, err := readStructure(ctx, tx, b.Target)
	if err != nil || !tableedit.VerifyColumnOrder(b, fresh, p.Reconstruction.ColumnOrder, true) || !pgRebuildAttributes(b, fresh) || !pgRebuildCatalog(ctx, tx, fresh) {
		return fail("Retained structure, attributes or dependencies did not match; reconstruction was rolled back.")
	}
	commit := func() error { return tx.Commit(ctx) }
	if s.structureCommitOverride != nil {
		err = s.structureCommitOverride(commit)
	} else {
		err = commit()
	}
	if err != nil {
		closeConnection(s.conn)
		return fill("unknown", "Reconstruction COMMIT acknowledgement was lost. Reconcile explicitly; no replay is authorized.")
	}
	return out
}
func pgRebuildAttributes(a, b tableedit.Baseline) bool {
	x, z := map[string]map[string]any{}, map[string]map[string]any{}
	for n, v := range a.Attributes {
		x[n] = map[string]any{}
		for k, value := range v {
			if k != "attrelid" && k != "attnum" {
				if k == "attoptions" {
					value = tableedit.SemanticPostgresAttributeOptions(value)
				}
				x[n][k] = value
			}
		}
	}
	for n, v := range b.Attributes {
		z[n] = map[string]any{}
		for k, value := range v {
			if k != "attrelid" && k != "attnum" {
				if k == "attoptions" {
					value = tableedit.SemanticPostgresAttributeOptions(value)
				}
				z[n][k] = value
			}
		}
	}
	return reflect.DeepEqual(x, z)
}
