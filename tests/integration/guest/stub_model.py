#!/usr/bin/python3
"""OpenAI-compatible stub. Requests one bash tool call, then echoes its output."""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

COMMAND = "echo harness-tool-ran > harness-proof.txt; id -un; pwd"


def chunk(delta, finish=None):
    choice = {"index": 0, "delta": delta, "finish_reason": finish}
    return {"id": "stub", "object": "chat.completion.chunk", "model": "stub-1", "choices": [choice]}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        last = request["messages"][-1]
        if last["role"] == "tool":
            content = last["content"]
            text = content if isinstance(content, str) else "".join(p.get("text", "") for p in content)
            chunks = [chunk({"role": "assistant", "content": "stub-saw: " + text.replace("\n", " ")}), chunk({}, "stop")]
        else:
            call = {
                "index": 0,
                "id": "call_1",
                "type": "function",
                "function": {"name": "bash", "arguments": json.dumps({"command": COMMAND})},
            }
            chunks = [chunk({"role": "assistant", "tool_calls": [call]}), chunk({}, "tool_calls")]
        body = "".join(f"data: {json.dumps(c)}\n\n" for c in chunks) + "data: [DONE]\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", 18080), Handler).serve_forever()
