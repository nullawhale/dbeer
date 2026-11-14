package mariadb

import (
	"errors"
	"strconv"
	"strings"

	"dbeer/helper/internal/tableedit"
)

type mariaDBStructureContext struct {
	Native                                  []string
	ServerVersion                           int
	SQLMode, SchemaCharset, SchemaCollation string
}

// Called only under the owning session worker. Every retained scalar owns its
// bytes; observing native context does not change session settings or roles.
func (s *Session) mariaDBStructureContext(target tableedit.Target) (mariaDBStructureContext, error) {
	var context mariaDBStructureContext
	if !target.Valid() || s.TransactionStatus() != "idle" {
		return context, tableedit.ErrUnsupported
	}
	if err := s.requireNativeMetadataEncoding(); err != nil {
		return context, err
	}
	version, vendor, identity := s.nativeServerObservation()
	if identity == "" || !supportedNativeVersion(version, vendor) {
		return context, tableedit.ErrUnsupported
	}
	parts := strings.Split(strings.Split(version, "-")[0], ".")
	if len(parts) != 3 {
		return context, tableedit.ErrUnsupported
	}
	numbers := make([]int, 3)
	for i, part := range parts {
		n, err := strconv.Atoi(part)
		if err != nil || n < 0 || n > 999 {
			return context, tableedit.ErrUnsupported
		}
		numbers[i] = n
	}
	context.ServerVersion = numbers[0]*10000 + numbers[1]*100 + numbers[2]
	context.Native = []string{version, vendor, identity}
	result, err := s.work.client.Execute(`SELECT @@SESSION.sql_mode,@@lower_case_table_names,@@character_set_client,@@character_set_connection,@@character_set_results,@@collation_connection,COALESCE(DATABASE(),''),CURRENT_USER(),COALESCE(CURRENT_ROLE(),''),@@SESSION.time_zone,@@SESSION.explicit_defaults_for_timestamp,@@SESSION.sql_quote_show_create,@@SESSION.old_mode`)
	if err != nil {
		return context, err
	}
	if result.RowNumber() != 1 || result.ColumnNumber() != 13 {
		result.Close()
		return context, tableedit.ErrUnsupported
	}
	for i := 0; i < 13; i++ {
		value, err := result.GetString(0, i)
		if err != nil || len(value) > 65536 {
			result.Close()
			return context, tableedit.ErrUnsupported
		}
		context.Native = append(context.Native, strings.Clone(value))
	}
	result.Close()
	context.SQLMode = context.Native[3]
	caseMode, err := strconv.Atoi(context.Native[4])
	if err != nil || caseMode < 0 || caseMode > 2 {
		return context, tableedit.ErrUnsupported
	}
	if context.Native[5] != "utf8mb4" || context.Native[6] != "utf8mb4" || context.Native[7] != "utf8mb4" {
		return context, tableedit.ErrUnsupported
	}
	if context.Native[14] != "1" {
		return context, errors.New("MariaDB structure observation requires the already active sql_quote_show_create setting; no setting is changed implicitly.")
	}
	schema, err := s.work.client.Execute(`SELECT SCHEMA_NAME,DEFAULT_CHARACTER_SET_NAME,DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE BINARY SCHEMA_NAME=BINARY ? LIMIT 2`, target.Schema)
	if err != nil {
		return context, err
	}
	defer schema.Close()
	if schema.RowNumber() != 1 {
		return context, tableedit.ErrUnsupported
	}
	for i := 0; i < 3; i++ {
		value, err := schema.GetString(0, i)
		if err != nil || value == "" || len(value) > 65536 {
			return context, tableedit.ErrUnsupported
		}
		context.Native = append(context.Native, strings.Clone(value))
	}
	if context.Native[16] != target.Schema {
		return context, tableedit.ErrUnsupported
	}
	context.SchemaCharset, context.SchemaCollation = context.Native[17], context.Native[18]
	controls, err := s.work.client.Execute("SELECT @@SESSION.autocommit,@@SESSION.foreign_key_checks,@@SESSION.system_versioning_alter_history,@@SESSION.innodb_strict_mode")
	if err != nil {
		return context, err
	}
	if controls.RowNumber() != 1 || controls.ColumnNumber() != 4 {
		controls.Close()
		return context, tableedit.ErrUnsupported
	}
	for i := 0; i < 4; i++ {
		value, e := controls.GetString(0, i)
		if e != nil {
			controls.Close()
			return context, tableedit.ErrUnsupported
		}
		context.Native = append(context.Native, strings.Clone(value))
	}
	controls.Close()
	if context.Native[19] != "1" {
		return context, errors.New("This native DDL workflow requires an already autocommitting dedicated session; no existing SQL-tab transaction is borrowed or changed.")
	}
	return context, nil
}
