# Hampanel risk gateway

A small Go reverse proxy between Caddy+Coraza and the Web engine. It adds:

- TypeSafe TypeSafe `/v1/systemone` `noul` risk judgement on bounded request bodies.
- GeoIP CIDR and GeoSite domain rules from Geo-Aggregator text lists.
- detect / enforce decisions, fail-open/closed TypeSafe failure policy.
- JSONL audit logs.

## Build

```bash
go build -o hampanel-risk main.go
```

Standard library only; no module dependencies.

## Config

```json
{
  "listen": "127.0.0.1:18092",
  "upstream": "http://127.0.0.1:80",
  "mode": "detect",
  "max_body_bytes": 65536,
  "log_path": "/var/lib/hampanel/waf/risk.log",
  "typesafe": {
    "enabled": true,
    "endpoint": "https://api.typesafe.ai/v1/systemone",
    "model": "jev-latest",
    "credential": "/var/lib/hampanel/waf/typesafe.cred",
    "credential_name": "hampanel-typesafe",
    "threshold": 0.85,
    "timeout_ms": 800,
    "fail_open": true,
    "instructions": "Is this HTTP request malicious, an exploit attempt, or abusive automation?",
    "inspect_methods": ["POST", "PUT", "PATCH", "DELETE"]
  },
  "geo": {
    "enabled": true,
    "mode": "enforce",
    "data_dir": "/var/lib/hampanel/waf/geo",
    "geoip": [{"tag": "ru", "action": "deny"}],
    "geosite": [{"tag": "category-ads", "action": "deny"}]
  }
}
```

- `geoip-<tag>.txt` contains CIDRs (Geo-Aggregator `source2/<cc>.txt`).
- `geosite-<tag>.txt` contains domains (Geo-Aggregator `source1/<tag>.txt`); supports
  `full:`, `domain:`, `keyword:` prefixes.
- `typesafe.credential` is a systemd-creds encrypted file. The gateway runs
  `systemd-creds decrypt --name=<name> <file> -` once at startup; the plaintext key
  never appears in config or API responses.
- TypeSafe request uses `{model,state,questions:{malicious:{type:"noul",...}}}` and
  reads `answers.malicious.noul` per the official OpenAPI schema.
- On TypeSafe timeout/error, `fail_open=true` forwards the request; if false and
  mode is enforce, the request is blocked.

## Mock verification

Start an HTTP server for `/v1/systemone` returning `answers.malicious.noul`, point
`typesafe.endpoint` to it, then:

- normal POST → 200
- POST containing an attack marker → 403 in enforce, 200 in detect
- Host matching a denied GeoSite tag → 403
- JSONL log contains decision, probability, rule/reason and duration.

This was verified locally before wiring the gateway into the panel.
