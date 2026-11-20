package main

import (
	"testing"
	"time"
)

func testGuard(threshold int) (*bruteGuard, *time.Time) {
	now := time.Unix(1_700_000_000, 0)
	guard := newBruteGuard(bruteConfig{
		Enabled:   true,
		Threshold: threshold,
		WindowMS:  60_000,
		BanMS:     600_000,
	})
	current := now
	guard.now = func() time.Time { return current }
	return guard, &current
}

func TestBansAfterThreshold(t *testing.T) {
	guard, now := testGuard(3)
	for i := 0; i < 2; i++ {
		if guard.RecordFailure("203.0.113.7", "fp-a") {
			t.Fatalf("banned after %d failures", i+1)
		}
	}
	if !guard.RecordFailure("203.0.113.7", "fp-a") {
		t.Fatal("expected a ban on the third failure")
	}
	if !guard.Banned("203.0.113.7", "") {
		t.Fatal("source should be banned")
	}
	// Ban expires.
	*now = now.Add(601 * time.Second)
	if guard.Banned("203.0.113.7", "") {
		t.Fatal("ban should have expired")
	}
}

func TestWindowResets(t *testing.T) {
	guard, now := testGuard(2)
	guard.RecordFailure("198.51.100.9", "")
	*now = now.Add(2 * time.Minute)
	if guard.RecordFailure("198.51.100.9", "") {
		t.Fatal("a stale window must not count towards the threshold")
	}
}

func TestCollusionBansSharedFingerprint(t *testing.T) {
	guard, _ := testGuard(2)
	// Two sources rotate out of an IP pool but keep the same fingerprint.
	guard.RecordFailure("192.0.2.10", "fp-shared")
	guard.RecordFailure("192.0.2.11", "fp-shared")
	if guard.RecordFailure("192.0.2.12", "fp-shared") {
		t.Fatal("third source alone is under the threshold")
	}
	// The second source reached the threshold, which bans the fingerprint, so
	// the first source is now banned as well.
	guard.RecordFailure("192.0.2.11", "fp-shared")
	if !guard.Banned("192.0.2.10", "") {
		t.Fatal("shared fingerprint must ban colluding sources")
	}
	if !guard.Banned("192.0.2.99", "fp-shared") {
		t.Fatal("a fresh IP reusing the banned fingerprint must be refused")
	}
}

func TestDisabledGuardNeverBans(t *testing.T) {
	guard := newBruteGuard(bruteConfig{Enabled: false, Threshold: 1})
	for i := 0; i < 10; i++ {
		guard.RecordFailure("203.0.113.5", "fp")
	}
	if guard.Banned("203.0.113.5", "fp") {
		t.Fatal("disabled guard must not ban")
	}
}

func TestFingerprintIgnoresUserAgentNoise(t *testing.T) {
	a := fingerprintOf(map[string]string{
		"Accept-Language":    "zh-CN",
		"Sec-Ch-Ua":          "Chromium;v=120",
		"Sec-Ch-Ua-Platform": "Linux",
		"Sec-Ch-Ua-Mobile":   "?0",
		"User-Agent":         "attack-1",
	})
	b := fingerprintOf(map[string]string{
		"Accept-Language":    "zh-CN",
		"Sec-Ch-Ua":          "Chromium;v=120",
		"Sec-Ch-Ua-Platform": "Linux",
		"Sec-Ch-Ua-Mobile":   "?0",
		"User-Agent":         "attack-2",
	})
	if a != b {
		t.Fatal("fingerprint must not depend on a rotating user agent")
	}
	if fingerprintOf(map[string]string{"Sec-Ch-Ua": "Firefox"}) == a {
		t.Fatal("different clients must produce different fingerprints")
	}
}
