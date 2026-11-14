package mariadb

// This is an observation gate for the UI. Apply independently reloads native
// metadata and enforces exact row/period witnesses and operation privileges.
const mariaDBColumnEditabilitySQL = `CASE
WHEN FIND_IN_SET('EMPTY_STRING_IS_NULL',@@SESSION.sql_mode)>0 OR FIND_IN_SET('ORACLE',@@SESSION.sql_mode)>0 THEN 'The current SQL mode cannot preserve exact empty prepared values or parameter syntax; change it explicitly before editing.'
WHEN NOT EXISTS(SELECT 1 FROM information_schema.TABLES t WHERE BINARY t.TABLE_SCHEMA=BINARY c.TABLE_SCHEMA AND BINARY t.TABLE_NAME=BINARY c.TABLE_NAME AND t.ENGINE='InnoDB' AND t.TABLE_TYPE IN ('BASE TABLE','SYSTEM VERSIONED')) THEN 'Atomic row changes require a native InnoDB base table; views and nontransactional engines are read-only in this workflow.'
WHEN NOT EXISTS(SELECT 1 FROM information_schema.KEY_COLUMN_USAGE pk WHERE BINARY pk.TABLE_SCHEMA=BINARY c.TABLE_SCHEMA AND BINARY pk.TABLE_NAME=BINARY c.TABLE_NAME AND pk.CONSTRAINT_NAME='PRIMARY') THEN 'A complete native primary key is required for row editing.'
WHEN EXISTS(SELECT 1 FROM information_schema.COLUMNS other WHERE BINARY other.TABLE_SCHEMA=BINARY c.TABLE_SCHEMA AND BINARY other.TABLE_NAME=BINARY c.TABLE_NAME AND (FIND_IN_SET('select',other.PRIVILEGES)=0 OR other.DATA_TYPE NOT IN ('tinyint','smallint','mediumint','int','bigint','decimal','numeric','float','double','bit','char','varchar','tinytext','text','mediumtext','longtext','binary','varbinary','tinyblob','blob','mediumblob','longblob','date','datetime','timestamp','time','year','enum','set','uuid','inet4','inet6','geometry','point','linestring','polygon','multipoint','multilinestring','multipolygon','geometrycollection'))) THEN 'Every original column must have complete readable native value support before row changes.'
WHEN COALESCE(c.GENERATION_EXPRESSION,'')<>'' OR c.EXTRA LIKE '%GENERATED%' THEN 'Generated and system-period columns are maintained by the server and remain read-only.'
WHEN FIND_IN_SET('update',c.PRIVILEGES)=0 AND FIND_IN_SET('insert',c.PRIVILEGES)=0 THEN 'The required native column write privilege is unavailable.'
ELSE '' END`
