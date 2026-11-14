package tableedit

import "context"

type PhysicalInspection struct {
	Version       int              `json:"version"`
	Engine        string           `json:"engine"`
	ServerVersion int              `json:"serverVersion"`
	Objects       []PhysicalObject `json:"objects"`
	Operations    []string         `json:"operations"`
}
type PhysicalInspector interface {
	PhysicalInspect(context.Context, Target) (PhysicalInspection, error)
}
