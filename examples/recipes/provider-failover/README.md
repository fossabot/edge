# Recipe: Provider Failover / Edge Control

Run two provider paths under independent policy budgets. When the primary
provider (OpenAI) trips a circuit breaker, your client-side router can
switch to the fallback (Anthropic) — both paths enforced by the same edge.

## How it works

- `/openai/v1/...` — enforced by an OpenAI TPM limit + a spend-based circuit breaker
- `/anthropic/v1/...` — enforced by an Anthropic TPM limit

The circuit breaker on the OpenAI path auto-trips when cumulative spend
exceeds the threshold in a 5-minute window, then auto-resets after 10 minutes.
Your application can detect the 429 with `X-Fairvisor-Reason: circuit_breaker_open`
and switch to the Anthropic path without any Fairvisor configuration change.

## Deploy

```bash
cp policy.json /etc/fairvisor/policy.json
```

## Client-side failover pattern

```python
import httpx

EDGE = "http://localhost:8080"
AUTH = "Bearer my-client-jwt.payload.sig:sk-my-upstream-key"

def chat(messages, provider="openai"):
    resp = httpx.post(
        f"{EDGE}/{provider}/v1/chat/completions",
        headers={"Authorization": AUTH, "Content-Type": "application/json"},
        json={"model": "gpt-4o", "messages": messages},
    )
    if resp.status_code == 429:
        reason = resp.headers.get("X-Fairvisor-Reason", "")
        if reason == "circuit_breaker_open" and provider == "openai":
            return chat(messages, provider="anthropic")
    resp.raise_for_status()
    return resp.json()
```

## Auth note

The composite `CLIENT_JWT:UPSTREAM_KEY` format is the same for all providers.
Fairvisor injects the correct provider-native auth header:
- OpenAI: `Authorization: Bearer UPSTREAM_KEY`
- Anthropic: `x-api-key: UPSTREAM_KEY`

The upstream key is stripped from responses — it never reaches your client.
