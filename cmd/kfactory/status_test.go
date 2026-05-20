package main

import (
	"testing"
	"time"
)

func TestTruncDur(t *testing.T) {
	cases := []struct {
		in   time.Duration
		want string
	}{
		{45 * time.Second, "45s"},
		{2*time.Minute + 17*time.Second, "2m17s"},
		{11*time.Hour + 53*time.Minute + 42*time.Second, "11h53m0s"},
	}
	for _, tc := range cases {
		got := truncDur(tc.in)
		if got != tc.want {
			t.Errorf("truncDur(%v)=%q want %q", tc.in, got, tc.want)
		}
	}
}

func TestPlural(t *testing.T) {
	if plural(1) != "" {
		t.Errorf("plural(1) should be empty")
	}
	if plural(0) != "s" {
		t.Errorf("plural(0) should be s")
	}
	if plural(5) != "s" {
		t.Errorf("plural(5) should be s")
	}
}
