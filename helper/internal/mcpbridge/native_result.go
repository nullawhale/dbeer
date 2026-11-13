package mcpbridge

import (
	"bytes"
	"encoding/json"
	"errors"

	"dbeer/helper/internal/jsoncheck"
	"dbeer/helper/internal/nativevalue"
)

// Native rows remain paired with their display projection, including an explicit empty matrix.
func (result *Result) UnmarshalJSON(data []byte) error {
	if len(data) > MaxResponseBytes || !jsoncheck.UnicodeValid(data) || !jsoncheck.UniqueObjectKeys(data) {
		return errTransport
	}
	type wire Result
	var value wire
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(data, &fields) != nil {
		return errTransport
	}
	for _, key := range []string{"nativeValues", "sqliteValues"} {
		if raw, present := fields[key]; present && bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
			return errTransport
		}
	}
	if value.NativeValues != nil {
		if !nativevalue.NativeMatrixValid(*value.NativeValues, len(value.Rows), len(value.Columns)) {
			return errors.New("Invalid native result dimensions or limits.")
		}
		for _, row := range value.Rows {
			if len(row) != len(value.Columns) {
				return errTransport
			}
		}
	}
	if value.SQLiteValues != nil {
		if len(*value.SQLiteValues) != len(value.Rows) {
			return errTransport
		}
		for i, row := range *value.SQLiteValues {
			if len(row) != len(value.Columns) {
				return errTransport
			}
			for j, cell := range row {
				if !cell.Valid() || value.NativeValues != nil && !nativevalue.MatchesSQLite((*value.NativeValues)[i][j], cell) {
					return errTransport
				}
			}
		}
	}
	if value.NativeValues != nil && value.SQLiteValues == nil {
		for _, row := range *value.NativeValues {
			for _, cell := range row {
				if cell.Engine == "sqlite" {
					return errTransport
				}
			}
		}
	}
	*result = Result(value)
	return nil
}
