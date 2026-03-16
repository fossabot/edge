-- LLM Proxy Wrapper Mode — feature 019
-- Composite Bearer token: "Authorization: Bearer CLIENT_JWT:UPSTREAM_KEY"
-- Provider registry maps path prefix → upstream host + auth scheme.
-- Provider-native error bodies and streaming cutoff formats.

local pairs = pairs
local ipairs = ipairs
local pcall = pcall
local tostring = tostring
local type = type
local string_find = string.find
local string_lower = string.lower
local string_sub = string.sub
local string_gsub = string.gsub
local table_sort = table.sort

local utils = require("fairvisor.utils")
local json_lib = utils.get_json()

local _M = {}

local _deps = {
  health        = nil,
  rule_engine   = nil,
  bundle_loader = nil,
}

-- ---------------------------------------------------------------------------
-- Provider registry
-- IMPORTANT: sorted longest-prefix-first at module load so /gemini-compat
-- matches before /gemini.
-- ---------------------------------------------------------------------------
local _PROVIDERS = {
  {
    prefix          = "/openai",
    upstream        = "https://api.openai.com",
    auth_header     = "Authorization",
    auth_prefix     = "Bearer ",
    default_headers = {},
    error_format    = "openai",
    cutoff_format   = "openai",
    notes           = "Native",
  },
  {
    prefix          = "/anthropic",
    upstream        = "https://api.anthropic.com",
    auth_header     = "x-api-key",
    auth_prefix     = "",
    default_headers = { ["anthropic-version"] = "2023-06-01" },
    error_format    = "anthropic",
    cutoff_format   = "anthropic",
    notes           = "Native",
  },
  {
    prefix          = "/gemini-compat",
    upstream        = "https://generativelanguage.googleapis.com/v1beta/openai",
    auth_header     = "Authorization",
    auth_prefix     = "Bearer ",
    default_headers = {},
    error_format    = "openai",
    cutoff_format   = "openai",
    notes           = "OpenAI-compat",
  },
  {
    prefix          = "/gemini",
    upstream        = "https://generativelanguage.googleapis.com",
    auth_header     = "x-goog-api-key",
    auth_prefix     = "",
    default_headers = {},
    error_format    = "gemini",
    cutoff_format   = "gemini",
    notes           = "Native",
  },
  {
    prefix          = "/grok",
    upstream        = "https://api.x.ai",
    auth_header     = "Authorization",
    auth_prefix     = "Bearer ",
    default_headers = {},
    error_format    = "openai",
    cutoff_format   = "openai",
    notes           = "OpenAI-compat",
  },
  {
    prefix          = "/groq",
    upstream        = "https://api.groq.com/openai",
    auth_header     = "Authorization",
    auth_prefix     = "Bearer ",
    default_headers = {},
    error_format    = "openai",
    cutoff_format   = "openai",
    notes           = "OpenAI-compat",
  },
  {
    prefix          = "/mistral",
    upstream        = "https://api.mistral.ai",
    auth_header     = "Authorization",
    auth_prefix     = "Bearer ",
    default_headers = {},
    error_format    = "openai",
    cutoff_format   = "openai",
    notes           = "OpenAI-compat",
  },
  {
    prefix          = "/deepseek",
    upstream        = "https://api.deepseek.com",
    auth_header     = "Authorization",
    auth_prefix     = "Bearer ",
    default_headers = {},
    error_format    = "openai",
    cutoff_format   = "openai",
    notes           = "OpenAI-compat",
  },
  {
    prefix          = "/perplexity",
    upstream        = "https://api.perplexity.ai",
    auth_header     = "Authorization",
    auth_prefix     = "Bearer ",
    default_headers = {},
    error_format    = "openai",
    cutoff_format   = "openai",
    notes           = "OpenAI-compat",
  },
  {
    prefix          = "/together",
    upstream        = "https://api.together.xyz",
    auth_header     = "Authorization",
    auth_prefix     = "Bearer ",
    default_headers = {},
    error_format    = "openai",
    cutoff_format   = "openai",
    notes           = "OpenAI-compat",
  },
  {
    prefix          = "/fireworks",
    upstream        = "https://api.fireworks.ai/inference",
    auth_header     = "Authorization",
    auth_prefix     = "Bearer ",
    default_headers = {},
    error_format    = "openai",
    cutoff_format   = "openai",
    notes           = "OpenAI-compat",
  },
  {
    prefix          = "/cerebras",
    upstream        = "https://api.cerebras.ai",
    auth_header     = "Authorization",
    auth_prefix     = "Bearer ",
    default_headers = {},
    error_format    = "openai",
    cutoff_format   = "openai",
    notes           = "OpenAI-compat",
  },
  {
    prefix          = "/ollama",
    upstream        = "http://localhost:11434",
    auth_header     = nil,
    auth_prefix     = nil,
    default_headers = {},
    error_format    = "openai",
    cutoff_format   = "openai",
    notes           = "No auth, local only",
  },
}

-- Sort descending by prefix length so longer prefixes match first
table_sort(_PROVIDERS, function(a, b) return #a.prefix > #b.prefix end)

-- ---------------------------------------------------------------------------
-- Error body templates — pre-built strings to avoid allocation on hot path
-- ---------------------------------------------------------------------------
local _ERROR_BODIES = {
  openai = function(reason, msg)
    local r = reason or "rate_limit_exceeded"
    local m = msg or "Token budget exceeded for this tenant."
    return '{"error":{"type":"rate_limit_error","code":"' .. r
      .. '","message":"' .. m .. '","param":null}}'
  end,
  anthropic = function(_, msg)
    local m = msg or "Token budget exceeded for this tenant."
    return '{"type":"error","error":{"type":"rate_limit_error","message":"' .. m .. '"}}'
  end,
  gemini = function(_, msg)
    local m = msg or "Token budget exceeded for this tenant."
    return '{"error":{"code":429,"message":"' .. m .. '","status":"RESOURCE_EXHAUSTED"}}'
  end,
}

-- ---------------------------------------------------------------------------
-- Streaming cutoff sequences
-- ---------------------------------------------------------------------------
local _STREAM_CUTOFF = {
  openai = 'data: {"choices":[{"delta":{},"finish_reason":"length","index":0}]}\n\n'
         .. 'data: [DONE]\n\n',

  anthropic = 'event: message_delta\n'
            .. 'data: {"type":"message_delta","delta":{"stop_reason":"max_tokens",'
            .. '"stop_sequence":null},"usage":{"output_tokens":0}}\n\n'
            .. 'event: message_stop\n'
            .. 'data: {"type":"message_stop"}\n\n',

  gemini = 'data: {"candidates":[{"content":{"parts":[],"role":"model"},'
         .. '"finishReason":"MAX_TOKENS","index":0}],"usageMetadata":{}}\n\n',
}

-- ---------------------------------------------------------------------------
-- Logging helpers
-- ---------------------------------------------------------------------------
local function _log_err(...)
  if ngx and ngx.log then ngx.log(ngx.ERR, "wrapper ", ...) end
end

local function _log_info(...)
  if ngx and ngx.log then ngx.log(ngx.INFO, "wrapper ", ...) end
end

-- ---------------------------------------------------------------------------
-- Metrics helper
-- ---------------------------------------------------------------------------
local function _inc(name, labels, value)
  local health = _deps.health
  if not health or type(health.inc) ~= "function" then return end
  pcall(health.inc, health, name, labels or {}, value or 1)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- init() — called from init_worker.lua.
function _M.init(deps)
  if type(deps) ~= "table" then
    return nil, "deps must be a table"
  end
  _deps.health        = deps.health
  _deps.rule_engine   = deps.rule_engine
  _deps.bundle_loader = deps.bundle_loader
  return true
end

-- parse_composite_bearer(auth_header)
-- Returns: ok_table {jwt_part, upstream_key} or nil, reason_code
--
-- Composite token format: "Bearer CLIENT_JWT:UPSTREAM_KEY"
-- Split is at the FIRST colon in the token portion.
function _M.parse_composite_bearer(auth_header)
  if type(auth_header) ~= "string" then
    return nil, "composite_key_invalid"
  end

  if string_sub(auth_header, 1, 7) ~= "Bearer " then
    return nil, "composite_key_invalid"
  end

  local token = string_sub(auth_header, 8)
  if token == "" then
    return nil, "composite_key_invalid"
  end

  -- Find first colon to split JWT:KEY
  local colon_pos = string_find(token, ":", 1, true)
  if not colon_pos or colon_pos <= 1 then
    return nil, "composite_key_invalid"
  end

  local jwt_part    = string_sub(token, 1, colon_pos - 1)
  local upstream_key = string_sub(token, colon_pos + 1)

  if jwt_part == "" then
    return nil, "composite_key_invalid"
  end

  if upstream_key == "" then
    return nil, "upstream_key_missing"
  end

  -- Validate JWT is three base64url segments (header.payload.signature)
  local first_dot  = string_find(jwt_part, ".", 1, true)
  if not first_dot then
    return nil, "composite_key_invalid"
  end
  local second_dot = string_find(jwt_part, ".", first_dot + 1, true)
  if not second_dot then
    return nil, "composite_key_invalid"
  end

  -- Decode JWT payload (middle segment)
  local payload_b64 = string_sub(jwt_part, first_dot + 1, second_dot - 1)
  local payload_json = utils.base64url_decode(payload_b64)
  if not payload_json then
    return nil, "composite_key_invalid"
  end

  local claims
  if json_lib then
    local ok, decoded = pcall(json_lib.decode, payload_json)
    if ok and type(decoded) == "table" then
      claims = decoded
    end
  end

  -- Fallback: claims may be nil if JSON decode fails, still return the key
  return {
    jwt_part     = jwt_part,
    upstream_key = upstream_key,
    claims       = claims or {},
  }
end

-- get_provider(path)
-- Returns the matching provider table or nil.
-- Iterates sorted list (longest prefix first).
function _M.get_provider(path)
  if type(path) ~= "string" then return nil end

  for _, provider in ipairs(_PROVIDERS) do
    local pfx = provider.prefix
    if string_sub(path, 1, #pfx) == pfx then
      -- Ensure it's an exact prefix match (next char is "/" or end of string)
      local next_char = string_sub(path, #pfx + 1, #pfx + 1)
      if next_char == "/" or next_char == "" then
        return provider
      end
    end
  end

  return nil
end

-- preflight_error_body(provider, reason_code, message)
-- Returns provider-native JSON error body string (HTTP 429).
function _M.preflight_error_body(provider, reason_code, message)
  local fmt = provider and provider.error_format or "openai"
  local builder = _ERROR_BODIES[fmt] or _ERROR_BODIES.openai
  return builder(reason_code, message)
end

-- streaming_cutoff_for_provider(provider)
-- Returns the provider-native SSE termination sequence string.
function _M.streaming_cutoff_for_provider(provider)
  local fmt = provider and provider.cutoff_format or "openai"
  return _STREAM_CUTOFF[fmt] or _STREAM_CUTOFF.openai
end

-- collect_policy_header_descriptors(bundle)
-- Returns a set (table with keys = lowercase header names) of headers
-- referenced as "header:<name>" in active policy rules.
-- Used to strip only those headers before forwarding.
function _M.collect_policy_header_descriptors(bundle)
  local result = {}
  if type(bundle) ~= "table" then return result end

  local policies = bundle.policies
  if type(policies) ~= "table" then return result end

  for _, policy in ipairs(policies) do
    local spec = policy and policy.spec
    if type(spec) == "table" then
      local rules = spec.rules
      if type(rules) == "table" then
        for _, rule in ipairs(rules) do
          -- Scan limit_keys
          if type(rule.limit_keys) == "table" then
            for _, key in ipairs(rule.limit_keys) do
              if type(key) == "string" then
                local name = string_sub(key, 8)  -- strip "header:"
                if string_sub(key, 1, 7) == "header:" and name ~= "" then
                  result[string_lower(name)] = true
                end
              end
            end
          end
          -- Scan match expressions
          if type(rule.match) == "table" then
            for descriptor_key, _ in pairs(rule.match) do
              if type(descriptor_key) == "string"
                 and string_sub(descriptor_key, 1, 7) == "header:" then
                local name = string_sub(descriptor_key, 8)
                if name ~= "" then
                  result[string_lower(name)] = true
                end
              end
            end
          end
        end
      end
    end
  end

  return result
end

-- strip_policy_headers(header_set)
-- Removes headers in header_set from the current nginx request.
-- header_set: table returned by collect_policy_header_descriptors().
function _M.strip_policy_headers(header_set)
  if not ngx or not ngx.req then return end
  for name, _ in pairs(header_set) do
    -- ngx.req.clear_header accepts both hyphen and underscore forms
    ngx.req.clear_header(name)
    -- Also try with hyphens replaced by underscores (OpenResty normalisation)
    local under = string_gsub(name, "-", "_")
    if under ~= name then
      ngx.req.clear_header(under)
    end
  end
end

-- replace_openai_cutoff(output, cutoff_format)
-- Post-processes streaming.body_filter() output to replace the OpenAI-style
-- cutoff sequence with the provider-native format.
-- Returns the modified output string.
function _M.replace_openai_cutoff(output, cutoff_format)
  if type(output) ~= "string" then return output end
  if cutoff_format == "openai" or not cutoff_format then return output end

  -- Only process if the output ends with the OpenAI [DONE] marker
  local done_marker = "data: [DONE]\n\n"
  if string_sub(output, #output - #done_marker + 1) ~= done_marker then
    return output
  end

  -- Find the start of the finish_reason chunk that streaming.lua injects
  local finish_prefix = 'data: {"choices":[{"delta":{},"finish_reason":"length"'
  local finish_start = string_find(output, finish_prefix, 1, true)
  if not finish_start then
    -- The [DONE] is present but no finish_reason event. Leave as-is except
    -- replace [DONE] with provider-native termination.
    local pre = string_sub(output, 1, #output - #done_marker)
    local cutoff = _STREAM_CUTOFF[cutoff_format] or _STREAM_CUTOFF.openai
    return pre .. cutoff
  end

  -- Everything before the injected finish_reason event + provider-native termination
  local pre = string_sub(output, 1, finish_start - 1)
  local cutoff = _STREAM_CUTOFF[cutoff_format] or _STREAM_CUTOFF.openai
  return pre .. cutoff
end

-- access_handler()
-- Main nginx access phase handler for FAIRVISOR_MODE=wrapper.
-- Parses composite bearer, evaluates rules, rewrites headers, sets upstream URL.
function _M.access_handler()
  _log_info("access_handler entered")
  _inc("fairvisor_wrapper_requests_total", { action = "received" })

  local bundle_loader = _deps.bundle_loader
  local rule_engine   = _deps.rule_engine

  -- -------------------------------------------------------------------------
  -- 1. Parse composite Bearer token
  -- -------------------------------------------------------------------------
  ngx.req.read_body()
  local raw_headers = ngx.req.get_headers()

  local auth_header = raw_headers["Authorization"] or raw_headers["authorization"]
  local parsed, parse_err = _M.parse_composite_bearer(auth_header)
  if not parsed then
    _log_info("composite_bearer_parse_failed reason=", parse_err)
    _inc("fairvisor_wrapper_requests_total", { action = "reject", reason = parse_err or "composite_key_invalid" })

    local provider_for_error = _M.get_provider(ngx.var.uri or "")
    local body = _M.preflight_error_body(provider_for_error, parse_err, nil)
    ngx.header["Content-Type"] = "application/json"
    ngx.header["X-Fairvisor-Reason"] = parse_err or "composite_key_invalid"
    ngx.status = 401
    ngx.print(body)
    return ngx.exit(401)
  end

  -- -------------------------------------------------------------------------
  -- 2. Resolve provider from path
  -- -------------------------------------------------------------------------
  local path = ngx.var.uri or ""
  local provider = _M.get_provider(path)
  if not provider then
    _log_info("provider_not_configured path=", path)
    _inc("fairvisor_wrapper_requests_total", { action = "reject", reason = "provider_not_configured" })
    ngx.header["Content-Type"] = "application/json"
    ngx.header["X-Fairvisor-Reason"] = "provider_not_configured"
    ngx.status = 404
    -- Use OpenAI format for unmapped paths (best effort)
    ngx.print(_ERROR_BODIES.openai("provider_not_configured",
      "No provider mapping for the requested path prefix."))
    return ngx.exit(404)
  end

  -- Strip /{provider} prefix from the path for upstream forwarding
  local upstream_path = string_sub(path, #provider.prefix + 1)
  if upstream_path == "" then upstream_path = "/" end

  -- Build full upstream URL including query string
  local args = ngx.var.args
  local upstream_url = provider.upstream .. upstream_path
  if type(args) == "string" and args ~= "" then
    upstream_url = upstream_url .. "?" .. args
  end

  -- -------------------------------------------------------------------------
  -- 3. Build request context for enforcement
  -- -------------------------------------------------------------------------
  local headers = {}
  if type(raw_headers) == "table" then
    for k, v in pairs(raw_headers) do
      if type(k) == "string" then
        headers[k] = v
        headers[string_lower(k)] = v
        -- Also provide underscore form for descriptor.lua compatibility
        headers[string_gsub(string_lower(k), "-", "_")] = v
      end
    end
  end

  local body = ngx.req.get_body_data()

  local request_context = {
    method     = ngx.var.request_method,
    path       = path,
    host       = ngx.var.host,
    headers    = headers,
    query_params = ngx.req.get_uri_args(),
    jwt_claims = parsed.claims,
    ip_address = ngx.var.remote_addr,
    provider   = provider.prefix:sub(2),   -- strip leading /
    body       = body,
  }

  -- -------------------------------------------------------------------------
  -- 4. Pre-flight enforcement (rule_engine)
  -- -------------------------------------------------------------------------
  local bundle = nil
  if bundle_loader and type(bundle_loader.get_current) == "function" then
    bundle = bundle_loader.get_current()
  end

  -- Strip headers referenced as header:* descriptors in the bundle
  local header_descriptors = _M.collect_policy_header_descriptors(bundle)
  -- (strip happens after enforcement, before forwarding)

  local decision = nil
  if rule_engine and type(rule_engine.evaluate) == "function" and bundle then
    local ok, result = pcall(rule_engine.evaluate, rule_engine, request_context, bundle)
    if ok and type(result) == "table" then
      decision = result
    else
      _log_err("rule_engine.evaluate failed err=", tostring(result))
    end
  end

  -- -------------------------------------------------------------------------
  -- 5. Handle reject / shadow
  -- -------------------------------------------------------------------------
  if decision and decision.action == "reject" and decision.mode ~= "shadow" then
    _log_info("pre_flight_rejected reason=", tostring(decision.reason))
    _inc("fairvisor_wrapper_requests_total", {
      action   = "reject",
      provider = provider.prefix:sub(2),
      reason   = decision.reason or "policy",
    })

    local body_str = _M.preflight_error_body(provider, decision.reason, nil)
    ngx.header["Content-Type"]     = "application/json"
    ngx.header["X-Fairvisor-Reason"] = decision.reason or "policy_rejected"
    if decision.headers then
      for k, v in pairs(decision.headers) do
        if type(k) == "string" and v ~= nil then
          ngx.header[k] = v
        end
      end
    end
    ngx.status = 429
    ngx.print(body_str)
    return ngx.exit(429)
  end

  -- -------------------------------------------------------------------------
  -- 6. Allow: rewrite auth headers, strip policy headers, set upstream URL
  -- -------------------------------------------------------------------------
  _log_info("allowing provider=", provider.prefix, " upstream=", upstream_url)
  _inc("fairvisor_wrapper_requests_total", {
    action   = "allow",
    provider = provider.prefix:sub(2),
  })

  -- Remove composite Authorization header
  ngx.req.clear_header("Authorization")

  -- Inject upstream auth header
  if provider.auth_header then
    local auth_val = (provider.auth_prefix or "") .. parsed.upstream_key
    ngx.req.set_header(provider.auth_header, auth_val)
  end

  -- Set provider default headers (e.g. anthropic-version)
  for hdr_name, hdr_val in pairs(provider.default_headers or {}) do
    -- Only inject if client did not already send this header
    if not raw_headers[hdr_name] and not raw_headers[string_gsub(hdr_name, "-", "_")] then
      ngx.req.set_header(hdr_name, hdr_val)
    end
  end

  -- Strip policy-referenced header:* descriptors before forwarding
  _M.strip_policy_headers(header_descriptors)

  -- Set the dynamic upstream URL for nginx proxy_pass
  ngx.var.wrapper_upstream_url = upstream_url

  -- Store provider in ctx for body_filter and logging
  ngx.ctx = ngx.ctx or {}
  ngx.ctx.wrapper_provider      = provider
  ngx.ctx.wrapper_upstream_key  = parsed.upstream_key  -- in-flight only
  ngx.ctx.wrapper_tenant        = parsed.claims and (parsed.claims.sub or parsed.claims.org_id or "")
  ngx.ctx.wrapper_decision      = decision
end

-- get_providers() — returns a copy of the provider list (for tests/inspection).
function _M.get_providers()
  return _PROVIDERS
end

return _M
