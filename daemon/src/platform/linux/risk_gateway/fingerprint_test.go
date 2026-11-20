package main

import (
	"bytes"
	"compress/gzip"
	"io"
	"net/http"
	"strings"
	"testing"
)

func htmlResponse(body string, encoding string) *http.Response {
	resp := &http.Response{
		Header: http.Header{"Content-Type": []string{"text/html; charset=utf-8"}},
		Body:   io.NopCloser(strings.NewReader(body)),
	}
	if encoding == "gzip" {
		var buf bytes.Buffer
		zw := gzip.NewWriter(&buf)
		_, _ = zw.Write([]byte(body))
		_ = zw.Close()
		resp.Body = io.NopCloser(bytes.NewReader(buf.Bytes()))
		resp.Header.Set("Content-Encoding", "gzip")
	}
	return resp
}

func readAll(t *testing.T, resp *http.Response) string {
	if strings.EqualFold(resp.Header.Get("Content-Encoding"), "gzip") {
		zr, err := gzip.NewReader(resp.Body)
		if err != nil {
			t.Fatalf("gzip reader: %v", err)
		}
		defer zr.Close()
		out, err := io.ReadAll(zr)
		if err != nil {
			t.Fatalf("read gzip: %v", err)
		}
		return string(out)
	}
	out, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	return string(out)
}

func TestInjectFingerprintIntoHead(t *testing.T) {
	resp := htmlResponse("<html><head><title>x</title></head><body>hi</body></html>", "")
	if err := injectFingerprint(resp); err != nil {
		t.Fatalf("inject: %v", err)
	}
	body := readAll(t, resp)
	if !strings.Contains(body, "hm_fp=") {
		t.Fatalf("script missing: %s", body)
	}
	if strings.Index(body, "hm_fp=") > strings.Index(body, "</head>") {
		t.Fatalf("script injected after head: %s", body)
	}
}

func TestInjectFingerprintKeepsGzip(t *testing.T) {
	resp := htmlResponse("<html><head></head><body>hi</body></html>", "gzip")
	if err := injectFingerprint(resp); err != nil {
		t.Fatalf("inject: %v", err)
	}
	if resp.Header.Get("Content-Encoding") != "gzip" {
		t.Fatalf("encoding dropped: %q", resp.Header.Get("Content-Encoding"))
	}
	if !strings.Contains(readAll(t, resp), "hm_fp=") {
		t.Fatal("script missing after gzip round trip")
	}
}

func TestInjectFingerprintSkipsNonHtml(t *testing.T) {
	resp := &http.Response{
		Header: http.Header{"Content-Type": []string{"application/json"}},
		Body:   io.NopCloser(strings.NewReader(`{"ok":true}`)),
	}
	if err := injectFingerprint(resp); err != nil {
		t.Fatalf("inject: %v", err)
	}
	if strings.Contains(readAll(t, resp), "hm_fp=") {
		t.Fatal("injected into non-HTML response")
	}
}

func TestFingerprintUsesCookie(t *testing.T) {
	headers := map[string]string{"Accept-Language": "en", "Sec-Ch-Ua": "ua"}
	plain := fingerprintOf(headers)
	withCookie := fingerprintOf(map[string]string{
		"Accept-Language": "en", "Sec-Ch-Ua": "ua", "Cookie": "deadbeef",
	})
	if plain == withCookie {
		t.Fatal("fingerprint ignores the JS cookie")
	}
	// Rotating the IP must not change the fingerprint.
	if fingerprintOf(headers) != plain {
		t.Fatal("fingerprint is not stable")
	}
}
