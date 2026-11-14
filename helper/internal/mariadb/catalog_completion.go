package mariadb

// Each ordered native aggregate preserves catalog ordinality. JSON_QUERY marks
// nested MariaDB text-backed JSON as an array rather than a quoted JSON string.
const mariaDBColumnComparisonSQL = `JSON_OBJECT(
'kind',CASE WHEN c.DATA_TYPE IN ('char','varchar','tinytext','text','mediumtext','longtext') THEN 'text'
 WHEN c.DATA_TYPE IN ('tinyint','smallint','mediumint','int','bigint','decimal','numeric','float','double','bit','binary','varbinary','tinyblob','blob','mediumblob','longblob','date','datetime','timestamp','time','year') THEN 'native' ELSE 'unknown' END,
'baseType',c.DATA_TYPE,'charset',COALESCE(c.CHARACTER_SET_NAME,''),'collationSchema','',
'collationName',COALESCE(c.COLLATION_NAME,''),
'collationIdentity',COALESCE((SELECT CAST(co.ID AS CHAR) FROM information_schema.COLLATIONS co WHERE BINARY co.COLLATION_NAME=BINARY c.COLLATION_NAME),'')
)`

const mariaDBCompletionSQL = `WITH objects AS (
 SELECT TABLE_NAME AS name,IF(TABLE_TYPE='VIEW','view','table') AS kind,TABLE_SCHEMA AS ` + "`schema`" + ` FROM information_schema.TABLES WHERE TABLE_TYPE IN ('BASE TABLE','SYSTEM VERSIONED','VIEW')
 UNION ALL SELECT ROUTINE_NAME,'function',ROUTINE_SCHEMA FROM information_schema.ROUTINES WHERE ROUTINE_TYPE='FUNCTION'
), page AS (
 SELECT * FROM objects WHERE (?<>'' AND BINARY ` + "`schema`" + `=BINARY ?) OR (?='' AND ` + "`schema`" + ` NOT IN ('information_schema','mysql','performance_schema','sys'))
 ORDER BY BINARY ` + "`schema`" + `,BINARY name,kind LIMIT 200 OFFSET ?
)
SELECT name,kind,` + "`schema`" + `,
COALESCE((SELECT JSON_ARRAYAGG(c.COLUMN_NAME ORDER BY c.ORDINAL_POSITION) FROM information_schema.COLUMNS c WHERE BINARY c.TABLE_SCHEMA=BINARY page.` + "`schema`" + ` AND BINARY c.TABLE_NAME=BINARY page.name AND page.kind IN ('table','view')),JSON_ARRAY()) AS columns,
COALESCE((SELECT JSON_ARRAYAGG(JSON_OBJECT('name',fk.CONSTRAINT_NAME,'targetSchema',fk.UNIQUE_CONSTRAINT_SCHEMA,'targetTable',fk.REFERENCED_TABLE_NAME,
 'columns',JSON_QUERY(COALESCE((SELECT JSON_ARRAYAGG(JSON_OBJECT('source',k.COLUMN_NAME,'target',k.REFERENCED_COLUMN_NAME) ORDER BY k.ORDINAL_POSITION)
 FROM information_schema.KEY_COLUMN_USAGE k WHERE BINARY k.CONSTRAINT_SCHEMA=BINARY fk.CONSTRAINT_SCHEMA AND BINARY k.CONSTRAINT_NAME=BINARY fk.CONSTRAINT_NAME AND BINARY k.TABLE_NAME=BINARY fk.TABLE_NAME),JSON_ARRAY()),'$')) ORDER BY BINARY fk.CONSTRAINT_NAME)
 FROM information_schema.REFERENTIAL_CONSTRAINTS fk WHERE BINARY fk.CONSTRAINT_SCHEMA=BINARY page.` + "`schema`" + ` AND BINARY fk.TABLE_NAME=BINARY page.name AND page.kind='table'),JSON_ARRAY()) AS foreignKeys,
COALESCE((SELECT JSON_ARRAYAGG(JSON_OBJECT('returnType',r.DTD_IDENTIFIER,'parameters',JSON_QUERY(COALESCE((SELECT JSON_ARRAYAGG(JSON_OBJECT('name',COALESCE(p.PARAMETER_NAME,''),'type',p.DTD_IDENTIFIER,'position',p.ORDINAL_POSITION) ORDER BY p.ORDINAL_POSITION)
 FROM information_schema.PARAMETERS p WHERE BINARY p.SPECIFIC_SCHEMA=BINARY r.ROUTINE_SCHEMA AND BINARY p.SPECIFIC_NAME=BINARY r.SPECIFIC_NAME AND p.ORDINAL_POSITION>0 AND p.PARAMETER_MODE IN ('IN','INOUT')),JSON_ARRAY()),'$')))
 FROM information_schema.ROUTINES r WHERE page.kind='function' AND BINARY r.ROUTINE_SCHEMA=BINARY page.` + "`schema`" + ` AND BINARY r.ROUTINE_NAME=BINARY page.name AND r.ROUTINE_TYPE='FUNCTION'),JSON_ARRAY()) AS signatures,
COALESCE((SELECT JSON_OBJECTAGG(c.COLUMN_NAME,c.COLUMN_TYPE) FROM information_schema.COLUMNS c WHERE BINARY c.TABLE_SCHEMA=BINARY page.` + "`schema`" + ` AND BINARY c.TABLE_NAME=BINARY page.name AND page.kind IN ('table','view')),JSON_OBJECT()) AS columnTypes,
COALESCE((SELECT JSON_ARRAYAGG(JSON_OBJECT('name',c.COLUMN_NAME,'nativeType',c.COLUMN_TYPE,'comparison',` + mariaDBColumnComparisonSQL + `) ORDER BY c.ORDINAL_POSITION)
 FROM information_schema.COLUMNS c WHERE BINARY c.TABLE_SCHEMA=BINARY page.` + "`schema`" + ` AND BINARY c.TABLE_NAME=BINARY page.name AND page.kind IN ('table','view')),JSON_ARRAY()) AS columnTypeEntries
FROM page ORDER BY BINARY ` + "`schema`" + `,BINARY name,kind`
