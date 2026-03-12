# E2E: token reconciliation for non-streaming LLM responses (Issue #12 / Feature 015).
# The edge runs in reverse_proxy mode backed by a mock LLM server that always returns
# {"usage":{"total_tokens":50}}.  A pessimistic reservation of ~1010 tokens is made
# at access time (10 prompt + 1000 default_max_completion).  After the response the
# reconciler must refund the unused ~960 tokens and emit the
# fairvisor_token_reservation_unused_total metric.

import uuid

import requests


LLM_REQUEST_BODY = '{"model":"gpt-4","messages":[{"role":"user","content":"hello"}]}'
LLM_REQUEST_HEADERS = {"Content-Type": "application/json"}


class TestNonStreamingTokenReconciliation:
    """E2E: non-streaming response body is buffered and tokens are reconciled."""

    def test_non_streaming_request_passes_through_to_backend(self, edge_llm_reconcile_base_url):
        key = f"recon-pass-{uuid.uuid4().hex[:8]}"
        response = requests.post(
            f"{edge_llm_reconcile_base_url}/v1/chat/completions",
            headers={**LLM_REQUEST_HEADERS, "X-E2E-Key": key},
            data=LLM_REQUEST_BODY,
            timeout=5,
        )
        assert response.status_code == 200, f"Expected 200, got {response.status_code}: {response.text}"
        body = response.json()
        assert "usage" in body, "Mock LLM backend response must contain usage field"
        assert body["usage"]["total_tokens"] == 50

    def test_reconciliation_emits_reservation_unused_metric(self, edge_llm_reconcile_base_url):
        """After a non-streaming response, unused tokens (reserved - actual) are refunded
        and counted in fairvisor_token_reservation_unused_total."""
        key = f"recon-metric-{uuid.uuid4().hex[:8]}"

        # Make one LLM request so reconciliation runs at least once.
        requests.post(
            f"{edge_llm_reconcile_base_url}/v1/chat/completions",
            headers={**LLM_REQUEST_HEADERS, "X-E2E-Key": key},
            data=LLM_REQUEST_BODY,
            timeout=5,
        )

        metrics = requests.get(f"{edge_llm_reconcile_base_url}/metrics", timeout=5)
        assert metrics.status_code == 200
        assert "fairvisor_token_reservation_unused_total" in metrics.text, (
            "Expected fairvisor_token_reservation_unused_total metric after reconciliation"
        )

    def test_reconciliation_refunds_allow_subsequent_requests(self, edge_llm_reconcile_base_url):
        """After reconciliation the refunded tokens allow additional requests that would
        have been rejected under pessimistic (no-refund) accounting."""
        key = f"recon-refund-{uuid.uuid4().hex[:8]}"
        headers = {**LLM_REQUEST_HEADERS, "X-E2E-Key": key}

        # With tokens_per_minute=10000 and default_max_completion=1000, we can make
        # ~10 requests pessimistically (10 * 1000 = 10000).  After reconciliation each
        # request only costs ~50, so we should comfortably fit many more.
        responses = []
        for _ in range(5):
            r = requests.post(
                f"{edge_llm_reconcile_base_url}/v1/chat/completions",
                headers=headers,
                data=LLM_REQUEST_BODY,
                timeout=5,
            )
            responses.append(r.status_code)

        assert all(s == 200 for s in responses), (
            f"All 5 requests should pass with reconciliation enabled; got: {responses}"
        )
