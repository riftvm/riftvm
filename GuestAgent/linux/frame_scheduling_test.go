package main

import "testing"

func TestVariableFrameRenderingEnabled(t *testing.T) {
	for _, tc := range []struct {
		input string
		want  bool
	}{
		{`{"bool":true}`, true}, {`{"bool":false}`, false},
		{`{}`, false}, {`{"bool":null}`, false}, {`{"bool":"true"}`, false}, {`unavailable`, false},
	} {
		if got := variableFrameRenderingEnabled([]byte(tc.input)); got != tc.want {
			t.Errorf("%s: got %v", tc.input, got)
		}
	}
}
