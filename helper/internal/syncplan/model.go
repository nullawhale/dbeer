// Package syncplan describes bounded, reviewable SQL drafts. It never executes SQL.
package syncplan

import (
	"encoding/json"
	"errors"
	"strings"
	"unicode/utf8"
)

const Capability = "synchronizationPlanV1"
const MaxSteps = 2000
const MaxBytes = 4 << 20

var ErrInvalid = errors.New("invalid synchronization plan")
var ErrLimit = errors.New("synchronization plan limit")

type Step struct {
	ID          string   `json:"id"`
	Title       string   `json:"title"`
	SQL         string   `json:"sql"`
	Destructive bool     `json:"destructive"`
	Manual      bool     `json:"manual"`
	Reason      string   `json:"reason"`
	DependsOn   []string `json:"dependsOn"`
	Selected    bool     `json:"selected"`
}

type Plan struct {
	FormatVersion int      `json:"formatVersion"`
	Kind          string   `json:"kind"`
	Engine        string   `json:"engine"`
	ModelDigest   string   `json:"modelDigest"`
	Warnings      []string `json:"warnings"`
	Steps         []Step   `json:"steps"`
}

func New(kind, engine, digest string) Plan {
	return Plan{FormatVersion: 1, Kind: kind, Engine: engine, ModelDigest: digest,
		Warnings: []string{"Direction: source → target. Review the selected operations before execution.",
			"Captures are historical. Concurrent changes may invalidate this plan.",
			"Execution may finish only partially. DDL does not have a portable global rollback."}, Steps: []Step{}}
}

func DigestValid(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, r := range s {
		if !(r >= '0' && r <= '9' || r >= 'a' && r <= 'f') {
			return false
		}
	}
	return true
}

func (p Plan) Validate() error {
	if p.FormatVersion != 1 || (p.Kind != "schema" && p.Kind != "data") ||
		(p.Engine != "postgresql" && p.Engine != "mysql") || !DigestValid(p.ModelDigest) ||
		p.Steps == nil || p.Warnings == nil || len(p.Steps) > MaxSteps || len(p.Warnings) > 64 {
		return ErrInvalid
	}
	textOK := func(s string, max int) bool {
		return len(s) <= max && utf8.ValidString(s) && !strings.ContainsRune(s, 0)
	}
	for _, s := range p.Warnings {
		if !textOK(s, 4096) {
			return ErrInvalid
		}
	}
	seen := map[string]Step{}
	for _, s := range p.Steps {
		_, duplicate := seen[s.ID]
		if !textOK(s.ID, 128) || s.ID == "" || duplicate || !textOK(s.Title, 4096) ||
			!textOK(s.SQL, MaxBytes) || !textOK(s.Reason, 4096) || s.DependsOn == nil ||
			(s.Manual && (s.SQL != "" || s.Selected || s.Reason == "")) || (!s.Manual && strings.TrimSpace(s.SQL) == "") ||
			(s.Destructive && s.Selected) {
			return ErrInvalid
		}
		deps := map[string]bool{}
		for _, id := range s.DependsOn {
			dep, ok := seen[id]
			if !ok || deps[id] || (!s.Manual && dep.Manual) || (s.Selected && !dep.Selected) {
				return ErrInvalid
			}
			deps[id] = true
		}
		seen[s.ID] = s
	}
	data, err := json.Marshal(p)
	if err != nil {
		return ErrInvalid
	}
	if len(data) > MaxBytes {
		return ErrLimit
	}
	return nil
}
