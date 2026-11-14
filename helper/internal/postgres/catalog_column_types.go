package postgres

// Only built-in equality types are classified. Domains and user types retain
// their actual base identity without authorizing an inferred comparison.
const catalogColumnComparisonSQL = `json_build_object(
'kind',CASE WHEN a.atttypid IN (25,1042,1043) THEN 'text'
 WHEN a.atttypid IN (16,17,20,21,23,26,700,701,1700,1082,1083,1114,1184,1186,1266,2950) THEN 'native' ELSE 'unknown' END,
'baseType',(SELECT ns.nspname::text||'.'||t.typname::text FROM pg_catalog.pg_type t JOIN pg_catalog.pg_namespace ns ON ns.oid=t.typnamespace WHERE t.oid=` + browseBaseOIDSQL + `),
'charset',CASE WHEN a.atttypid IN (25,1042,1043) THEN 'UTF8' ELSE '' END,
'collationSchema',COALESCE((SELECT n.nspname::text FROM pg_catalog.pg_collation co JOIN pg_catalog.pg_namespace n ON n.oid=co.collnamespace WHERE co.oid=a.attcollation),''),
'collationName',COALESCE((SELECT co.collname::text FROM pg_catalog.pg_collation co WHERE co.oid=a.attcollation),''),
'collationIdentity',CASE WHEN a.attcollation=0 THEN '' ELSE a.attcollation::text END)`
