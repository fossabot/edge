# Feature: Mid-stream truncation at the Edge body_filter layer (Issue #4 AC / UC-18 streaming).
# The edge acts as a reverse proxy with max_completion_tokens=10 and buffer_tokens=1.
# The mock SSE backend emits 3 content events (4 + 5 + 6 = 15 tokens total).
# After event 2 (total 9 ≤ 10), events pass through.
# Event 3 pushes total to 15 > 10 → edge truncates and sends a graceful_close termination.
#
# SSE fixture token accounting (ceil(char_count / 4)):
#   event 1: "one two three"       = 13 chars → 4 tokens  (cumulative: 4,  ≤ 10 → pass)
#   event 2: "four five six seven" = 19 chars → 5 tokens  (cumulative: 9,  ≤ 10 → pass)
#   event 3: "eight nine ten eleven" = 21 chars → 6 tokens (cumulative: 15, > 10 → truncate)

import uuid

import requests


LLM_STREAMING_BODY = (
    b'{"model":"gpt-4","messages":[{"role":"user","content":"hi"}],"stream":true}'
)
LLM_STREAMING_HEADERS = {
    "Content-Type": "application/json",
    "Accept": "text/event-stream",
}


def _parse_sse_events(raw_text):
    """Return list of raw data payloads from SSE text (strips 'data: ' prefix)."""
    events = []
    for line in raw_text.splitlines():
        line = line.strip()
        if line.startswith("data:"):
            payload = line[5:].strip()
            if payload:
                events.append(payload)
    return events


class TestLLMStreamingTruncationE2E:
    """E2E: Edge truncates mid-stream when completion token budget is exhausted (Issue #4 P0)."""

    def test_streaming_request_returns_200(self, edge_llm_streaming_base_url):
        """Streaming request is initially allowed (high TPM policy) and returns 200."""
        key = f"stream-ok-{uuid.uuid4().hex[:8]}"
        r = requests.post(
            f"{edge_llm_streaming_base_url}/v1/chat/completions",
            headers={**LLM_STREAMING_HEADERS, "X-E2E-Key": key},
            data=LLM_STREAMING_BODY,
            timeout=10,
        )
        assert r.status_code == 200, (
            f"Expected 200 for allowed streaming request; got {r.status_code}: {r.text[:200]}"
        )

    def test_streaming_response_contains_first_two_events(self, edge_llm_streaming_base_url):
        """Events 1 and 2 from the backend pass through before truncation."""
        key = f"stream-evts-{uuid.uuid4().hex[:8]}"
        r = requests.post(
            f"{edge_llm_streaming_base_url}/v1/chat/completions",
            headers={**LLM_STREAMING_HEADERS, "X-E2E-Key": key},
            data=LLM_STREAMING_BODY,
            timeout=10,
        )
        assert r.status_code == 200
        body = r.text
        assert "one two three" in body, (
            f"Event 1 content 'one two three' missing from truncated stream; body: {body[:400]}"
        )
        assert "four five six seven" in body, (
            f"Event 2 content 'four five six seven' missing from truncated stream; body: {body[:400]}"
        )

    def test_streaming_response_truncated_before_event_3(self, edge_llm_streaming_base_url):
        """Event 3 content must NOT appear — the edge truncates before forwarding it."""
        key = f"stream-trunc-{uuid.uuid4().hex[:8]}"
        r = requests.post(
            f"{edge_llm_streaming_base_url}/v1/chat/completions",
            headers={**LLM_STREAMING_HEADERS, "X-E2E-Key": key},
            data=LLM_STREAMING_BODY,
            timeout=10,
        )
        assert r.status_code == 200
        assert "eight nine ten eleven" not in r.text, (
            f"Event 3 content should be suppressed by truncation; body: {r.text[:400]}"
        )

    def test_streaming_response_ends_with_done(self, edge_llm_streaming_base_url):
        """Truncated stream ends with 'data: [DONE]' from the termination event."""
        key = f"stream-done-{uuid.uuid4().hex[:8]}"
        r = requests.post(
            f"{edge_llm_streaming_base_url}/v1/chat/completions",
            headers={**LLM_STREAMING_HEADERS, "X-E2E-Key": key},
            data=LLM_STREAMING_BODY,
            timeout=10,
        )
        assert r.status_code == 200
        assert "[DONE]" in r.text, (
            f"Truncated stream must end with [DONE]; body: {r.text[:400]}"
        )

    def test_streaming_response_contains_finish_reason_length(self, edge_llm_streaming_base_url):
        """Termination event includes finish_reason='length' (graceful_close mode)."""
        key = f"stream-fin-{uuid.uuid4().hex[:8]}"
        r = requests.post(
            f"{edge_llm_streaming_base_url}/v1/chat/completions",
            headers={**LLM_STREAMING_HEADERS, "X-E2E-Key": key},
            data=LLM_STREAMING_BODY,
            timeout=10,
        )
        assert r.status_code == 200
        events = _parse_sse_events(r.text)
        finish_events = [e for e in events if e != "[DONE]" and "finish_reason" in e]
        assert finish_events, (
            f"No finish_reason event found in truncated stream; events: {events}"
        )
        assert any("length" in e for e in finish_events), (
            f"Expected finish_reason='length' in graceful_close truncation; "
            f"finish events: {finish_events}"
        )
