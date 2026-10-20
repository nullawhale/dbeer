-- ADDITIVE SOURCE ONLY. Never sent by a request or provisioned by this recipe.
-- Integrator: use only the exact already-owned PostgreSQL container receipt.
-- Existing namespace/table collisions must fail, never DROP/replace/adopt.
CREATE TABLE dbeer_parity_v1.acceptance_effects (
    case_id text PRIMARY KEY,
    commits integer NOT NULL DEFAULT 0 CHECK (commits >= 0)
);
INSERT INTO dbeer_parity_v1.acceptance_effects(case_id) VALUES
    ('sql-commit'), ('apply-commit'), ('full-export');
CREATE TABLE dbeer_parity_v1.acceptance_receipts (
    case_id text NOT NULL, statement_ordinal integer NOT NULL,
    marker integer NOT NULL, PRIMARY KEY(case_id, statement_ordinal)
);
INSERT INTO dbeer_parity_v1.acceptance_receipts VALUES
    ('script-first-error',0,0), ('script-middle-error',0,0);
CREATE TABLE dbeer_parity_v1.acceptance_apply (
    id integer PRIMARY KEY, label text DEFAULT 'fixture default',
    exact_value numeric(38,18), payload bytea,
    computed_length integer GENERATED ALWAYS AS (length(label)) STORED
);
INSERT INTO dbeer_parity_v1.acceptance_apply(id,label,exact_value,payload) VALUES
    (1,'before',1,decode('00ff','hex')), (2,'second',2,NULL);
CREATE FUNCTION dbeer_parity_v1.acceptance_record_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE dbeer_parity_v1.acceptance_effects
       SET commits=commits+1 WHERE case_id='apply-commit';
    RETURN NEW;
END; $$;
CREATE TRIGGER acceptance_record_apply AFTER UPDATE ON dbeer_parity_v1.acceptance_apply
FOR EACH ROW EXECUTE FUNCTION dbeer_parity_v1.acceptance_record_apply();
CREATE FUNCTION dbeer_parity_v1.acceptance_export_once()
RETURNS TABLE(sort_key numeric,label text,exact_value numeric,payload bytea)
LANGUAGE plpgsql VOLATILE AS $$
BEGIN
    UPDATE dbeer_parity_v1.acceptance_effects
       SET commits=commits+1 WHERE case_id='full-export';
    RETURN QUERY SELECT CASE WHEN v.id<=5 THEN v.id::numeric ELSE v.exact_value+6 END,
        v.label,v.exact_value,v.payload FROM dbeer_parity_v1.values_grid v;
END; $$;
