package main

import "encoding/json"

// Missing or unsupported options must not trigger a compositor change.
func variableFrameRenderingEnabled(data []byte) bool {
	var option struct {
		Enabled *bool `json:"bool"`
	}
	return json.Unmarshal(data, &option) == nil && option.Enabled != nil && *option.Enabled
}
