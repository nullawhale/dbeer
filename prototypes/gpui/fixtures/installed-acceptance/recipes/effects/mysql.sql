-- ADDITIVE SOURCE ONLY. Never sent by a request or provisioned by this recipe.
-- Integrator: exact owned MySQL receipt and root stdin setup path only.
-- Objects stay in the reserved corpus covered by existing synthetic grants.
CREATE TABLE dbeer_parity_v1.acceptance_effects (
    case_id varchar(64) PRIMARY KEY,
    commits integer NOT NULL DEFAULT 0 CHECK (commits >= 0)
) ENGINE=InnoDB;
INSERT INTO dbeer_parity_v1.acceptance_effects(case_id) VALUES
    ('sql-commit'), ('apply-commit'), ('full-export');
CREATE TABLE dbeer_parity_v1.acceptance_receipts (
    case_id varchar(64) NOT NULL, statement_ordinal integer NOT NULL,
    marker integer NOT NULL, PRIMARY KEY(case_id,statement_ordinal)
) ENGINE=InnoDB;
INSERT INTO dbeer_parity_v1.acceptance_receipts VALUES
    ('script-first-error',0,0), ('script-middle-error',0,0);
CREATE TABLE dbeer_parity_v1.acceptance_apply (
    id integer PRIMARY KEY, label varchar(255) DEFAULT 'fixture default',
    exact_value decimal(38,18), payload blob,
    computed_length integer GENERATED ALWAYS AS (CHAR_LENGTH(label)) STORED
) ENGINE=InnoDB;
INSERT INTO dbeer_parity_v1.acceptance_apply(id,label,exact_value,payload) VALUES
    (1,'before',1,UNHEX('00ff')), (2,'second',2,NULL);
DELIMITER //
CREATE TRIGGER dbeer_parity_v1.acceptance_record_apply
AFTER UPDATE ON dbeer_parity_v1.acceptance_apply FOR EACH ROW
BEGIN
    UPDATE dbeer_parity_v1.acceptance_effects
       SET commits=commits+1 WHERE case_id='apply-commit';
END//
CREATE PROCEDURE dbeer_parity_v1.acceptance_export_once() MODIFIES SQL DATA
BEGIN
    UPDATE dbeer_parity_v1.acceptance_effects
       SET commits=commits+1 WHERE case_id='full-export';
    SELECT label AS x,exact_value AS x,payload FROM dbeer_parity_v1.values_grid
      ORDER BY CASE WHEN id<=5 THEN id ELSE exact_value+6 END;
END//
DELIMITER ;
