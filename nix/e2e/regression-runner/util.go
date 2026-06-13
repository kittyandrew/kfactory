package main

import (
	"encoding/json"
	"errors"
	"time"
)

func retry(timeout, interval time.Duration, fn func() error) error {
	deadline := time.Now().Add(timeout)
	var last error
	for time.Now().Before(deadline) {
		if err := fn(); err != nil {
			last = err
			time.Sleep(interval)
			continue
		}
		return nil
	}
	if last == nil {
		last = errors.New("condition not met")
	}
	return last
}

func jsonArrayContains(raw, value string) bool {
	for _, item := range jsonArray(raw) {
		if item == value {
			return true
		}
	}
	return false
}

func jsonArray(raw string) []string {
	var out []string
	_ = json.Unmarshal([]byte(raw), &out)
	return out
}

func tail(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[len(s)-n:]
}
