package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type GeoRule struct {
	Tag    string `json:"tag"`
	Action string `json:"action"`
}

type TypeSafeConfig struct {
	Enabled        bool     `json:"enabled"`
	Endpoint       string   `json:"endpoint"`
	Model          string   `json:"model"`
	Credential     string   `json:"credential"`
	CredentialName string   `json:"credential_name"`
	Threshold      float64  `json:"threshold"`
	TimeoutMS      int      `json:"timeout_ms"`
	FailOpen       bool     `json:"fail_open"`
	Instructions   string   `json:"instructions"`
	InspectMethods []string `json:"inspect_methods"`
}

type GeoConfig struct {
	Enabled bool      `json:"enabled"`
	Mode    string    `json:"mode"`
	DataDir string    `json:"data_dir"`
	GeoIP   []GeoRule `json:"geoip"`
	GeoSite []GeoRule `json:"geosite"`
}

type Route struct {
	Name     string   `json:"name"`
	Hosts    []string `json:"hosts"`
	Upstream string   `json:"upstream"`
	Mode     string   `json:"mode"`
}

type Config struct {
	Listen   string         `json:"listen"`
	Upstream string         `json:"upstream"`
	Mode     string         `json:"mode"`
	MaxBody  int64          `json:"max_body_bytes"`
	LogPath  string         `json:"log_path"`
	TypeSafe TypeSafeConfig `json:"typesafe"`
	Geo      GeoConfig      `json:"geo"`
	Routes   []Route        `json:"routes"`
	Brute    bruteConfig    `json:"brute"`
}

type domainSet struct {
	full     map[string]bool
	suffix   []string
	keywords []string
}

type geoRuleSet struct {
	action  string
	tag     string
	kind    string
	ips     []*net.IPNet
	domains domainSet
}

type routeProxy struct {
	hosts []string
	proxy *httputil.ReverseProxy
	mode  string
	name  string
}

type gateway struct {
	cfg     Config
	brute   *bruteGuard
	proxy   *httputil.ReverseProxy
	routes  []routeProxy
	geoSets []geoRuleSet
	apiKey  string
	logMu   sync.Mutex
	logFile *os.File
}

func main() {
	configPath := flag.String("config", "", "path to risk gateway JSON config")
	flag.Parse()
	if *configPath == "" {
		log.Fatal("missing -config")
	}
	raw, err := os.ReadFile(*configPath)
	if err != nil {
		log.Fatalf("read config: %v", err)
	}
	var cfg Config
	if err := json.Unmarshal(raw, &cfg); err != nil {
		log.Fatalf("parse config: %v", err)
	}
	if cfg.Listen == "" {
		cfg.Listen = "127.0.0.1:18092"
	}
	if cfg.MaxBody <= 0 {
		cfg.MaxBody = 64 * 1024
	}
	if cfg.TypeSafe.Threshold <= 0 || cfg.TypeSafe.Threshold > 1 {
		cfg.TypeSafe.Threshold = 0.85
	}
	if cfg.TypeSafe.TimeoutMS <= 0 {
		cfg.TypeSafe.TimeoutMS = 800
	}
	if cfg.TypeSafe.Endpoint == "" {
		cfg.TypeSafe.Endpoint = "https://api.typesafe.ai/v1/systemone"
	}
	if cfg.TypeSafe.Model == "" {
		cfg.TypeSafe.Model = "jev-latest"
	}
	if cfg.TypeSafe.Instructions == "" {
		cfg.TypeSafe.Instructions = "Is this HTTP request malicious, an exploit attempt, or abusive automation?"
	}
	upstream, err := url.Parse(cfg.Upstream)
	if err != nil || upstream.Scheme == "" || upstream.Host == "" {
		log.Fatalf("invalid upstream %q", cfg.Upstream)
	}

	g := &gateway{cfg: cfg, brute: newBruteGuard(cfg.Brute)}
	if cfg.TypeSafe.Enabled && cfg.TypeSafe.Credential != "" {
		g.apiKey, err = decryptCredential(cfg.TypeSafe.Credential, cfg.TypeSafe.CredentialName)
		if err != nil {
			log.Printf("TypeSafe credential decrypt failed (continuing without key): %v", err)
			g.apiKey = ""
		}
	}
	if cfg.Geo.Enabled {
		g.geoSets = loadGeo(cfg.Geo)
	}
	if cfg.LogPath != "" {
		if err := os.MkdirAll(filepath.Dir(cfg.LogPath), 0o755); err == nil {
			if f, err := os.OpenFile(cfg.LogPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600); err == nil {
				g.logFile = f
				defer f.Close()
			}
		}
	}

	g.proxy = makeProxy(upstream)
	for _, route := range cfg.Routes {
		routeURL, err := url.Parse(route.Upstream)
		if err != nil || routeURL.Scheme == "" || routeURL.Host == "" {
			log.Printf("skip invalid route %s upstream %q", route.Name, route.Upstream)
			continue
		}
		mode := route.Mode
		if mode == "" {
			mode = cfg.Mode
		}
		g.routes = append(g.routes, routeProxy{
			hosts: route.Hosts,
			proxy: makeProxy(routeURL),
			mode:  mode,
			name:  route.Name,
		})
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/", g.handle)
	server := &http.Server{
		Addr:              cfg.Listen,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("risk gateway listening on %s -> %s (mode=%s, typesafe=%v, geo=%v)", cfg.Listen, cfg.Upstream, cfg.Mode, cfg.TypeSafe.Enabled, cfg.Geo.Enabled)
	if err := server.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

func decryptCredential(path, name string) (string, error) {
	args := []string{"decrypt"}
	if name != "" {
		args = append(args, "--name="+name)
	}
	args = append(args, path, "-")
	ctx, cancel := context.WithTimeout(context.Background(), 1200*time.Millisecond)
	defer cancel()
	out, err := exec.CommandContext(ctx, "systemd-creds", args...).Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func makeProxy(upstream *url.URL) *httputil.ReverseProxy {
	proxy := httputil.NewSingleHostReverseProxy(upstream)
	original := proxy.Director
	proxy.Director = func(req *http.Request) {
		host := req.Host
		original(req)
		req.Host = host
	}
	proxy.ModifyResponse = injectFingerprint
	return proxy
}

func matchHost(pattern, host string) bool {
	pattern = strings.ToLower(strings.TrimSpace(pattern))
	host = strings.ToLower(strings.TrimSpace(host))
	if pattern == host {
		return true
	}
	if strings.HasPrefix(pattern, "*.") {
		suffix := pattern[1:]
		return strings.HasSuffix(host, suffix) && len(host) > len(suffix)
	}
	return false
}

func (g *gateway) routeFor(host string) (*httputil.ReverseProxy, string, string) {
	for _, route := range g.routes {
		for _, pattern := range route.hosts {
			if matchHost(pattern, host) {
				return route.proxy, route.mode, route.name
			}
		}
	}
	return g.proxy, g.cfg.Mode, "default"
}

func (g *gateway) handle(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	clientIP := clientIP(r)
	host := stripPort(r.Host)
	proxy, mode, _ := g.routeFor(host)
	if mode == "off" {
		proxy.ServeHTTP(w, r)
		return
	}

	geoDecision, geoRule := g.matchGeo(clientIP, host)
	if geoDecision == "deny" {
		g.audit(r, clientIP, host, "block", "geo:"+geoRule, 0, start)
		writeBlocked(w, "geo:"+geoRule)
		return
	}
	if r.Method == http.MethodGet && r.Header.Get("Upgrade") == "websocket" {
		proxy.ServeHTTP(w, r)
		return
	}

	fingerprint := fingerprintOf(map[string]string{
		"Accept-Language":    r.Header.Get("Accept-Language"),
		"Sec-Ch-Ua":          r.Header.Get("Sec-Ch-Ua"),
		"Sec-Ch-Ua-Platform": r.Header.Get("Sec-Ch-Ua-Platform"),
		"Sec-Ch-Ua-Mobile":   r.Header.Get("Sec-Ch-Ua-Mobile"),
		"Cookie":             cookieValue(r, fingerprintCookie),
	})
	if g.brute.Banned(clientIP, fingerprint) {
		g.audit(r, clientIP, host, "block", "brute:banned", 0, start)
		writeBlocked(w, "brute:banned")
		return
	}

	body, truncated := readBody(r, g.cfg.MaxBody)
	inspect := g.shouldInspect(r)
	prob := 0.0
	reason := ""
	decision := "allow"
	if geoDecision == "allow" {
		reason = "geo-allow:" + geoRule
	} else if inspect && g.cfg.TypeSafe.Enabled {
		p, err := g.checkTypeSafe(r.Context(), r, body, truncated)
		if err != nil {
			if !g.cfg.TypeSafe.FailOpen && mode == "enforce" {
				decision = "block"
				reason = "typesafe-error"
			} else {
				reason = "typesafe-error-open"
			}
		} else {
			prob = p
			if p >= g.cfg.TypeSafe.Threshold {
				reason = fmt.Sprintf("typesafe:%.4f", p)
				if mode == "enforce" {
					decision = "block"
				} else {
					decision = "detect"
				}
			}
		}
	}

	if decision == "block" {
		if g.brute.RecordFailure(clientIP, fingerprint) {
			g.audit(r, clientIP, host, "ban", "brute:threshold", prob, start)
		}
		g.audit(r, clientIP, host, "block", reason, prob, start)
		writeBlocked(w, reason)
		return
	}
	if decision == "detect" {
		g.audit(r, clientIP, host, "detect", reason, prob, start)
	}
	proxy.ServeHTTP(w, r)
}

func writeBlocked(w http.ResponseWriter, reason string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusForbidden)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"error":  "blocked by Hampanel WAF risk gateway",
		"reason": reason,
	})
}

func (g *gateway) shouldInspect(r *http.Request) bool {
	if len(g.cfg.TypeSafe.InspectMethods) == 0 {
		return true
	}
	for _, method := range g.cfg.TypeSafe.InspectMethods {
		if strings.EqualFold(method, r.Method) {
			return true
		}
	}
	return false
}

func readBody(r *http.Request, limit int64) (string, bool) {
	if r.Body == nil {
		return "", false
	}
	original := r.Body
	buffer, _ := io.ReadAll(io.LimitReader(original, limit+1))
	r.Body = io.NopCloser(io.MultiReader(bytes.NewReader(buffer), original))
	truncated := int64(len(buffer)) > limit
	if truncated {
		buffer = buffer[:limit]
	}
	return string(buffer), truncated
}

func (g *gateway) checkTypeSafe(ctx context.Context, r *http.Request, body string, truncated bool) (float64, error) {
	state := map[string]any{
		"method":       r.Method,
		"host":         stripPort(r.Host),
		"path":         r.URL.Path,
		"query":        r.URL.RawQuery,
		"remote_ip":    clientIP(r),
		"content_type": r.Header.Get("Content-Type"),
		"user_agent":   r.Header.Get("User-Agent"),
		"body":         body,
		"truncated":    truncated,
	}
	payload := map[string]any{
		"model": g.cfg.TypeSafe.Model,
		"state": state,
		"questions": map[string]any{
			"malicious": map[string]any{
				"type":         "noul",
				"instructions": g.cfg.TypeSafe.Instructions,
			},
		},
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return 0, err
	}
	timeout := time.Duration(g.cfg.TypeSafe.TimeoutMS) * time.Millisecond
	reqCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(reqCtx, http.MethodPost, g.cfg.TypeSafe.Endpoint, bytes.NewReader(encoded))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	if g.apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+g.apiKey)
	}
	client := &http.Client{Timeout: timeout}
	resp, err := client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return 0, fmt.Errorf("typesafe status %d: %s", resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	var parsed struct {
		Answers map[string]struct {
			Type string  `json:"type"`
			Noul float64 `json:"noul"`
		} `json:"answers"`
	}
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return 0, err
	}
	answer, ok := parsed.Answers["malicious"]
	if !ok {
		return 0, fmt.Errorf("missing malicious answer")
	}
	return answer.Noul, nil
}

func (g *gateway) matchGeo(ipText, host string) (string, string) {
	ip := net.ParseIP(ipText)
	allowTag := ""
	for _, set := range g.geoSets {
		matched := false
		if set.kind == "geoip" && ip != nil {
			for _, network := range set.ips {
				if network.Contains(ip) {
					matched = true
					break
				}
			}
		} else if set.kind == "geosite" {
			matched = matchDomain(set.domains, host)
		}
		if !matched {
			continue
		}
		if set.action == "deny" {
			return "deny", set.tag
		}
		if allowTag == "" {
			allowTag = set.tag
		}
	}
	if allowTag != "" {
		return "allow", allowTag
	}
	return "", ""
}

func matchDomain(set domainSet, host string) bool {
	if host == "" {
		return false
	}
	if set.full[host] {
		return true
	}
	for _, suffix := range set.suffix {
		if host == suffix || strings.HasSuffix(host, "."+suffix) {
			return true
		}
	}
	for _, keyword := range set.keywords {
		if strings.Contains(host, keyword) {
			return true
		}
	}
	return false
}

func loadGeo(cfg GeoConfig) []geoRuleSet {
	var out []geoRuleSet
	for _, rule := range cfg.GeoIP {
		set := geoRuleSet{action: rule.Action, tag: rule.Tag, kind: "geoip"}
		path := filepath.Join(cfg.DataDir, "geoip-"+safeTag(rule.Tag)+".txt")
		if data, err := os.ReadFile(path); err == nil {
			for _, line := range strings.Split(string(data), "\n") {
				line = strings.TrimSpace(line)
				if line == "" || strings.HasPrefix(line, "#") {
					continue
				}
				if !strings.Contains(line, "/") {
					if strings.Contains(line, ":") {
						line += "/128"
					} else {
						line += "/32"
					}
				}
				if _, network, err := net.ParseCIDR(line); err == nil {
					set.ips = append(set.ips, network)
				}
			}
			out = append(out, set)
		}
	}
	for _, rule := range cfg.GeoSite {
		set := geoRuleSet{action: rule.Action, tag: rule.Tag, kind: "geosite"}
		set.domains.full = map[string]bool{}
		path := filepath.Join(cfg.DataDir, "geosite-"+safeTag(rule.Tag)+".txt")
		if data, err := os.ReadFile(path); err == nil {
			for _, line := range strings.Split(string(data), "\n") {
				line = strings.TrimSpace(line)
				if line == "" || strings.HasPrefix(line, "#") {
					continue
				}
				switch {
				case strings.HasPrefix(line, "full:"):
					set.domains.full[strings.TrimPrefix(line, "full:")] = true
				case strings.HasPrefix(line, "domain:"):
					set.domains.suffix = append(set.domains.suffix, strings.TrimPrefix(line, "domain:"))
				case strings.HasPrefix(line, "keyword:"):
					set.domains.keywords = append(set.domains.keywords, strings.TrimPrefix(line, "keyword:"))
				default:
					set.domains.suffix = append(set.domains.suffix, line)
				}
			}
			out = append(out, set)
		}
	}
	return out
}

func safeTag(tag string) string {
	var b strings.Builder
	for _, r := range tag {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' || r == '_' || r == '.' {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func (g *gateway) audit(r *http.Request, clientIP, host, decision, reason string, probability float64, start time.Time) {
	entry := map[string]any{
		"ts":          time.Now().UTC().Format(time.RFC3339Nano),
		"client_ip":   clientIP,
		"host":        host,
		"method":      r.Method,
		"path":        r.URL.Path,
		"decision":    decision,
		"reason":      reason,
		"probability": probability,
		"duration_ms": time.Since(start).Milliseconds(),
	}
	line, _ := json.Marshal(entry)
	if g.logFile != nil {
		g.logMu.Lock()
		_, _ = g.logFile.Write(append(line, '\n'))
		g.logMu.Unlock()
	}
	log.Print(string(line))
}

func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		parts := strings.Split(xff, ",")
		if ip := strings.TrimSpace(parts[0]); ip != "" {
			return ip
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		return host
	}
	return r.RemoteAddr
}

func stripPort(host string) string {
	if h, _, err := net.SplitHostPort(host); err == nil {
		return h
	}
	return host
}
