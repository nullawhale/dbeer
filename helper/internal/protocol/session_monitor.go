package protocol

import (
	"encoding/json"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

const SessionMonitorCapability = "sessionMonitorV1"
const MaxMonitoredSessions = 500
const MaxMonitorWaits = 2000
const MaxMonitorQueryBytes = 4096
const MaxMonitorFieldBytes = 1024
const MaxMonitorNotices = 16
const MaxSessionMonitorBytes = 4 * 1024 * 1024

// time.Parse accepts several non-RFC3339 forms, including comma fractions and
// out-of-range numeric zone offsets. Keep the native/helper boundary strict.
var monitorTimestamp = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])$`)

// SessionMonitorSnapshot is a bounded, transient observation. Missing sessions
// never imply that a blocking backend has exited or is safe to terminate.
type SessionMonitorSnapshot struct {
	Engine              string             `json:"engine"`
	CollectionStartedAt string             `json:"collectionStartedAt"`
	CollectedAt         string             `json:"collectedAt"`
	Sessions            []MonitoredSession `json:"sessions"`
	Waits               []MonitorWait      `json:"waits"`
	SessionsComplete    bool               `json:"sessionsComplete"`
	WaitsComplete       bool               `json:"waitsComplete"`
	Notices             []string           `json:"notices"`
}

type MonitoredSession struct {
	ID               string  `json:"id"`
	User             *string `json:"user,omitempty"`
	Database         *string `json:"database,omitempty"`
	Client           *string `json:"client,omitempty"`
	Application      *string `json:"application,omitempty"`
	State            *string `json:"state,omitempty"`
	Query            *string `json:"query,omitempty"`
	QueryAgeMs       *string `json:"queryAgeMs,omitempty"`
	TransactionAgeMs *string `json:"transactionAgeMs,omitempty"`
	WaitType         *string `json:"waitType,omitempty"`
	WaitEvent        *string `json:"waitEvent,omitempty"`
	IsMonitor        bool    `json:"isMonitor"`
	QueryTruncated   bool    `json:"queryTruncated"`
}

type MonitorWait struct {
	WaitingID  string  `json:"waitingId"`
	BlockingID string  `json:"blockingId"`
	Kind       string  `json:"kind"`
	Object     *string `json:"object,omitempty"`
	LockMode   *string `json:"lockMode,omitempty"`
}

func ValidMonitorDecimal(value string) bool {
	if len(value) == 0 || len(value) > 20 || len(value) > 1 && value[0] == '0' {
		return false
	}
	for _, digit := range value {
		if digit < '0' || digit > '9' {
			return false
		}
	}
	return true
}

func validMonitorText(value *string, limit int) bool {
	return value == nil || len(*value) <= limit && utf8.ValidString(*value) && !strings.ContainsRune(*value, 0)
}

func (snapshot SessionMonitorSnapshot) Valid() bool {
	if snapshot.Engine != "postgresql" && snapshot.Engine != "mysql" ||
		snapshot.Sessions == nil || snapshot.Waits == nil || snapshot.Notices == nil ||
		len(snapshot.Sessions) > MaxMonitoredSessions || len(snapshot.Waits) > MaxMonitorWaits || len(snapshot.Notices) > MaxMonitorNotices ||
		(!snapshot.SessionsComplete || !snapshot.WaitsComplete) && len(snapshot.Notices) == 0 ||
		len(snapshot.CollectionStartedAt) > 40 || len(snapshot.CollectedAt) > 40 ||
		!monitorTimestamp.MatchString(snapshot.CollectionStartedAt) || !monitorTimestamp.MatchString(snapshot.CollectedAt) {
		return false
	}
	started, err := time.Parse(time.RFC3339Nano, snapshot.CollectionStartedAt)
	if err != nil {
		return false
	}
	finished, err := time.Parse(time.RFC3339Nano, snapshot.CollectedAt)
	if err != nil || finished.Before(started) {
		return false
	}
	seen := make(map[string]bool, len(snapshot.Sessions))
	for _, session := range snapshot.Sessions {
		if !ValidMonitorDecimal(session.ID) || seen[session.ID] || !validMonitorText(session.Query, MaxMonitorQueryBytes) ||
			session.QueryTruncated && session.Query == nil {
			return false
		}
		seen[session.ID] = true
		for _, value := range []*string{session.User, session.Database, session.Client, session.Application, session.State, session.WaitType, session.WaitEvent} {
			if !validMonitorText(value, MaxMonitorFieldBytes) {
				return false
			}
		}
		for _, age := range []*string{session.QueryAgeMs, session.TransactionAgeMs} {
			if age != nil && !ValidMonitorDecimal(*age) {
				return false
			}
		}
	}
	type edgeKey struct {
		waiting, blocking, kind, object, mode string
		hasObject, hasMode                    bool
	}
	edges := make(map[edgeKey]bool, len(snapshot.Waits))
	for _, wait := range snapshot.Waits {
		if !ValidMonitorDecimal(wait.WaitingID) || !ValidMonitorDecimal(wait.BlockingID) ||
			wait.Kind != "lock" && wait.Kind != "data" && wait.Kind != "metadata" ||
			!validMonitorText(wait.Object, MaxMonitorFieldBytes) || !validMonitorText(wait.LockMode, MaxMonitorFieldBytes) {
			return false
		}
		key := edgeKey{waiting: wait.WaitingID, blocking: wait.BlockingID, kind: wait.Kind, hasObject: wait.Object != nil, hasMode: wait.LockMode != nil}
		if wait.Object != nil {
			key.object = *wait.Object
		}
		if wait.LockMode != nil {
			key.mode = *wait.LockMode
		}
		if edges[key] {
			return false
		}
		edges[key] = true
	}
	for _, notice := range snapshot.Notices {
		if len(notice) == 0 || len(notice) > MaxMonitorFieldBytes || !utf8.ValidString(notice) || strings.ContainsRune(notice, 0) {
			return false
		}
	}
	encoded, err := json.Marshal(snapshot)
	return err == nil && len(encoded) <= MaxSessionMonitorBytes
}
