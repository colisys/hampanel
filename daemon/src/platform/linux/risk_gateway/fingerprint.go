package main

// Browser fingerprinting.
//
// Header-derived fingerprints are trivially evaded: a client can rotate its IP
// and send identical headers, so the brute-force guard needs a signal that
// survives an IP pool. We therefore inject a tiny script into HTML responses;
// it hashes stable browser properties into a cookie, which the gateway then
// mixes into the fingerprint. Clients without JS fall back to headers only.

import (
	"bytes"
	"compress/gzip"
	"io"
	"net/http"
	"strconv"
	"strings"
)

const fingerprintCookie = "hm_fp"

// Kept dependency-free and idempotent so it is safe on every response.
const fingerprintScript = `<script>(function(){try{` +
	`var k=[navigator.hardwareConcurrency,navigator.deviceMemory,screen.width+"x"+screen.height,` +
	`screen.colorDepth,Intl.DateTimeFormat().resolvedOptions().timeZone,` +
	`navigator.languages?navigator.languages.join(","):"",` +
	`navigator.platform,!!window.chrome].join("|");` +
	`var h=2166136261;for(var i=0;i<k.length;i++){h^=k.charCodeAt(i);h=(h*16777619)>>>0;}` +
	`var v=("00000000"+h.toString(16)).slice(-8);` +
	`if(document.cookie.indexOf("hm_fp=")<0){` +
	`document.cookie="hm_fp="+v+";path=/;max-age=2592000;samesite=lax";}}catch(e){}})();</script>`

func injectFingerprint(resp *http.Response) error {
	if resp == nil || resp.Body == nil {
		return nil
	}
	contentType := resp.Header.Get("Content-Type")
	if !strings.Contains(contentType, "text/html") {
		return nil
	}
	gzipped := strings.EqualFold(resp.Header.Get("Content-Encoding"), "gzip")
	var reader io.Reader = resp.Body
	if gzipped {
		zr, err := gzip.NewReader(resp.Body)
		if err != nil {
			// Cannot decode: leave the body untouched rather than corrupt it.
			return nil
		}
		defer zr.Close()
		reader = zr
	}
	body, err := io.ReadAll(reader)
	if err != nil {
		return nil
	}
	lower := bytes.ToLower(body)
	idx := bytes.Index(lower, []byte("</head>"))
	if idx < 0 {
		idx = bytes.Index(lower, []byte("<body"))
	}
	if idx < 0 {
		// Not a document we can safely inject into.
		resp.Body = io.NopCloser(bytes.NewReader(body))
		if gzipped {
			resp.Header.Del("Content-Encoding")
			resp.ContentLength = int64(len(body))
		}
		return nil
	}
	var out bytes.Buffer
	out.Write(body[:idx])
	out.WriteString(fingerprintScript)
	out.Write(body[idx:])
	payload := out.Bytes()
	if gzipped {
		var buf bytes.Buffer
		zw := gzip.NewWriter(&buf)
		if _, err := zw.Write(payload); err != nil {
			return nil
		}
		if err := zw.Close(); err != nil {
			return nil
		}
		payload = buf.Bytes()
	}
	resp.Body = io.NopCloser(bytes.NewReader(payload))
	resp.ContentLength = int64(len(payload))
	resp.Header.Set("Content-Length", strconv.Itoa(len(payload)))
	return nil
}

// cookieValue returns the named cookie without pulling in a request parse error
// path: a missing cookie simply means "no JS fingerprint yet".
func cookieValue(r *http.Request, name string) string {
	cookie, err := r.Cookie(name)
	if err != nil {
		return ""
	}
	return cookie.Value
}
