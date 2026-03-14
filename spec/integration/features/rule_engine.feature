Feature: Rule engine golden integration behavior
  Rule: Golden scenarios RE-007 to RE-009
    Scenario: RE-007 shadow mode returns allow with would_reject
      Given the rule engine integration harness is reset
      And fixture RE-007 shadow policy would reject
      When I run rule engine evaluation
      Then integration decision is allow shadow would_reject true

    Scenario: RE-008 all must pass rejects on second policy
      Given the rule engine integration harness is reset
      And fixture RE-008 two policies second rejects
      When I run rule engine evaluation
      Then integration decision is reject from policy "p2"

    Scenario: RE-009 missing limit key is fail-open
      Given the rule engine integration harness is reset
      And fixture RE-009 missing limit key fail-open
      When I run rule engine evaluation
      Then integration decision is allow all rules passed
      And missing descriptor log was emitted

  Rule: Pipeline order
    Scenario: kill-switch runs before route evaluation
      Given the rule engine integration harness is reset
      And fixture kill switch takes precedence
      When I run rule engine evaluation
      Then kill switch short-circuited route evaluation

    Scenario: loop detection returns before circuit breaker and limit checks
      Given the rule engine integration harness is reset
      And fixture loop check happens before circuit and rules
      When I run rule engine evaluation
      Then loop short-circuited circuit and limiter checks

  Rule: Full chain with real modules
    Scenario: load real policy JSON then evaluate until reject after burst
      Given the full chain integration is reset with real bundle_loader and token_bucket
      And a real bundle with token_bucket burst 2 is loaded and applied
      And request context is path /v1/chat with jwt org_id org-1 and plan pro
      When I evaluate the request 3 times
      Then the first two evaluations are allow and the third is reject

    Scenario: kill switch in bundle causes matching request to reject
      Given the full chain integration is reset with real bundle_loader and token_bucket
      And a real bundle with kill_switch matching org-1 is loaded and applied
      And request context is path /v1/chat with jwt org_id org-1
      When I run rule engine evaluation
      Then integration decision is reject with reason kill_switch

    Scenario: kill switch extracts scope from request context without precomputed descriptors
      Given the full chain integration is reset with real bundle_loader and token_bucket
      And a real bundle with kill_switch matching org-1 is loaded and applied
      And request context is path /v1/chat with jwt org_id org-1 and no precomputed descriptors
      When I run rule engine evaluation
      Then integration decision is reject with reason kill_switch

  Rule: Issue #4 regression and P0 coverage
    Scenario: header_hint estimator works in full integration for Circuit Breaker
      Given the full chain integration is reset with real bundle_loader and token_bucket
      And a real bundle with token_bucket_llm rule and header_hint estimator is loaded
      And request context is path /v1/chat with jwt org_id org-1
      And request context has header X-Token-Estimate 5000
      When I run rule engine evaluation
      Then integration decision is allow all rules passed
      And circuit breaker was checked with cost 6000

    Scenario: UC-09 SaaS Unavailable - Edge enforces policy even when audit event queue fails
      # Uses a reject decision (tpm_exceeded) so queue_event IS called, proving
      # that a saas_client failure does not block or corrupt the enforcement decision.
      Given the full chain integration is reset with real bundle_loader and token_bucket
      And a real bundle with token_bucket_llm rule and TPM 1000 is loaded
      And SaaS client is configured but unreachable
      And request context is path /v1/chat with jwt org_id org-1
      And request context has header X-Token-Estimate 1500
      When I run rule engine evaluation
      Then integration decision is reject with reason "tpm_exceeded"
      And saas queue_event was attempted but did not block the decision

    Scenario: UC-16 OpenAI-compatible rate limiting headers
      # Tests rule_engine decision.headers output (pre-HTTP layer).
      # X-Fairvisor-Reason is stripped by decision_api in non-debug mode — see decision_api_spec.lua:519.
      Given the full chain integration is reset with real bundle_loader and token_bucket
      And a real bundle with token_bucket_llm rule and TPM 1000 is loaded
      And request context is path /v1/chat with jwt org_id org-1
      And request context has header X-Token-Estimate 1500
      When I run rule engine evaluation
      Then integration decision is reject with reason "tpm_exceeded"
      And decision headers include "X-Fairvisor-Reason" with value "tpm_exceeded"
      And decision headers include "Retry-After"
      And decision headers include "RateLimit-Limit" with value "1000"
      And decision headers include "RateLimit-Remaining" with value "0"
      And decision headers include "RateLimit-Reset"
      And decision headers include "RateLimit" matching pattern p_tpm.*;r=0;t=%d+

    Scenario: UC-18 Token usage shadow mode
      Given the full chain integration is reset with real bundle_loader and token_bucket
      And a real bundle with token_bucket_llm rule in shadow mode is loaded
      And request context is path /v1/chat with jwt org_id org-1
      And request context has header X-Token-Estimate 15000
      When I run rule engine evaluation
      Then integration decision is allow
      And integration decision mode is "shadow"
      And would_reject is true

