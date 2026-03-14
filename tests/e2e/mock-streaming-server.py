#!/usr/bin/env python3
"""Minimal mock streaming backend for e2e tests.

Serves a static SSE fixture for any POST request (simulates an LLM streaming endpoint).
GET / returns 200 ok (used by healthcheck).

SSE token accounting (ceil(char_count / 4), buffer_tokens=1, max_completion_tokens=10):
  event 1: "one two three"        = 13 chars -> 4 tokens  (cumulative 4,  <= 10 pass)
  event 2: "four five six seven"  = 19 chars -> 5 tokens  (cumulative 9,  <= 10 pass)
  event 3: "eight nine ten eleven"= 21 chars -> 6 tokens  (cumulative 15, >  10 truncate)
"""
from http.server import BaseHTTPRequestHandler, HTTPServer

_SSE_BODY = (
    b'data: {"id":"sse1","object":"chat.completion.chunk",'
    b'"choices":[{"index":0,"delta":{"role":"assistant","content":"one two three"}}]}\n\n'
    b'data: {"id":"sse2","object":"chat.completion.chunk",'
    b'"choices":[{"index":0,"delta":{"content":"four five six seven"}}]}\n\n'
    b'data: {"id":"sse3","object":"chat.completion.chunk",'
    b'"choices":[{"index":0,"delta":{"content":"eight nine ten eleven"}}]}\n\n'
    b'data: [DONE]\n\n'
)


class _Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        self.wfile.write(_SSE_BODY)
        self.wfile.flush()

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, fmt, *args):  # suppress per-request logs
        pass


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 80), _Handler).serve_forever()
