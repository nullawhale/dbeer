package mysql

import sc "dbeer/helper/internal/schemacompare"

// CatalogTypeShape parses the shared column-type grammar only. Callers retain
// native engine eligibility, catalog completeness and SQL rendering authority.
func CatalogTypeShape(datatype, definition, charset, length, precision, scale, datetimePrecision, srid string) sc.TypeUse {
	return mysqlSchemaType(datatype, definition, charset, length, precision, scale, datetimePrecision, srid)
}

// CatalogRawRows owns a byte-preserving JSON-safe copy of catalog scalars.
func CatalogRawRows(rows [][]*string) [][]*string { return mysqlRawRows(rows) }
