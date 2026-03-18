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

This quickstart runs in `FAIRVISOR_MODE=reverse_proxy`. Requests to `/v1/*`
are enforced by the TPM policy and forwarded to a local mock LLM backend.
No real API keys are required.

**Allowed request** — should return `200`:

```bash
curl -s -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d @../../fixtures/normal_request.json
```

Expected response body shape matches `../../fixtures/allow_response.json`.

**Over-limit request** — should return `429`:

```bash
curl -s -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d @../../fixtures/over_limit_request.json
```

Expected response body shape: `../../fixtures/reject_tpm_exceeded.json`.
The response will also include:
- `X-Fairvisor-Reason: tpm_exceeded`
- `Retry-After: 60`
- `RateLimit-Limit: 100` (matches the quickstart policy `tokens_per_minute`)
- `RateLimit-Remaining: 0`

## How the policy works

The quickstart policy (`policy.json`) enforces a TPM limit keyed on `ip:address`:

- `tokens_per_minute: 100` — allows roughly 2 small requests per minute
- `tokens_per_day: 1000` — daily cap
- `default_max_completion: 50` — pessimistic reservation per request when `max_tokens` is not set

Sending `over_limit_request.json` (which sets `max_tokens: 200000`) immediately
exceeds the 100-token per-minute budget and triggers a `429`.

## Wrapper mode (real provider routing)

Wrapper mode routes requests to real upstream providers using provider-prefixed paths
and a composite Bearer token. It requires real provider API keys and cannot be
demonstrated with this mock stack.

**Path and auth format:**

```
POST /openai/v1/chat/completions
Authorization: Bearer CLIENT_JWT:UPSTREAM_KEY
```

Where:
- `CLIENT_JWT` — signed JWT identifying the calling client/tenant (used for policy enforcement)
- `UPSTREAM_KEY` — real upstream API key forwarded to the provider (e.g. `sk-...` for OpenAI)

Fairvisor strips the composite header, injects the correct provider auth before forwarding,
and **never returns upstream auth headers to the caller**
(see `../../fixtures/allow_response.json`).

**Provider-prefixed paths:**

| Path prefix | Upstream | Auth header injected |
|---|---|---|
| `/openai/v1/...` | `https://api.openai.com/v1/...` | `Authorization: Bearer UPSTREAM_KEY` |
| `/anthropic/v1/...` | `https://api.anthropic.com/v1/...` | `x-api-key: UPSTREAM_KEY` |
| `/gemini/v1beta/...` | `https://generativelanguage.googleapis.com/v1beta/...` | `x-goog-api-key: UPSTREAM_KEY` |

To run in wrapper mode, change the compose env to `FAIRVISOR_MODE: wrapper` and
supply real credentials in the `Authorization` header.

## Teardown

```bash
docker compose down
```

## Next steps

- See `../recipes/` for team budgets, runaway agent guard, and provider failover scenarios
- See `../../fixtures/` for all sample request/response artifacts
- See [fairvisor/benchmark](https://github.com/fairvisor/benchmark) for performance benchmarks
- See [docs/install/](../../docs/install/) for Kubernetes, VM, and SaaS deployment options
