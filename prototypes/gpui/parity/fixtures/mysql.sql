-- Synthetic fixtures only. Run on an owned disposable MySQL 8.0/8.4 server.
-- CREATE fails on an existing namespace; never replace an unowned database.
CREATE DATABASE dbeer_parity_v1 CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE dbeer_parity_v1;
CREATE TABLE values_grid (
    id bigint PRIMARY KEY AUTO_INCREMENT,
    label varchar(255) DEFAULT 'fixture default',
    exact_value decimal(38,18), payload blob,
    computed_length integer GENERATED ALWAYS AS (CHAR_LENGTH(label)) STORED
) ENGINE=InnoDB;
INSERT INTO values_grid(label,exact_value,payload) VALUES
    (NULL,9007199254740993.123456789,UNHEX('00ff')),
    ('',-0.000000000000000001,UNHEX('')),
    ('NULL',NULL,NULL),
    (CONCAT('é, "😀"',CHAR(13),CHAR(10),'世界'),1,UNHEX('00')),
    (CONCAT(CHAR(92),'N'),2,NULL);
INSERT INTO values_grid(label,exact_value)
    WITH digits AS (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
        UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9)
    SELECT CONCAT('synthetic row ',a.n+10*b.n+100*c.n),a.n+10*b.n+100*c.n
        FROM digits a CROSS JOIN digits b CROSS JOIN digits c;
CREATE TABLE composite_key (a integer,b integer,label text,PRIMARY KEY(a,b)) ENGINE=InnoDB;
INSERT INTO composite_key VALUES (1,1,'one'),(1,2,'two'),(2,1,'three');
CREATE TABLE no_key(label text) ENGINE=InnoDB;
INSERT INTO no_key VALUES ('duplicate'),('duplicate');
CREATE TABLE non_transactional(id integer PRIMARY KEY,label text) ENGINE=MyISAM;
CREATE TABLE children(id integer PRIMARY KEY,parent_id bigint,
    CONSTRAINT fixture_fk FOREIGN KEY(parent_id) REFERENCES values_grid(id)) ENGINE=InnoDB;
CREATE VIEW readonly_view AS SELECT label,exact_value FROM values_grid;
DELIMITER //
CREATE FUNCTION calculate(input_value decimal(38,18),scale_value integer)
RETURNS decimal(38,18) DETERMINISTIC RETURN ROUND(input_value,scale_value)//
CREATE PROCEDURE fixture_procedure()
BEGIN SELECT 'synthetic;literal' AS x; SELECT NULL AS x,UNHEX('00ff') AS bytes; END//
CREATE TRIGGER fixture_trigger BEFORE UPDATE ON values_grid FOR EACH ROW
BEGIN SET NEW.label=NEW.label; END//
DELIMITER ;
-- Use for duplicate-name fidelity and display/export truncation scenarios:
SELECT label AS x,exact_value AS x,payload FROM values_grid ORDER BY id;
-- CALL dbeer_parity_v1.fixture_procedure(); yields ordered result sets.
