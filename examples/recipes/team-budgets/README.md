# Recipe: Team Budgets

Enforce per-team token and cost limits using JWT claims.

## How it works

Each request carries a JWT with a `team_id` claim. Fairvisor uses this as
the bucket key for two independent rules:

1. **TPM/TPD limit** — token-rate enforcement per minute and per day
2. **Monthly cost budget** — cumulative cost cap with staged warn/throttle/reject

## Deploy

```bash
# Copy policy to your edge config path
cp policy.json /etc/fairvisor/policy.json

# Or use with docker compose (standalone mode):
FAIRVISOR_CONFIG_FILE=./policy.json FAIRVISOR_MODE=wrapper docker compose up -d
```

## JWT shape expected

```json
{
  "sub": "user-123",
  "team_id": "engineering",
  "plan": "pro",
  "exp": 9999999999
}
```

## Staged actions at cost budget thresholds

| Threshold | Action |
|---|---|
| 80% | Warn (allow, log, emit business event) |
| 95% | Throttle (allow with 500 ms delay) |
| 100% | Reject (429, `budget_exceeded`) |

## Related fixtures

- `../../../fixtures/reject_tpd_exceeded.json` — TPD reject body
- `../../../fixtures/reject_tpm_exceeded.json` — TPM reject body
