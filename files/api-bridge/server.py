#!/usr/bin/env python3
"""OpenAI-compatible bridge server for the Muse API Bridge.

Accepts POST /v1/chat/completions, queues the request as a job file in
~/bridge/inbox/, and waits for the agent's answer to appear in
~/bridge/outbox/ (written by bridge-respond, called by the agent in
the API Bridge side chat after a hook wakes it). Returns the answer
as an OpenAI chat completion. Jobs are serialized: one at a time.
"""
import hashlib
import json
import os
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.path.expanduser("~/bridge")
INBOX = os.path.join(BASE, "inbox")
OUTBOX = os.path.join(BASE, "outbox")
KEYS_FILE = os.path.join(BASE, "keys.json")
TOKEN_FILE = os.path.join(BASE, "token")
_keyring = {"stamp": None, "by_hash": {}}


def _load_keyring():
    """Map of sha256 hex digest -> key name, for request auth.

    Source of truth is keys.json (managed by bridge-key); it is
    reloaded whenever the file changes, so add/revoke apply
    without a server restart. When keys.json does not exist,
    fall back to the legacy single token in ~/bridge/token.
    """
    try:
        stamp = ("keys", os.path.getmtime(KEYS_FILE))
    except OSError:
        try:
            stamp = ("legacy", os.path.getmtime(TOKEN_FILE))
        except OSError:
            stamp = ("legacy", None)
    if _keyring["stamp"] != stamp:
        by_hash = {}
        try:
            if stamp[0] == "keys":
                with open(KEYS_FILE) as f:
                    data = json.load(f)
                by_hash = {e["sha256"]: e["name"] for e in data.get("keys", [])}
            else:
                with open(TOKEN_FILE) as f:
                    legacy = f.read().strip()
                if legacy:
                    by_hash = {hashlib.sha256(legacy.encode()).hexdigest(): "legacy-token"}
        except (OSError, ValueError, KeyError):
            by_hash = _keyring["by_hash"]  # keep the last good keyring
        _keyring["by_hash"] = by_hash
        _keyring["stamp"] = stamp
    return _keyring["by_hash"]
TIMEOUT = int(os.environ.get("BRIDGE_TIMEOUT", "600"))
JOB_LOCK = threading.Lock()


def completion_obj(job_id, model, content):
    return {
        "id": "chatcmpl-" + job_id,
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model or "muse",
        "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": content},
            "finish_reason": "stop",
        }],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print("%s %s" % (self.address_string(), fmt % args), flush=True)

    def _send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        """Return the name of the presented API key, or None."""
        header = self.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            return None
        digest = hashlib.sha256(header[7:].strip().encode()).hexdigest()
        return _load_keyring().get(digest)

    def do_GET(self):
        if self.path == "/health":
            self._send_json(200, {"status": "ok"})
            return
        if self._authorized() is None:
            self._send_json(401, {"error": {"message": "unauthorized",
                                            "type": "auth_error"}})
            return
        if self.path == "/v1/models":
            self._send_json(200, {"object": "list", "data": [{
                "id": "muse", "object": "model",
                "created": 0, "owned_by": "muse-bridge"}]})
            return
        self._send_json(404, {"error": {"message": "not found",
                                        "type": "invalid_request_error"}})

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self._send_json(404, {"error": {"message": "not found",
                                            "type": "invalid_request_error"}})
            return
        key_name = self._authorized()
        if key_name is None:
            self._send_json(401, {"error": {"message": "unauthorized",
                                            "type": "auth_error"}})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(length) or b"{}")
            messages = req["messages"]
            if not isinstance(messages, list) or not messages:
                raise ValueError("messages must be a non-empty list")
        except Exception as e:
            self._send_json(400, {"error": {"message": str(e),
                                            "type": "invalid_request_error"}})
            return

        with JOB_LOCK:
            job_id = uuid.uuid4().hex
            job_path = os.path.join(INBOX, job_id + ".json")
            out_path = os.path.join(OUTBOX, job_id + ".txt")
            job = {"id": job_id, "created": int(time.time()),
                   "request": {"model": req.get("model"),
                               "messages": messages}}
            tmp = job_path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(job, f)
            os.rename(tmp, job_path)
            print("job %s queued key=%s" % (job_id, key_name), flush=True)

            deadline = time.time() + TIMEOUT
            content = None
            while time.time() < deadline:
                if os.path.exists(out_path):
                    with open(out_path) as f:
                        content = f.read()
                    break
                time.sleep(0.25)

            for p in (job_path, out_path):
                try:
                    os.unlink(p)
                except OSError:
                    pass

            if content is None:
                print("job %s timed out" % job_id, flush=True)
                self._send_json(504, {"error": {
                    "message": "agent did not respond in time",
                    "type": "timeout"}})
                return

            print("job %s answered (%d chars)" % (job_id, len(content)),
                  flush=True)
            model = req.get("model") or "muse"
            if req.get("stream"):
                chunk = {
                    "id": "chatcmpl-" + job_id,
                    "object": "chat.completion.chunk",
                    "created": int(time.time()), "model": model,
                    "choices": [{"index": 0,
                                 "delta": {"role": "assistant",
                                           "content": content},
                                 "finish_reason": None}],
                }
                final = {
                    "id": "chatcmpl-" + job_id,
                    "object": "chat.completion.chunk",
                    "created": int(time.time()), "model": model,
                    "choices": [{"index": 0, "delta": {},
                                 "finish_reason": "stop"}],
                }
                body = ("data: %s\n\ndata: %s\n\ndata: [DONE]\n\n"
                        % (json.dumps(chunk), json.dumps(final))).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self._send_json(200, completion_obj(job_id, model, content))


if __name__ == "__main__":
    os.makedirs(INBOX, exist_ok=True)
    os.makedirs(OUTBOX, exist_ok=True)
    port = int(os.environ.get("BRIDGE_PORT", "8080"))
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
