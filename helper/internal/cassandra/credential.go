package cassandra

import (
	"context"
	"sync"

	"dbeer/helper/internal/credential"
	"dbeer/helper/internal/protocol"
	gocql "github.com/apache/cassandra-gocql-driver/v2"
)

// AuthProvider is invoked for every driver connection, including control,
// discovered nodes and reconnects. A provider failure latches for this session
// so driver reconnection cannot repeatedly launch a failing local command.
func configureCredentials(ctx context.Context, connection protocol.Connection, config *gocql.ClusterConfig) <-chan error {
	if connection.PasswordCommand == nil {
		return nil
	}
	failures := make(chan error, 1)
	var mu sync.Mutex
	var failed error
	config.Authenticator = nil
	config.AuthProvider = func(_ *gocql.HostInfo) (gocql.Authenticator, error) {
		mu.Lock()
		defer mu.Unlock()
		if failed != nil {
			return nil, failed
		}
		password, err := credential.Password(ctx, connection)
		if err != nil {
			failed = err
			failures <- err
			return nil, err
		}
		return gocql.PasswordAuthenticator{Username: connection.User, Password: password}, nil
	}
	return failures
}
