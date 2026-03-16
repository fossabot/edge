Feature: LLM Proxy Wrapper Mode unit behavior

  Rule: Composite Bearer token parsing
    Scenario: Valid composite bearer splits JWT and upstream key
      Given the nginx mock is set up
      And a composite bearer header "Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJ1c2VyMTIzIn0.:sk-abc123"
      When parse_composite_bearer is called
      Then parsing succeeds
      And the upstream_key is "sk-abc123"
      And JWT claims have sub "user123"

    Scenario: Missing colon separator returns composite_key_invalid
      Given the nginx mock is set up
      And an auth header "Bearer justajwt"
      When parse_composite_bearer is called
      Then parsing fails with reason "composite_key_invalid"

    Scenario: Empty upstream key returns upstream_key_missing
      Given the nginx mock is set up
      And an auth header with empty key
      When parse_composite_bearer is called
      Then parsing fails with reason "upstream_key_missing"

    Scenario: Non-bearer auth header returns composite_key_invalid
      Given the nginx mock is set up
      And an auth header "Basic dXNlcjpwYXNz"
      When parse_composite_bearer is called
      Then parsing fails with reason "composite_key_invalid"

    Scenario: Nil auth header returns composite_key_invalid
      Given the nginx mock is set up
      And a nil auth header
      When parse_composite_bearer is called
      Then parsing fails with reason "composite_key_invalid"

    Scenario: Token with colon in upstream key splits at first colon only
      Given the nginx mock is set up
      And a composite bearer header "Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJ1c2VyMTIzIn0.:sk-abc:extra"
      When parse_composite_bearer is called
      Then parsing succeeds
      And the upstream_key is "sk-abc:extra"

  Rule: Provider routing
    Scenario: /openai path maps to OpenAI upstream
      When I call get_provider for path "/openai/v1/chat/completions"
      Then provider prefix is "/openai"
      And provider upstream is "https://api.openai.com"
      And provider auth_header is "Authorization"

    Scenario: /anthropic path maps to Anthropic upstream
      When I call get_provider for path "/anthropic/v1/messages"
      Then provider prefix is "/anthropic"
      And provider upstream is "https://api.anthropic.com"
      And provider auth_header is "x-api-key"

    Scenario: /gemini-compat path maps to Gemini OpenAI-compat upstream
      When I call get_provider for path "/gemini-compat/v1/chat/completions"
      Then provider prefix is "/gemini-compat"
      And provider auth_header is "Authorization"

    Scenario: /gemini path maps to Gemini native upstream with x-goog-api-key
      When I call get_provider for path "/gemini/v1beta/models/gemini-pro:generateContent"
      Then provider prefix is "/gemini"
      And provider auth_header is "x-goog-api-key"

    Scenario: /gemini-compat matches before /gemini due to longer prefix
      When I call get_provider for path "/gemini-compat/v1/chat/completions"
      Then provider prefix is "/gemini-compat"

    Scenario: Unknown path prefix returns nil provider
      When I call get_provider for path "/unknown/v1/chat"
      Then provider is nil

    Scenario: /grok path maps to xAI upstream
      When I call get_provider for path "/grok/v1/chat/completions"
      Then provider prefix is "/grok"
      And provider upstream is "https://api.x.ai"

    Scenario: /ollama path has no auth header
      When I call get_provider for path "/ollama/api/generate"
      Then provider prefix is "/ollama"
      And provider auth_header is nil

  Rule: Pre-flight error bodies
    Scenario: OpenAI provider error body contains rate_limit_error type
      Given provider error_format is "openai"
      When I call preflight_error_body with reason "rate_limit_exceeded"
      Then error body contains "rate_limit_error"
      And error body contains "rate_limit_exceeded"

    Scenario: Anthropic provider error body uses Anthropic envelope
      Given provider error_format is "anthropic"
      When I call preflight_error_body with reason "rate_limit_exceeded"
      Then error body contains "rate_limit_error"
      And error body does not contain "RESOURCE_EXHAUSTED"

    Scenario: Gemini provider error body uses RESOURCE_EXHAUSTED status
      Given provider error_format is "gemini"
      When I call preflight_error_body with reason "rate_limit_exceeded"
      Then error body contains "RESOURCE_EXHAUSTED"
      And error body contains "429"

  Rule: Streaming cutoff formats
    Scenario: OpenAI cutoff format contains DONE marker
      Given provider cutoff_format is "openai"
      When I call streaming_cutoff_for_provider
      Then cutoff contains "DONE"
      And cutoff contains "finish_reason"

    Scenario: Anthropic cutoff format contains message_stop
      Given provider cutoff_format is "anthropic"
      When I call streaming_cutoff_for_provider
      Then cutoff contains "message_stop"
      And cutoff contains "max_tokens"

    Scenario: Gemini cutoff format contains MAX_TOKENS without DONE
      Given provider cutoff_format is "gemini"
      When I call streaming_cutoff_for_provider
      Then cutoff contains "MAX_TOKENS"
      And cutoff does not contain "DONE"

  Rule: replace_openai_cutoff post-processing
    Scenario: Anthropic format replaces OpenAI cutoff sequence
      Given an SSE output ending with OpenAI finish_reason and DONE
      When replace_openai_cutoff is called with format "anthropic"
      Then output contains "message_stop"
      And output does not contain "DONE"

    Scenario: Gemini format replaces OpenAI cutoff sequence
      Given an SSE output ending with OpenAI finish_reason and DONE
      When replace_openai_cutoff is called with format "gemini"
      Then output contains "MAX_TOKENS"
      And output does not contain "DONE"

    Scenario: OpenAI format leaves output unchanged
      Given an SSE output ending with OpenAI finish_reason and DONE
      When replace_openai_cutoff is called with format "openai"
      Then output contains "DONE"

    Scenario: Output without DONE marker is unchanged
      Given an SSE output with no DONE marker
      When replace_openai_cutoff is called with format "anthropic"
      Then output is returned unchanged

  Rule: Policy header descriptor collection
    Scenario: Bundle with header:Org-id in limit_keys collects it
      Given a bundle with limit_key "header:Org-id"
      When I call collect_policy_header_descriptors
      Then header descriptors contain "org-id"

    Scenario: Bundle with header:X-Tenant in match expression collects it
      Given a bundle with match key "header:X-Tenant"
      When I call collect_policy_header_descriptors
      Then header descriptors contain "x-tenant"

    Scenario: Bundle with only jwt descriptors collects nothing
      Given a bundle with limit_key "jwt:sub"
      When I call collect_policy_header_descriptors
      Then header descriptors is empty

    Scenario: Nil bundle returns empty header descriptors
      Given a nil bundle
      When I call collect_policy_header_descriptors
      Then header descriptors is empty

  Rule: access_handler request dispatch
    Scenario: Missing auth header returns 401
      Given the nginx mock is set up for access_handler
      And request path is "/openai/v1/chat/completions"
      When access_handler is called
      Then response exit code is 401

    Scenario: Valid composite token to known provider allows request
      Given the nginx mock is set up for access_handler
      And request auth header is "Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJ1c2VyMTIzIn0.:sk-abc123"
      And request path is "/openai/v1/chat/completions"
      When access_handler is called
      Then upstream url contains "api.openai.com"
      And ngx exit was not called

    Scenario: Valid composite token to unknown path returns 404
      Given the nginx mock is set up for access_handler
      And request auth header is "Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJ1c2VyMTIzIn0.:sk-abc123"
      And request path is "/unknown/endpoint"
      When access_handler is called
      Then response exit code is 404

    Scenario: Rule engine reject returns 429
      Given the nginx mock is set up for access_handler
      And request auth header is "Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJ1c2VyMTIzIn0.:sk-abc123"
      And request path is "/anthropic/v1/messages"
      And mock rule_engine returns action "reject"
      When access_handler is called
      Then response exit code is 429

  Rule: hybrid mode routing decision
    Scenario: hybrid mode — provider path triggers wrapper access_handler
      Given the nginx mock is set up for access_handler
      And request auth header is "Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJ1c2VyMTIzIn0.:sk-abc123"
      And request path is "/openai/v1/chat/completions"
      When access_handler is called
      Then upstream url contains "api.openai.com"
      And ngx exit was not called

    Scenario: hybrid mode — get_provider returns nil for non-provider path
      When I call get_provider for path "/api/v1/some-internal-endpoint"
      Then provider is nil

  Rule: wrapper init
    Scenario: init with valid deps table returns true
      When I call wrapper init with valid deps
      Then init result is true

    Scenario: init with non-table argument returns nil
      When I call wrapper init with nil
      Then init result is nil
