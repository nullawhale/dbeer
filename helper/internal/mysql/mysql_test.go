package mysql

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math/big"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func TestMySQLTLSModesAndSafeValidation(t *testing.T) {
	settings := protocol.Connection{Engine: "mysql", Host: "localhost", Port: 3306, Database: "db", User: "user", Password: "private-password"}
	for _, mode := range []string{"disable", "require", "verify-ca", "verify-full"} {
		settings.SSLMode = mode
		config, err := tlsConfiguration(settings)
		if err != nil {
			t.Fatalf("supported TLS mode %s rejected", mode)
		}
		if mode == "disable" {
			if config != nil {
				t.Fatal("disable enabled TLS")
			}
			continue
		}
		if config.MinVersion != tls.VersionTLS12 {
			t.Fatal("weak TLS minimum")
		}
		if mode == "verify-full" && config.InsecureSkipVerify {
			t.Fatal("hostname verification disabled")
		}
		if mode == "verify-ca" {
			// Use a deterministic empty trust store rather than macOS trust APIs.
			config.RootCAs = x509.NewCertPool()
			public, private, _ := ed25519.GenerateKey(rand.Reader)
			template := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
			der, _ := x509.CreateCertificate(rand.Reader, template, template, public, private)
			certificate, _ := x509.ParseCertificate(der)
			var invalid x509.UnknownAuthorityError
			err := config.VerifyConnection(tls.ConnectionState{PeerCertificates: []*x509.Certificate{certificate}})
			if err == nil || !errors.As(err, &invalid) {
				t.Fatal("verify-ca did not reject an untrusted certificate")
			}
		}
	}
	for _, mode := range []string{"allow", "prefer", "garbage"} {
		settings.SSLMode = mode
		_, err := Open(context.Background(), settings)
		var failure *adapter.ConnectionError
		if !errors.As(err, &failure) || failure.Category != "validation" || strings.Contains(err.Error(), settings.Password) {
			t.Fatal("unsafe or missing validation")
		}
	}
	settings.SSLMode, settings.SSLRootCert = "verify-full", "/does/not/exist"
	if _, err := tlsConfiguration(settings); err == nil {
		t.Fatal("missing CA accepted")
	}
}

func TestMySQLCollectorPreservesTypedValuesAndBoundedOutput(t *testing.T) {
	command := protocol.Command{RequestID: "r", SessionID: "s", QueryID: "q"}
	collector := newCollector(command)
	result := wire.NewResultReserveResultset(4)
	defer result.Close()
	result.Fields = []*wire.Field{
		{Name: []byte("x"), Type: wire.MYSQL_TYPE_NEWDECIMAL},
		{Name: []byte("x"), Type: wire.MYSQL_TYPE_LONGLONG, Flag: wire.UNSIGNED_FLAG},
		{Name: []byte("x"), Type: wire.MYSQL_TYPE_BLOB, Charset: 63},
		{Name: []byte("x"), Type: wire.MYSQL_TYPE_VARCHAR, Charset: 45},
	}
	_ = collector.columns(result)
	values := []wire.FieldValue{
		wire.NewFieldValue(wire.FieldValueTypeString, 0, []byte("12345678901234567890.12345678901234567890")),
		wire.NewFieldValue(wire.FieldValueTypeUnsigned, ^uint64(0), nil),
		wire.NewFieldValue(wire.FieldValueTypeString, 0, []byte{0, 255, 128}),
		wire.NewFieldValue(wire.FieldValueTypeString, 0, []byte("κόσμος 🍺")),
	}
	_ = collector.row(values)
	values[0] = wire.NewFieldValue(wire.FieldValueTypeNull, 0, nil)
	_ = collector.row(values)
	for range 1100 {
		_ = collector.row(values)
	}
	response := collector.finish(result, time.Millisecond, "transaction")
	if *response.Rows[0][0] != "12345678901234567890.12345678901234567890" || *response.Rows[0][1] != "18446744073709551615" ||
		*response.Rows[0][2] != base64.StdEncoding.EncodeToString([]byte{0, 255, 128}) || *response.Rows[0][3] != "κόσμος 🍺" || response.Rows[1][0] != nil {
		t.Fatal("values changed")
	}
	if response.Columns[2].Encoding != "base64" || response.Columns[0].NativeType != "DECIMAL" || response.Columns[0].Engine != "mysql" {
		t.Fatal("typed metadata missing")
	}
	if len(response.Rows) != MaxResultRows || !response.Truncated || response.RowCount != 1102 {
		t.Fatal("row limit/count incorrect")
	}
	encoded, _ := json.Marshal(response)
	if len(encoded) > MaxResultBytes {
		t.Fatal("result byte limit exceeded")
	}

	collector = newCollector(command)
	_ = collector.columns(result)
	values[0] = wire.NewFieldValue(wire.FieldValueTypeString, 0, []byte(strings.Repeat("\\\"", 1024*1024)))
	for range 5 {
		_ = collector.row(values)
	}
	response = collector.finish(result, 0, "idle")
	encoded, _ = json.Marshal(response)
	if !response.Truncated || len(encoded) > MaxResultBytes {
		t.Fatal("escaped value exceeded byte budget")
	}
}

func TestMySQLConnectionDiagnosticsNeverRetainRawError(t *testing.T) {
	for _, err := range []error{errors.New("password=private host=private"), &wire.MyError{Code: 1045, Message: "private-password"}} {
		if strings.Contains(safeConnectionError(err).Error(), "private") {
			t.Fatal("unsafe connection diagnostic")
		}
	}
}

func TestMySQLOnlyWireInterruptionChangesSQLFailureToCancellation(t *testing.T) {
	session := &Session{}
	session.transaction.Store("transaction")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	command := protocol.Command{RequestID: "r"}
	response := session.queryError(command, ctx, &wire.MyError{Code: 1064, State: "42000", Message: "syntax error"})
	if response.Category != "sql" || response.SQLState != "42000" {
		t.Fatal("a real SQL error was replaced by cancellation")
	}
	response = session.queryError(command, ctx, &wire.MyError{Code: 1317, State: "70100", Message: "interrupted"})
	if response.Category != "cancelled" || response.TransactionStatus != "transaction" {
		t.Fatal("wire interruption did not retain cancellation and transaction state")
	}
}
