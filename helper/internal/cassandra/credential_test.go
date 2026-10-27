package cassandra

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"dbeer/helper/internal/protocol"
	gocql "github.com/apache/cassandra-gocql-driver/v2"
)

func TestCredentialsRefreshEveryDriverConnectionAndLatchFailures(t *testing.T) {
	path := filepath.Join(t.TempDir(), "token")
	connection := protocol.Connection{User: "reader", PasswordCommand: &protocol.PasswordCommand{Executable: "/bin/cat", Arguments: []string{path}}}
	config := gocql.NewCluster("synthetic.example")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	configureCredentials(ctx, connection, config)
	for _, value := range []string{"first", "second"} {
		if err := os.WriteFile(path, []byte(value), 0600); err != nil {
			t.Fatal(err)
		}
		auth, err := config.AuthProvider(nil)
		if err != nil || auth.(gocql.PasswordAuthenticator).Password != value {
			t.Fatal("driver connection reused a stale credential")
		}
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if _, err := config.AuthProvider(nil); err == nil {
		t.Fatal("provider failure was ignored")
	}
	os.WriteFile(path, []byte("third"), 0600)
	if _, err := config.AuthProvider(nil); err == nil {
		t.Fatal("driver retried a failed provider")
	}
	configureCredentials(ctx, connection, config)
	if _, err := config.AuthProvider(nil); err != nil {
		t.Fatal("new session cannot retry explicitly")
	}
	cancel()
	if _, err := config.AuthProvider(nil); err == nil {
		t.Fatal("closed session still launches providers")
	}
}
