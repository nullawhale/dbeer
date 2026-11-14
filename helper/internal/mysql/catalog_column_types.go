package mysql

// Charset and collation identity come from the resolved physical column, not
// its display type or connection defaults.
const catalogColumnComparisonSQL = `JSON_OBJECT(
'kind',CASE WHEN c.DATA_TYPE IN ('char','varchar','tinytext','text','mediumtext','longtext') THEN 'text'
 WHEN c.DATA_TYPE IN ('tinyint','smallint','mediumint','int','bigint','decimal','numeric','float','double','bit','binary','varbinary','tinyblob','blob','mediumblob','longblob','date','datetime','timestamp','time','year') THEN 'native' ELSE 'unknown' END,
'baseType',c.DATA_TYPE,'charset',COALESCE(c.CHARACTER_SET_NAME,''),'collationSchema','',
'collationName',COALESCE(c.COLLATION_NAME,''),
'collationIdentity',COALESCE((SELECT CAST(co.ID AS CHAR) FROM information_schema.COLLATIONS co WHERE BINARY co.COLLATION_NAME=BINARY c.COLLATION_NAME),'')
)`
