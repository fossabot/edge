# Recipe: Runaway Agent Guard

Stop runaway agentic workflows before they exhaust your token budget or
billing limit.

## Problem

Autonomous agents (LangChain, AutoGPT, custom loops) can enter retry storms
or infinite planning loops. Without enforcement, a single runaway agent
can consume thousands of dollars of API budget in minutes.

## How it works

Two rules cooperate:

1. **Loop detector** — counts requests per `agent_id` in a sliding window.
   If the agent fires more than 30 requests in 60 seconds, it trips a
   120-second cooldown. This catches tight retry loops.

2. **TPM guard** — caps tokens per minute per agent. A burst-heavy agent
   that passes the loop check still cannot drain the token pool.

## Deploy

```bash
cp policy.json /etc/fairvisor/policy.json
```

## JWT shape expected

```json
{
  "sub": "user-456",
  "agent_id": "autoagent-prod-7",
  "exp": 9999999999
}
```

## Kill switch for incidents

If an agent causes an incident, flip a kill switch without restarting edge:

```bash
# Via CLI
fairvisor kill-switch enable agent-id=autoagent-prod-7

# Or update the policy bundle with a kill_switch entry and hot-reload
```

See `docs/cookbook/kill-switch-incident-response.md` for the full incident playbook.
