package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/Cthaat/NekoTribe/backend-go/contracts"
)

type schemaColumn struct {
	Name     string  `json:"name"`
	Type     string  `json:"type"`
	Nullable bool    `json:"nullable"`
	Default  *string `json:"default"`
}
type schemaConstraint struct {
	Type              string   `json:"type"`
	Columns           []string `json:"columns"`
	Expression        string   `json:"expression"`
	ReferencedTable   string   `json:"referencedTable"`
	ReferencedColumns []string `json:"referencedColumns"`
	DeleteRule        string   `json:"deleteRule"`
}
type schemaStep struct {
	ID          string             `json:"id"`
	Kind        string             `json:"kind"`
	Name        string             `json:"name"`
	Table       string             `json:"table"`
	Columns     json.RawMessage    `json:"columns"`
	Constraints []schemaConstraint `json:"constraints"`
}
type schemaCatalog struct {
	ID                 string            `json:"id"`
	Revision           int               `json:"revision"`
	Ledger             schemaStep        `json:"ledger"`
	MigrationChecksums map[string]string `json:"migrationChecksums"`
	Feature            struct {
		ID    string       `json:"id"`
		Steps []schemaStep `json:"steps"`
	} `json:"feature"`
}
type schemaRow map[string]any
type schemaQueryer interface {
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
}

func schemaText(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return x
	case []byte:
		return string(x)
	default:
		return fmt.Sprint(x)
	}
}
func schemaInt(v any) (int64, bool) {
	if v == nil {
		return 0, true
	}
	value := strings.TrimSpace(schemaText(v))
	if value == "" {
		return 0, true
	}
	if n, err := strconv.ParseInt(value, 10, 64); err == nil {
		return n, true
	}
	// Oracle NUMBER may be delivered as decimal/exponent text by the driver.
	// Comparisons are only against small integer metadata values; reject NaN,
	// fractions and values outside JavaScript's exact integer range.
	n, err := strconv.ParseFloat(value, 64)
	if err != nil || math.IsInf(n, 0) || math.IsNaN(n) || math.Trunc(n) != n || math.Abs(n) > 9007199254740991 {
		return 0, false
	}
	return int64(n), true
}

// Match Nuxt's expression normalization: SQL syntax is case-insensitive, quoted
// string contents are not. Only simple literal IN lists may be reordered.
func normalizeSchemaExpression(value string) string {
	var b strings.Builder
	quoted := false
	characters := []rune(value)
	for i := 0; i < len(characters); i++ {
		c := characters[i]
		if c == '\'' {
			b.WriteRune(c)
			if quoted && i+1 < len(characters) && characters[i+1] == '\'' {
				b.WriteByte('\'')
				i++
				continue
			}
			quoted = !quoted
			continue
		}
		if !quoted && (c == '"' || jsTrimSpace(c)) {
			continue
		}
		if !quoted {
			b.WriteString(strings.ToUpper(string(c)))
		} else {
			b.WriteRune(c)
		}
	}
	s := b.String()
	for strings.HasPrefix(s, "(") && strings.HasSuffix(s, ")") {
		depth := 0
		inQuote := false
		early := false
		for i := 0; i < len(s)-1; i++ {
			if s[i] == '\'' {
				if inQuote && i+1 < len(s) && s[i+1] == '\'' {
					i++
					continue
				}
				inQuote = !inQuote
			}
			if !inQuote {
				if s[i] == '(' {
					depth++
				}
				if s[i] == ')' {
					depth--
					if depth == 0 {
						early = true
						break
					}
				}
			}
		}
		if early {
			break
		}
		s = s[1 : len(s)-1]
	}
	re := regexp.MustCompile(`^([A-Z][A-Z0-9_]*)IN\((.*)\)$`)
	if m := re.FindStringSubmatch(s); m != nil {
		parts := strings.Split(m[2], ",")
		literal := regexp.MustCompile(`^(?:'(?:[^']|'')*'|-?\d+(?:\.\d+)?)$`)
		valid := true
		for _, p := range parts {
			if !literal.MatchString(p) {
				valid = false
				break
			}
		}
		if valid {
			sort.Strings(parts)
			unique := parts[:0]
			for _, p := range parts {
				if len(unique) == 0 || unique[len(unique)-1] != p {
					unique = append(unique, p)
				}
			}
			s = m[1] + "IN(" + strings.Join(unique, ",") + ")"
		}
	}
	return s
}

func schemaColumnMatches(expected schemaColumn, actual schemaRow) bool {
	nullable := "N"
	if expected.Nullable {
		nullable = "Y"
	}
	if schemaText(actual["NULLABLE"]) != nullable {
		return false
	}
	defaultValue := ""
	if expected.Default != nil {
		defaultValue = *expected.Default
	}
	if normalizeSchemaExpression(schemaText(actual["DATA_DEFAULT"])) != normalizeSchemaExpression(defaultValue) {
		return false
	}
	n := regexp.MustCompile(`^NUMBER(?:\((\d+)(?:,(\d+))?\))?$`).FindStringSubmatch(expected.Type)
	if n != nil {
		if schemaText(actual["DATA_TYPE"]) != "NUMBER" {
			return false
		}
		if n[1] == "" {
			return actual["DATA_PRECISION"] == nil && actual["DATA_SCALE"] == nil
		}
		precision, ok := schemaInt(actual["DATA_PRECISION"])
		if !ok {
			return false
		}
		scale, ok := schemaInt(actual["DATA_SCALE"])
		if !ok {
			return false
		}
		want, _ := strconv.ParseInt(n[1], 10, 64)
		wantScale := int64(0)
		if n[2] != "" {
			wantScale, _ = strconv.ParseInt(n[2], 10, 64)
		}
		return precision == want && scale == wantScale
	}
	v := regexp.MustCompile(`^VARCHAR2\((\d+)\)$`).FindStringSubmatch(expected.Type)
	if v != nil {
		length, ok := schemaInt(actual["CHAR_LENGTH"])
		want, _ := strconv.ParseInt(v[1], 10, 64)
		return ok && schemaText(actual["DATA_TYPE"]) == "VARCHAR2" && length == want
	}
	if expected.Type == "TIMESTAMP" {
		return schemaText(actual["DATA_TYPE"]) == "TIMESTAMP(6)"
	}
	return schemaText(actual["DATA_TYPE"]) == expected.Type
}

func schemaRows(ctx context.Context, q schemaQueryer, query string, args ...any) ([]schemaRow, error) {
	if !strings.HasPrefix(strings.ToUpper(strings.TrimSpace(query)), "SELECT ") {
		return nil, errSessionStore
	}
	rows, err := q.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, errSessionStore
	}
	columns, err := rows.Columns()
	if err != nil {
		_ = rows.Close()
		return nil, errSessionStore
	}
	result := []schemaRow{}
	for rows.Next() {
		values := make([]any, len(columns))
		ptrs := make([]any, len(columns))
		for i := range values {
			ptrs[i] = &values[i]
		}
		if rows.Scan(ptrs...) != nil {
			_ = rows.Close()
			return nil, errSessionStore
		}
		row := schemaRow{}
		for i, c := range columns {
			if bytes, ok := values[i].([]byte); ok {
				row[strings.ToUpper(c)] = string(bytes)
			} else {
				row[strings.ToUpper(c)] = values[i]
			}
		}
		result = append(result, row)
	}
	if rows.Err() != nil {
		_ = rows.Close()
		return nil, errSessionStore
	}
	if rows.Close() != nil {
		return nil, errSessionStore
	}
	return result, nil
}

func sameSchemaStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
func checkSchemaTable(ctx context.Context, q schemaQueryer, step schemaStep) error {
	table, err := schemaRows(ctx, q, `SELECT table_name AS NAME FROM user_tables WHERE table_name = :name`, sql.Named("name", step.Table))
	if err != nil || len(table) == 0 {
		return errSessionStore
	}
	rows, err := schemaRows(ctx, q, `SELECT column_name, data_type, data_precision, data_scale, char_length, nullable, data_default FROM user_tab_columns WHERE table_name = :table_name`, sql.Named("table_name", step.Table))
	if err != nil {
		return errSessionStore
	}
	var expected []schemaColumn
	if json.Unmarshal(step.Columns, &expected) != nil || len(expected) == 0 {
		return errSessionStore
	}
	for _, column := range expected {
		found := false
		for _, row := range rows {
			if schemaText(row["COLUMN_NAME"]) == column.Name {
				found = schemaColumnMatches(column, row)
				break
			}
		}
		if !found {
			return errSessionStore
		}
	}
	constraints, err := schemaRows(ctx, q, `SELECT c.constraint_name, c.constraint_type, c.search_condition_vc, c.delete_rule, c.status, c.validated, r.table_name AS referenced_table, c.r_owner AS referenced_owner FROM user_constraints c LEFT JOIN user_constraints r ON r.constraint_name = c.r_constraint_name AND c.r_owner = USER WHERE c.table_name = :table_name`, sql.Named("table_name", step.Table))
	if err != nil {
		return errSessionStore
	}
	cols, err := schemaRows(ctx, q, `SELECT c.constraint_name, c.column_name, c.position, r.column_name AS referenced_column FROM user_cons_columns c LEFT JOIN user_constraints f ON f.constraint_name = c.constraint_name LEFT JOIN user_cons_columns r ON r.constraint_name = f.r_constraint_name AND r.position = c.position AND f.r_owner = USER WHERE c.table_name = :table_name ORDER BY c.constraint_name, c.position`, sql.Named("table_name", step.Table))
	if err != nil {
		return errSessionStore
	}
	for _, want := range step.Constraints {
		matched := false
		for _, got := range constraints {
			if schemaText(got["CONSTRAINT_TYPE"]) != want.Type || schemaText(got["STATUS"]) != "ENABLED" || schemaText(got["VALIDATED"]) != "VALIDATED" {
				continue
			}
			if want.Type == "C" {
				if normalizeSchemaExpression(schemaText(got["SEARCH_CONDITION_VC"])) == normalizeSchemaExpression(want.Expression) {
					matched = true
					break
				}
				continue
			}
			var own, ref []string
			for _, col := range cols {
				if schemaText(col["CONSTRAINT_NAME"]) == schemaText(got["CONSTRAINT_NAME"]) {
					own = append(own, schemaText(col["COLUMN_NAME"]))
					ref = append(ref, schemaText(col["REFERENCED_COLUMN"]))
				}
			}
			if sameSchemaStrings(own, want.Columns) && (want.Type != "R" || (schemaText(got["REFERENCED_TABLE"]) == want.ReferencedTable && schemaText(got["DELETE_RULE"]) == want.DeleteRule && sameSchemaStrings(ref, want.ReferencedColumns))) {
				matched = true
				break
			}
		}
		if !matched {
			return errSessionStore
		}
	}
	return nil
}

func validateFeatureSchema(ctx context.Context, q schemaQueryer, catalog schemaCatalog, feature string) error {
	valid := feature == "two-factor" && catalog.ID == "AUTH-2FA-SCHEMA-CATALOG" && len(catalog.Feature.Steps) == 9 || feature == "media" && catalog.ID == "MEDIA-SCHEMA-CATALOG" && len(catalog.Feature.Steps) == 1
	if !valid || catalog.Revision != 1 || catalog.Feature.ID != feature || len(catalog.MigrationChecksums) == 0 {
		return errSessionStore
	}
	owner, err := schemaRows(ctx, q, `SELECT USER AS USER_NAME, SYS_CONTEXT('USERENV','CURRENT_SCHEMA') AS SCHEMA_NAME FROM dual`)
	if err != nil || len(owner) == 0 || schemaText(owner[0]["USER_NAME"]) == "" || schemaText(owner[0]["USER_NAME"]) != schemaText(owner[0]["SCHEMA_NAME"]) {
		return errSessionStore
	}
	ledger, err := schemaRows(ctx, q, `SELECT table_name AS NAME FROM user_tables WHERE table_name = :name`, sql.Named("name", catalog.Ledger.Table))
	if err != nil {
		return errSessionStore
	}
	if len(ledger) > 0 {
		if checkSchemaTable(ctx, q, catalog.Ledger) != nil {
			return errSessionStore
		}
		records, err := schemaRows(ctx, q, `SELECT step_id, checksum FROM n_schema_migrations`)
		if err != nil {
			return errSessionStore
		}
		for _, record := range records {
			id := schemaText(record["STEP_ID"])
			if expected, ok := catalog.MigrationChecksums[id]; !ok || expected != schemaText(record["CHECKSUM"]) {
				return errSessionStore
			}
		}
	}
	for _, step := range catalog.Feature.Steps {
		switch step.Kind {
		case "table", "column":
			if checkSchemaTable(ctx, q, step) != nil {
				return errSessionStore
			}
		case "sequence":
			r, err := schemaRows(ctx, q, `SELECT sequence_name, increment_by, cycle_flag FROM user_sequences WHERE sequence_name = :name`, sql.Named("name", step.Name))
			if err != nil || len(r) == 0 {
				return errSessionStore
			}
			n, ok := schemaInt(r[0]["INCREMENT_BY"])
			if !ok || n != 1 || schemaText(r[0]["CYCLE_FLAG"]) != "N" {
				return errSessionStore
			}
		case "index":
			r, err := schemaRows(ctx, q, `SELECT index_name, table_name, uniqueness, status FROM user_indexes WHERE index_name = :name`, sql.Named("name", step.Name))
			if err != nil || len(r) == 0 || schemaText(r[0]["TABLE_NAME"]) != step.Table || schemaText(r[0]["UNIQUENESS"]) != "NONUNIQUE" || schemaText(r[0]["STATUS"]) != "VALID" {
				return errSessionStore
			}
			cols, err := schemaRows(ctx, q, `SELECT column_name, descend FROM user_ind_columns WHERE index_name = :name ORDER BY column_position`, sql.Named("name", step.Name))
			if err != nil {
				return errSessionStore
			}
			var want []string
			if json.Unmarshal(step.Columns, &want) != nil || len(want) != len(cols) {
				return errSessionStore
			}
			for i, c := range cols {
				if schemaText(c["COLUMN_NAME"]) != want[i] || schemaText(c["DESCEND"]) != "ASC" {
					return errSessionStore
				}
			}
		default:
			return errSessionStore
		}
	}
	return nil
}

// Hold the same Oracle session for the owner, ledger and all dictionary reads.
// No ready result is cached; later requests recheck the deployed schema.
func (s OracleSessions) CheckTwoFactorSchema(ctx context.Context) error {
	return s.checkFeatureSchema(ctx, "two-factor", contracts.TwoFactorSchemaCatalog)
}
func (s OracleSessions) CheckMediaSchema(ctx context.Context) error {
	return s.checkFeatureSchema(ctx, "media", contracts.MediaSchemaCatalog)
}
func (s OracleSessions) checkFeatureSchema(ctx context.Context, feature string, data []byte) error {
	var catalog schemaCatalog
	if json.Unmarshal(data, &catalog) != nil {
		return errSessionStore
	}
	connection, err := s.DB.Conn(ctx)
	if err != nil {
		return errSessionStore
	}
	result := validateFeatureSchema(ctx, connection, catalog, feature)
	if connection.Close() != nil {
		return errSessionStore
	}
	return result
}
