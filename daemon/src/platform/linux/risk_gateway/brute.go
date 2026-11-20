package main

// Brute-force containment.
//
// Three cooperating signals decide whether a source is banned:
//
//  1. a per-source failure counter inside a sliding window (repeated 40x/4xx);
//  2. a browser fingerprint bound to the source, so rotating the IP through a
//     pool does not reset the counter;
//  3. collusion: once a fingerprint is banned, every source that presented the
//     same fingerprint is banned too.
//
// The package is intentionally free of HTTP wiring so it can be unit tested.

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"sync"
	"time"
)

type bruteConfig struct {
	Enabled bool `json:"enabled"`
	// Failures inside Window before the source is banned.
	Threshold int `json:"threshold"`
	WindowMS  int `json:"window_ms"`
	// How long a ban lasts.
	BanMS int `json:"ban_ms"`
	// Keep at most this many tracked sources.
	MaxSources int `json:"max_sources"`
}

type failureWindow struct {
	first time.Time
	count int
}

type bruteGuard struct {
	cfg bruteConfig

	mu sync.Mutex
	// source -> failures in the current window
	sources map[string]failureWindow
	// source -> fingerprint observed for that source
	bindings map[string]string
	// fingerprint -> banned until
	fingerprintBans map[string]time.Time
	// source -> banned until
	sourceBans map[string]time.Time
	// fingerprints seen with a source that produced a suspicious request
	now func() time.Time
}

func newBruteGuard(cfg bruteConfig) *bruteGuard {
	if cfg.Threshold <= 0 {
		cfg.Threshold = 5
	}
	if cfg.WindowMS <= 0 {
		cfg.WindowMS = 60_000
	}
	if cfg.BanMS <= 0 {
		cfg.BanMS = 600_000
	}
	if cfg.MaxSources <= 0 {
		cfg.MaxSources = 10_000
	}
	return &bruteGuard{
		cfg:             cfg,
		sources:         make(map[string]failureWindow),
		bindings:        make(map[string]string),
		fingerprintBans: make(map[string]time.Time),
		sourceBans:      make(map[string]time.Time),
		now:             time.Now,
	}
}

// Banned reports whether the source or its fingerprint is currently banned.
func (g *bruteGuard) Banned(source, fingerprint string) bool {
	if !g.cfg.Enabled {
		return false
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	now := g.now()
	if until, ok := g.sourceBans[source]; ok {
		if now.Before(until) {
			return true
		}
		delete(g.sourceBans, source)
	}
	if fingerprint != "" {
		if until, ok := g.fingerprintBans[fingerprint]; ok {
			if now.Before(until) {
				return true
			}
			delete(g.fingerprintBans, fingerprint)
		}
	}
	return false
}

// RecordFailure counts a suspicious request and bans when the threshold is hit.
// It returns true when this call caused a ban.
func (g *bruteGuard) RecordFailure(source, fingerprint string) bool {
	if !g.cfg.Enabled {
		return false
	}
	g.mu.Lock()
	defer g.mu.Unlock()

	now := g.now()
	g.pruneLocked(now)
	if len(g.sources) >= g.cfg.MaxSources {
		// Refuse to grow without bound; drop the oldest window instead of
		// letting an attacker exhaust memory.
		for key := range g.sources {
			delete(g.sources, key)
			break
		}
	}

	if fingerprint != "" {
		g.bindings[source] = fingerprint
	}

	window := g.sources[source]
	if window.count == 0 || now.Sub(window.first) > time.Duration(g.cfg.WindowMS)*time.Millisecond {
		window = failureWindow{first: now, count: 0}
	}
	window.count++
	g.sources[source] = window

	if window.count < g.cfg.Threshold {
		return false
	}

	until := now.Add(time.Duration(g.cfg.BanMS) * time.Millisecond)
	g.sourceBans[source] = until
	delete(g.sources, source)
	if fingerprint != "" {
		g.fingerprintBans[fingerprint] = until
		// Collusion: the fingerprint is shared, so every source that presented
		// it is banned even though none of them reached the threshold alone.
		for other, bound := range g.bindings {
			if bound == fingerprint {
				g.sourceBans[other] = until
			}
		}
	}
	return true
}

// forget drops expired state so long-running gateways do not leak.
func (g *bruteGuard) pruneLocked(now time.Time) {
	for key, until := range g.sourceBans {
		if !now.Before(until) {
			delete(g.sourceBans, key)
		}
	}
	for key, until := range g.fingerprintBans {
		if !now.Before(until) {
			delete(g.fingerprintBans, key)
		}
	}
}

// fingerprintOf derives a stable fingerprint from request headers. It is a
// weak signal by design: it must not depend on anything the client controls
// per request (like a random UA suffix), so it prefers the client hints that
// browsers send consistently.
func fingerprintOf(h map[string]string) string {
	parts := []string{
		strings.TrimSpace(h["Accept-Language"]),
		strings.TrimSpace(h["Sec-Ch-Ua"]),
		strings.TrimSpace(h["Sec-Ch-Ua-Platform"]),
		strings.TrimSpace(h["Sec-Ch-Ua-Mobile"]),
		strings.TrimSpace(h["Cookie"]),
	}
	sum := sha256.Sum256([]byte(strings.Join(parts, "|")))
	return hex.EncodeToString(sum[:12])
}
