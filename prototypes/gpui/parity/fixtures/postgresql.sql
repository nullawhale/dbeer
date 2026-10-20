-- Synthetic fixtures only. Run on an owned disposable PostgreSQL 16/17/18 server.
-- CREATE fails on an existing namespace; never replace an unowned database.
CREATE SCHEMA dbeer_parity_v1;
CREATE TABLE dbeer_parity_v1.values_grid (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    label text DEFAULT 'fixture default',
    exact_value numeric(38,18),
    payload bytea,
    computed_length integer GENERATED ALWAYS AS (length(label)) STORED
);
INSERT INTO dbeer_parity_v1.values_grid(label, exact_value, payload) VALUES
    (NULL, 9007199254740993.123456789, decode('00ff','hex')),
    ('', -0.000000000000000001, decode('','hex')),
    ('NULL', NULL, NULL),
    (E'e\u0301, "😀"\r\n世界', 1.0, decode('00','hex')),
    (E'\\N', 2, NULL);
INSERT INTO dbeer_parity_v1.values_grid(label, exact_value)
    SELECT 'synthetic row ' || n, n FROM generate_series(1,1200) AS n;
CREATE TABLE dbeer_parity_v1.composite_key (
    a integer, b integer, label text, PRIMARY KEY(a,b)
);
INSERT INTO dbeer_parity_v1.composite_key VALUES (1,1,'one'), (1,2,'two'), (2,1,'three');
CREATE TABLE dbeer_parity_v1.no_key (label text);
INSERT INTO dbeer_parity_v1.no_key VALUES ('duplicate'), ('duplicate');
CREATE TABLE dbeer_parity_v1.children (
    id integer PRIMARY KEY, parent_id bigint REFERENCES dbeer_parity_v1.values_grid(id)
);
CREATE VIEW dbeer_parity_v1.readonly_view AS SELECT label, exact_value FROM dbeer_parity_v1.values_grid;
CREATE FUNCTION dbeer_parity_v1.calculate(value numeric, scale integer DEFAULT 2)
RETURNS numeric LANGUAGE SQL IMMUTABLE AS $$ SELECT round(value,scale); $$;
CREATE FUNCTION dbeer_parity_v1.calculate(value integer)
RETURNS integer LANGUAGE SQL IMMUTABLE AS $$ SELECT value; $$;
CREATE FUNCTION dbeer_parity_v1.join_values(VARIADIC values_array text[])
RETURNS text LANGUAGE SQL IMMUTABLE AS $$ SELECT array_to_string(values_array, ','); $$;
CREATE FUNCTION dbeer_parity_v1.keep_label() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RETURN NEW; END; $$;
CREATE TRIGGER fixture_trigger BEFORE UPDATE ON dbeer_parity_v1.values_grid
    FOR EACH ROW EXECUTE FUNCTION dbeer_parity_v1.keep_label();
CREATE PROCEDURE dbeer_parity_v1.fixture_procedure() LANGUAGE plpgsql AS $$
BEGIN PERFORM 'synthetic;literal'; END; $$;
-- Use as a read-only execution/result/export scenario after setup:
SELECT label AS x, exact_value AS x, payload FROM dbeer_parity_v1.values_grid ORDER BY id;
