package main

import (
	"errors"
	"testing"
)

func TestOmarchyRevisionUsesInstalledPackages(t *testing.T) {
	for _, test := range []struct {
		name     string
		packages map[string]string
		legacy   string
		want     string
	}{
		{"stable replaces stale alpha", map[string]string{"omarchy": "omarchy 4.0.3-1\n"}, "4.0.0.alpha", "4.0.3-1"},
		{"edge has precedence", map[string]string{"omarchy-dev": "omarchy-dev 4.1.0.r42-1\n", "omarchy": "omarchy 4.0.3-1\n"}, "old", "4.1.0.r42-1"},
		{"source installation fallback", nil, "4.0.0.alpha", "4.0.0.alpha"},
		{"missing installation", nil, "", ""},
		{"wrong package is ignored", map[string]string{"omarchy-dev": "other 9.0-1", "omarchy": "omarchy 4.0.3-1"}, "old", "4.0.3-1"},
		{"malformed output is ignored", map[string]string{"omarchy": "omarchy 4.0.3-1 unexpected"}, "old", "old"},
	} {
		t.Run(test.name, func(t *testing.T) {
			got := resolveOmarchyRevision(func(name string) ([]byte, error) {
				value, ok := test.packages[name]
				if !ok {
					return nil, errors.New("package unavailable")
				}
				return []byte(value), nil
			}, func() string { return test.legacy })
			if got != test.want {
				t.Fatalf("got %q, want %q", got, test.want)
			}
		})
	}
}

func TestOmarchyRevisionReflectsAnInGuestUpgrade(t *testing.T) {
	installed := "4.0.3-1"
	query := func(name string) ([]byte, error) {
		if name != "omarchy" {
			return nil, errors.New("not installed")
		}
		return []byte(name + " " + installed), nil
	}
	legacy := func() string { t.Fatal("packaged installation used legacy version"); return "" }
	if got := resolveOmarchyRevision(query, legacy); got != installed {
		t.Fatalf("before upgrade: %q", got)
	}
	installed = "4.0.4-1"
	if got := resolveOmarchyRevision(query, legacy); got != installed {
		t.Fatalf("after upgrade: %q", got)
	}
}
