# Feature: OpenAI wire contract for LLM rate limit rejections (Issue #4 AC / UC-16).
# When the edge rejects a request due to tpm_exceeded, the 429 response body must be
# an OpenAI-compatible JSON error: {"error":{"type":"rate_limit_error","code":"rate_limit_exceeded",...}}
#
# Policy: decision_service mode, token_bucket_llm with header_hint estimator, TPM=500.
# Trigger: X-Token-Estimate: 600 → estimated_total = 610 > burst(500) → tpm_exceeded.

import uuid

import pytest
import requests


def _reject_request(base_url, limit_key, token_estimate=600):
    """Send a decision request that exceeds the TPM budget and returns the 429 response."""
    return requests.post(
        f"{base_url}/v1/decision",
        headers={
            "X-Original-Method": "POST",
            "X-Original-URI": "/v1/chat/completions",
            "X-E2E-Key": limit_key,
            "X-Token-Estimate": str(token_estimate),
        },
        timeout=5,
    )


class TestLLMOpenAIContractE2E:
    """E2E: tpm_exceeded rejection produces OpenAI-compatible JSON error body (Issue #4 P0)."""

    def test_tpm_exceeded_returns_429(self, edge_llm_openai_contract_base_url):
        """Sending X-Token-Estimate exceeding burst_tokens yields 429."""
        key = f"openai-contract-{uuid.uuid4().hex[:8]}"
        r = _reject_request(edge_llm_openai_contract_base_url, key)
        assert r.status_code == 429, (
            f"Expected 429 for over-limit token estimate; got {r.status_code}; body: {r.text[:200]}"
        )

    def test_tpm_exceeded_body_is_openai_json(self, edge_llm_openai_contract_base_url):
        """429 response body is valid JSON with OpenAI error structure."""
        key = f"openai-body-{uuid.uuid4().hex[:8]}"
        r = _reject_request(edge_llm_openai_contract_base_url, key)
        assert r.status_code == 429

        try:
            body = r.json()
        except Exception as exc:
            pytest.fail(
                f"429 body is not valid JSON: {exc}; raw body: {r.text[:300]}; "
                f"Content-Type: {r.headers.get('Content-Type')}"
            )

        assert "error" in body, f"Missing 'error' key in response: {body}"
        error = body["error"]
        assert error.get("type") == "rate_limit_error", (
            f"Expected error.type='rate_limit_error'; got: {error}"
        )
        assert error.get("code") == "rate_limit_exceeded", (
            f"Expected error.code='rate_limit_exceeded'; got: {error}"
        )
        assert "message" in error, f"Missing 'message' in error object: {error}"

    def test_tpm_exceeded_content_type_is_json(self, edge_llm_openai_contract_base_url):
        """429 response sets Content-Type: application/json."""
        key = f"openai-ctype-{uuid.uuid4().hex[:8]}"
        r = _reject_request(edge_llm_openai_contract_base_url, key)
        assert r.status_code == 429
        content_type = r.headers.get("Content-Type", "")
        assert "application/json" in content_type, (
            f"Expected Content-Type: application/json; got: {content_type}"
        )

    def test_tpm_exceeded_includes_rate_limit_headers(self, edge_llm_openai_contract_base_url):
        """429 response for tpm_exceeded still includes RateLimit-* and Retry-After headers."""
        key = f"openai-hdrs-{uuid.uuid4().hex[:8]}"
        r = _reject_request(edge_llm_openai_contract_base_url, key)
        assert r.status_code == 429
        for header in ("RateLimit-Limit", "RateLimit-Remaining", "Retry-After"):
            assert header in r.headers, (
                f"Missing '{header}' in 429 headers; headers: {dict(r.headers)}"
            )

    def test_tpm_exceeded_error_message_contains_reason(self, edge_llm_openai_contract_base_url):
        """The error.message field identifies the rejection reason."""
        key = f"openai-msg-{uuid.uuid4().hex[:8]}"
        r = _reject_request(edge_llm_openai_contract_base_url, key)
        assert r.status_code == 429
        body = r.json()
        message = body["error"]["message"]
        assert "tpm_exceeded" in message or "rate limit" in message.lower(), (
            f"Error message should reference tpm_exceeded or rate limit; got: {message}"
        )
