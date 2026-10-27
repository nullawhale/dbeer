package protocol

import (
	"encoding/json"
	"testing"
)

func TestMongoDBConnectionProtocolAndCrossEngineValidation(t *testing.T) {
	c := Connection{Engine: "mongodb", Host: "localhost", Port: 27017, SSLMode: "verify-full", MongoDB: &MongoDBSettings{AuthSource: "admin", AuthMechanism: "SCRAM-SHA-256", ReplicaSet: "rs0"}}
	encoded, _ := json.Marshal(Command{Type: "connect", RequestID: "mongo", Connection: &c})
	parsed, err := ParseCommand(encoded)
	if err != nil || parsed.Connection.MongoDB == nil || parsed.Connection.MongoDB.ReplicaSet != "rs0" {
		t.Fatal("MongoDB connection protocol failed")
	}
	for _, host := range []string{"mongodb://secret@host", "a,b", "host:27017", "host/path", "host\n"} {
		bad := c
		bad.Host = host
		if bad.Valid() {
			t.Fatal("MongoDB host accepted URI/options injection")
		}
	}
	c.Engine = "mysql"
	if c.Valid() {
		t.Fatal("MongoDB metadata accepted on relational profile")
	}
	c.Engine = "mongodb"
	c.MongoDB.AuthMechanism = "MONGODB-AWS"
	if c.Valid() {
		t.Fatal("unsupported authentication mechanism accepted")
	}
}
