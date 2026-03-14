Feature: Decision API unit behavior
  Rule: JWT payload and request context
    Scenario: Decodes a valid JWT payload
      Given the decision api dependencies are initialized
      And the mode is "decision_service" and retry jitter is "true"
      And headers include "Authorization" as "Bearer a.eyJzdWIiOiJ1c2VyLTEiLCJyb2xlIjoiYWRtaW4ifQ.c"
      When I decode the jwt payload from authorization header
      Then jwt claims contain sub "user-1" and role "admin"
      And the test cleanup restores globals

    Scenario: Returns nil claims for malformed JWT
      Given the decision api dependencies are initialized
      And the mode is "decision_service" and retry jitter is "true"
      And headers include "Authorization" as "Bearer not-a-jwt"
      When I decode the jwt payload from authorization header
      Then jwt claims are nil
      And the test cleanup restores globals

    Scenario: BUG-6 JWT payload with nested JSON in claims is decoded by fallback
      Given the decision api dependencies are initialized
      And the mode is "decision_service" and retry jitter is "true"
      And headers include "Authorization" with JWT containing nested claims
      When I decode the jwt payload from authorization header
      Then jwt claims contain sub "user-nested"
      And jwt claims contain nested realm_access with roles "a" and "b"
      And the test cleanup restores globals

    Scenario: Uses X-Original headers in decision service mode
      Given the decision api dependencies are initialized
      And the mode is "decision_service" and retry jitter is "true"
      And request method is "GET" and path is "/v1/decision"
      And headers include "X-Original-Method" as "POST"
      And headers include "X-Original-URI" as "/v1/data"
      And headers include "X-Original-Host" as "API.EXAMPLE.COM:443"
      And headers include "User-Agent" as "agent-a"
      And client ip is "10.0.0.5"
      And headers include "Authorization" as "Bearer a.eyJwbGFuIjoicHJvIiwidXNlcl9pZCI6NDJ9.c"
      When I build request context
      Then request context method is "POST" and path is "/v1/data"
      And request context host is "api.example.com"
      And request context has user agent "agent-a" and client ip "10.0.0.5"
      And request context includes jwt claim plan "pro"
      And the test cleanup restores globals

    Scenario: Builds ip tor selector from nginx variable
      Given the decision api dependencies are initialized
      And the mode is "decision_service" and retry jitter is "true"
      And nginx tor exit variable is "1"
      When I build request context
      Then request context ip tor is "true"
      And the test cleanup restores globals

    Scenario: Normalizes X-Original-Host with trailing dot
      Given the decision api dependencies are initialized
      And the mode is "decision_service" and retry jitter is "true"
      And headers include "X-Original-Host" as "API.EXAMPLE.COM."
      When I build request context
      Then request context host is "api.example.com"
      And the test cleanup restores globals

    Scenario: Uses request method and uri in reverse proxy mode
      Given the decision api dependencies are initialized
      And the mode is "reverse_proxy" and retry jitter is "true"
      And request method is "PATCH" and path is "/items/42"
      And headers include "X-Original-Method" as "DELETE"
      And headers include "X-Original-URI" as "/ignored"
      When I build request context
      Then request context method is "PATCH" and path is "/items/42"
      And request context host is "edge.internal"
      And the test cleanup restores globals

    Scenario: BUG-9 read request body in reverse proxy mode
      Given the decision api dependencies are initialized
      And the mode is "reverse_proxy"
      And request method is "POST" and path is "/v1/chat"
      And the request body is "{\"foo\":\"bar\"}"
      When I build request context
      Then request context body is "{\"foo\":\"bar\"}"
      And request context body_hash is present
      And the test cleanup restores globals

    Scenario: BUG-9 read request body from file (fallback)
      Given the decision api dependencies are initialized
      And the mode is "reverse_proxy"
      And request method is "POST" and path is "/v1/chat"
      And the request body is in file "test_body.tmp" with content "{\"large\":\"body\"}"
      When I build request context
      Then request context body is "{\"large\":\"body\"}"
      And request context body_hash is present
      And the test cleanup restores globals

    Scenario: BUG-9 do not read body in decision service mode
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And request method is "POST" and path is "/v1/chat"
      And the request body is "{\"foo\":\"bar\"}"
      When I build request context
      Then request context body is nil
      And request context body_hash is nil
      And the test cleanup restores globals

    Scenario: BUG-9 do not read body for GET requests
      Given the decision api dependencies are initialized
      And the mode is "reverse_proxy"
      And request method is "GET" and path is "/v1/chat"
      And the request body is "{\"foo\":\"bar\"}"
      When I build request context
      Then request context body is nil
      And request context body_hash is nil
      And the test cleanup restores globals

    Scenario: BUG-15 geoip hot-reload timer is scheduled
      Given the decision api dependencies are initialized
      When I build request context
      Then geoip hot-reload timer is scheduled for 24 hours
      And the test cleanup restores globals

  Rule: Access phase decision mapping
    Scenario: Returns 503 when no bundle exists
      Given the decision api dependencies are initialized
      And the mode is "decision_service" and retry jitter is "true"
      And no bundle is currently loaded
      When I run the access handler
      Then the request is rejected with status 503
      And the test cleanup restores globals

    Scenario: Allow decision in decision service mode sets headers and proceeds
      Given the decision api dependencies are initialized
      And the mode is "decision_service" and retry jitter is "true"
      And the rule engine decision is allow with headers limit "200" remaining "150" reset "1"
      When I run the access handler
      Then the access phase proceeds without exiting
      And response header "RateLimit-Limit" is "200"
      And response header "RateLimit-Remaining" is "150"
      And response header "RateLimit-Reset" is "1"
      And one decision metric is emitted for action "allow" and policy "policy-a"
      And the bundle and context were passed to rule engine
      And the test cleanup restores globals

    Scenario: Reject decision sets reason and deterministic jittered retry-after
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And the rule engine decision is reject with reason "rate_limit_exceeded" and retry_after 10
      When I run the access handler
      Then the request is rejected with status 429
      And retry after header is between 10 and 15
      And one decision metric is emitted for action "reject" and policy "policy-r"
      And the test cleanup restores globals

    Scenario: Reject decisions emit retry-after bucket metric
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And the rule engine decision is reject with reason "rate_limit_exceeded" and retry_after 10
      When I run the access handler
      Then the request is rejected with status 429
      And retry after bucket metric is emitted for bucket "le_30"
      And the test cleanup restores globals

    Scenario: Jitter also applies when Retry-After is already present in decision headers
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And the rule engine decision is reject with header retry_after 10 and reason "rate_limit_exceeded"
      When I run the access handler
      Then retry after header is between 10 and 15
      And the test cleanup restores globals

    Scenario: Budget exceeded retry-after is jittered but capped by base window
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And the rule engine decision is reject with reason "budget_exceeded" and retry_after 10
      When I run the access handler
      Then retry after header is between 5 and 10
      And the test cleanup restores globals

    Scenario: Retry-After jitter is deterministic for equivalent rejects
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And the rule engine decision is reject with reason "rate_limit_exceeded" and retry_after 10
      When I run the access handler twice
      Then both retry after headers are equal
      And the test cleanup restores globals

    Scenario: Retry-After jitter differs across different clients
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And the rule engine decision is reject with reason "rate_limit_exceeded" and retry_after 10
      When I run the access handler for clients "10.0.0.1" and "10.0.0.2"
      Then retry after headers are different
      And the test cleanup restores globals

    Scenario: Jitter property holds for many clients
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And the rule engine decision is reject with reason "rate_limit_exceeded" and retry_after 10
      When I collect retry after samples for clients "10.0.0.1,10.0.0.2,10.0.0.3,10.0.0.4"
      Then retry after jitter is stable per client and diversified across clients
      And the test cleanup restores globals

    Scenario: Decision API emits namespaced metric without legacy duplication
      Given the decision api dependencies are initialized
      And the mode is "decision_service" and retry jitter is "true"
      And the rule engine decision is allow with headers limit "200" remaining "150" reset "1"
      When I run the access handler
      Then one decision metric is emitted for action "allow" and policy "policy-a"
      And legacy fairvisor decisions metric is not emitted
      And the test cleanup restores globals

    Scenario: Reject response includes all rate limit and fairvisor headers
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And the rule engine decision is reject with reason "rate_limit_exceeded" and retry_after 10
      When I run the access handler
      Then the request is rejected with status 429
      And response includes all rate limit and fairvisor headers on reject
      And the test cleanup restores globals

    Scenario: Reverse proxy allow buffers headers for header filter
      Given the decision api dependencies are initialized
      And the mode is "reverse_proxy" and retry jitter is "true"
      And the rule engine decision is throttle with delay_ms 250
      When I run the access handler
      Then the access phase proceeds without exiting
      And throttle delay sleep is 0.25 seconds
      And the reverse proxy headers are buffered in ngx ctx
      When I run the header filter handler
      Then header filter copies buffered header "RateLimit-Limit" with value "25"
      And header filter copies buffered header "RateLimit-Remaining" with value "24"
      And the test cleanup restores globals

    Scenario: Shadow mode allow logs mode and does not reject
      Given the decision api dependencies are initialized
      And the mode is "decision_service" and retry jitter is "true"
      And the rule engine decision is allow in shadow mode
      When I run the access handler
      Then the access phase proceeds without exiting
      And shadow mode log entry is emitted
      And the test cleanup restores globals

  Rule: Jitter hash fallbacks
    Scenario: stable jitter uses rolling hash when ngx.crc32_short is unavailable
      Given the decision api dependencies are initialized
      And ngx crc32_short is unavailable
      And the mode is "decision_service"
      And the rule engine decision is reject with reason "rate_limit_exceeded" and retry_after 60
      When I run the access handler
      Then the request is rejected with status 429
      And the test cleanup restores globals

    Scenario: stable identity hash uses sha1_bin when hmac_sha256 is unavailable
      Given the decision api dependencies are initialized
      And ngx hmac_sha256 is unavailable for identity hash
      And the mode is "decision_service"
      And the rule engine decision is reject with reason "rate_limit_exceeded" and retry_after 60
      When I run the access handler
      Then the request is rejected with status 429
      And the test cleanup restores globals

    Scenario: stable identity hash uses pure rolling hash when hmac_sha256 and sha1_bin are unavailable
      Given the decision api dependencies are initialized
      And ngx hmac_sha256 and sha1_bin are unavailable
      And the mode is "decision_service"
      And the rule engine decision is reject with reason "rate_limit_exceeded" and retry_after 60
      When I run the access handler
      Then the request is rejected with status 429
      And the test cleanup restores globals

  Rule: Provider detection
    Scenario: provider is anthropic when path contains anthropic segment
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And request method is "GET" and path is "/anthropic/v1/messages"
      When I build request context
      Then request context provider is "anthropic"
      And the test cleanup restores globals

    Scenario: provider is openai_compatible for /v1/chat/completions
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And request method is "GET" and path is "/v1/chat/completions"
      When I build request context
      Then request context provider is "openai_compatible"
      And the test cleanup restores globals

    Scenario: provider is gemini when path contains gemini segment
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And request method is "GET" and path is "/api/gemini/chat"
      When I build request context
      Then request context provider is "gemini"
      And the test cleanup restores globals

    Scenario: provider is nil for unknown path
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And request method is "GET" and path is "/api/v1/users"
      When I build request context
      Then request context provider is nil
      And the test cleanup restores globals

    Scenario: provider is mistral when path contains mistral segment
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And request method is "GET" and path is "/mistral/chat"
      When I build request context
      Then request context provider is "mistral"
      And the test cleanup restores globals

  Rule: ip tor normalization via normalize_boolish
    Scenario: ip tor is true when X-Tor-Exit header is yes
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And headers include "X-Tor-Exit" as "yes"
      When I build request context
      Then request context ip tor is "true"
      And the test cleanup restores globals

    Scenario: ip tor is false when X-Tor-Exit header is no
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And headers include "X-Tor-Exit" as "no"
      When I build request context
      Then request context ip tor is "false"
      And the test cleanup restores globals

    Scenario: ip tor is true when X-Tor-Exit header is 1
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And headers include "X-Tor-Exit" as "1"
      When I build request context
      Then request context ip tor is "true"
      And the test cleanup restores globals

    Scenario: ip tor is false when X-Tor-Exit header is 0
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And headers include "X-Tor-Exit" as "0"
      When I build request context
      Then request context ip tor is "false"
      And the test cleanup restores globals

  Rule: Bundle descriptor hint suppresses user agent
    Scenario: user_agent is nil when bundle descriptor hints needs_user_agent is false
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And the bundle has descriptor hints with needs_user_agent false
      And headers include "User-Agent" as "TestBot/1.0"
      When I build request context with the current bundle
      Then request context user agent is nil
      And the test cleanup restores globals

  Rule: access_handler 503 paths
    Scenario: access_handler returns 503 when rule engine evaluate is missing
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And the rule engine evaluate is removed
      When I run the access handler
      Then the request is rejected with status 503
      And the test cleanup restores globals

    Scenario: access_handler returns 503 when no bundle is loaded
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And no bundle is currently loaded
      When I run the access handler
      Then the request is rejected with status 503
      And the test cleanup restores globals

  Rule: LLM rejection produces JSON error body
    Scenario: access_handler produces JSON error body for tpm_exceeded
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And ngx say is captured
      And the rule engine decision is reject with reason "tpm_exceeded" and retry_after 60
      When I run the access handler
      Then the request is rejected with status 429
      And response content type is "application/json"
      And ngx say was called
      And the test cleanup restores globals

    Scenario: access_handler produces JSON error body for tpd_exceeded
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And ngx say is captured
      And the rule engine decision is reject with reason "tpd_exceeded" and retry_after 3600
      When I run the access handler
      Then the request is rejected with status 429
      And response content type is "application/json"
      And ngx say was called
      And the test cleanup restores globals

  Rule: Retry-after bucket gt_3600
    Scenario: retry_after 7200 seconds emits gt_3600 bucket metric
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And the rule engine decision is reject with reason "rate_limit_exceeded" and retry_after 7200
      When I run the access handler
      Then retry after bucket metric is emitted for bucket "gt_3600"
      And the test cleanup restores globals

  Rule: log_handler upstream error
    Scenario: log_handler queues upstream_error_forwarded event for status 502
      Given the decision api dependencies are initialized
      And decision api is initialized with a mock saas client
      And ngx status is 502
      And upstream address is "backend:8080"
      When I run the log handler
      Then the saas client received an event of type "upstream_error_forwarded"
      And the test cleanup restores globals

    Scenario: log_handler does not queue event for status 429
      Given the decision api dependencies are initialized
      And decision api is initialized with a mock saas client
      And ngx status is 429
      When I run the log handler
      Then no saas client event was queued
      And the test cleanup restores globals

    Scenario: log_handler does not queue event when no saas client
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      And ngx status is 500
      When I run the log handler
      Then the access phase proceeds without exiting
      And the test cleanup restores globals

  Rule: debug_session_handler
    Scenario: debug_session_handler returns 404 when no secret configured
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      When I run the debug session handler
      Then the handler exits with status 404
      And the test cleanup restores globals

    Scenario: debug_session_handler returns 405 for GET request
      Given the decision api dependencies are initialized
      And the debug session secret is configured as "my-secret"
      And the request method for handler is "GET"
      When I run the debug session handler
      Then the handler exits with status 405
      And the test cleanup restores globals

    Scenario: debug_session_handler returns 403 for wrong secret
      Given the decision api dependencies are initialized
      And the debug session secret is configured as "my-secret"
      And the request method for handler is "POST"
      And headers include "X-Fairvisor-Debug-Secret" as "wrong-secret"
      When I run the debug session handler
      Then the handler exits with status 403
      And the test cleanup restores globals

    Scenario: debug_session_handler returns 204 for valid secret
      Given the decision api dependencies are initialized
      And the debug session secret is configured as "my-secret"
      And the request method for handler is "POST"
      And headers include "X-Fairvisor-Debug-Secret" as "my-secret"
      When I run the debug session handler
      Then the handler exits with status 204
      And the test cleanup restores globals

  Rule: debug_logout_handler
    Scenario: debug_logout_handler returns 404 when no secret configured
      Given the decision api dependencies are initialized
      And the mode is "decision_service"
      When I run the debug logout handler
      Then the handler exits with status 404
      And the test cleanup restores globals

    Scenario: debug_logout_handler returns 405 for GET request
      Given the decision api dependencies are initialized
      And the debug session secret is configured as "my-secret"
      And the request method for handler is "GET"
      When I run the debug logout handler
      Then the handler exits with status 405
      And the test cleanup restores globals

    Scenario: debug_logout_handler returns 204 and clears cookie on POST
      Given the decision api dependencies are initialized
      And the debug session secret is configured as "my-secret"
      And the request method for handler is "POST"
      When I run the debug logout handler
      Then the handler exits with status 204
      And the test cleanup restores globals
