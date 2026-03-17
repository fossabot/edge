# Fairvisor Edge — Quickstart

Go from `git clone` to working policy enforcement in one step.

## Prerequisites

- Docker with Compose V2 (`docker compose version`)
- Port 8080 free on localhost

## Start

```bash
docker compose up -d
```

Wait for the edge service to report healthy:

```bash
docker compose ps
# edge should show "healthy"
```

## Verify enforcement

**Allowed request** — should return `200`:

```bash
curl -s -X POST http://localhost:8080/openai/v1/chat/completions \
  -H "Authorization: Bearer demo-client-jwt.demo-payload.demo-sig:sk-fake-key" \
  -H "Content-Type: application/json" \
  -d @../../fixtures/normal_request.json
```

Expected response matches `../../fixtures/allow_response.json`.

**Over-limit request** — should return `429`:

```bash
curl -s -X POST http://localhost:8080/openai/v1/chat/completions \
  -H "Authorization: Bearer demo-client-jwt.demo-payload.demo-sig:sk-fake-key" \
  -H "Content-Type: application/json" \
  -d @../../fixtures/over_limit_request.json
```

Expected response body matches `../../fixtures/reject_tpm_exceeded.json`.
The response will also include:
- `X-Fairvisor-Reason: tpm_exceeded`
- `Retry-After: 60`
- `RateLimit-Limit: 100`
- `RateLimit-Remaining: 0`

## Wrapper mode and auth

This quickstart runs in `FAIRVISOR_MODE=wrapper`. The composite Bearer token format is:

```
Authorization: Bearer CLIENT_JWT:UPSTREAM_KEY
```

- `CLIENT_JWT` — a signed JWT identifying the calling client/tenant (used for policy enforcement)
- `UPSTREAM_KEY` — the real upstream API key forwarded to the provider (e.g. `sk-...` for OpenAI)

Fairvisor strips the composite header and injects the correct provider auth before forwarding. The upstream key is **never returned to the caller** — see `../../fixtures/allow_response.json` for proof (no `Authorization`, `x-api-key`, or `x-goog-api-key` headers in the response).

## Provider-prefixed paths

Wrapper mode routes by path prefix:

| Path prefix | Upstream | Auth header |
|---|---|---|
| `/openai/v1/...` | `https://api.openai.com/v1/...` | `Authorization: Bearer UPSTREAM_KEY` |
| `/anthropic/v1/...` | `https://api.anthropic.com/v1/...` | `x-api-key: UPSTREAM_KEY` |
| `/gemini/v1beta/...` | `https://generativelanguage.googleapis.com/v1beta/...` | `x-goog-api-key: UPSTREAM_KEY` |

## Anthropic example

```bash
curl -s -X POST http://localhost:8080/anthropic/v1/messages \
  -H "Authorization: Bearer demo-client-jwt.demo-payload.demo-sig:sk-ant-fake-key" \
  -H "Content-Type: application/json" \
  -d @../../fixtures/anthropic_normal_request.json
```

A rejected Anthropic request returns an Anthropic-native error body — see `../../fixtures/reject_anthropic.json`.

## Teardown

```bash
docker compose down
```

## Next steps

- See `../recipes/` for team budgets, runaway agent guard, and provider failover scenarios
- See `../../fixtures/` for all sample request/response artifacts
- See [fairvisor/benchmark](https://github.com/fairvisor/benchmark) for performance benchmarks
- See [docs/install/](../../docs/install/) for Kubernetes, VM, and SaaS deployment options
