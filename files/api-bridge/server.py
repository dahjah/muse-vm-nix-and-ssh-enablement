#!/usr/bin/env python3
"""OpenAI-compatible bridge server for the Muse API Bridge.

Accepts POST /v1/chat/completions, queues the request as a job file in
~/bridge/inbox/, and waits for the agent's answer (written to
~/bridge/outbox/ by bridge-respond, or posted through the session
endpoints by bridge-reply, after a hook wakes the agent in the API
Bridge side chat). Returns the answer as an OpenAI chat completion.

Tool calls and sessions: when a request carries a "tools" list, the
tools are forwarded in the job file. The agent may answer with a JSON
envelope, {"tool_calls": [{"name": ..., "arguments": {...}}]}, which
this server translates into a real tool_calls response. If that
answer arrives through bridge-reply, a session is kept open: the
client's follow-up request (same history plus the tool results) is
routed straight to the still-running agent turn through the session
endpoints instead of a new job file and a new wake. A reply that is
plain text ends the session, as does the agent closing it or letting
it idle past the session timeout; any request that cannot be routed
to a live session takes the job-file path, so a dead session degrades
to today's behavior rather than failing. One session at a time, and
job-file requests are serialized as before.
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
SESSIONS_DIR = os.path.join(BASE, "sessions")
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
NEXT_WAIT = int(os.environ.get("BRIDGE_NEXT_WAIT", "55"))
SESSION_IDLE = int(os.environ.get("BRIDGE_SESSION_IDLE", "300"))
PORT = int(os.environ.get("BRIDGE_PORT", "8080"))
JOB_LOCK = threading.Lock()

# ---------------------------------------------------------------------
# Sessions
#
# A session belongs to one agent turn. It is pre-created (state
# "awaiting_first") when a job-file request carries tools and no other
# session exists; it becomes "live" when the first answer arrives via
# /session/<sid>/reply as a tool_calls envelope. While live, a client
# request whose messages strictly continue the session's history is
# routed to the agent's bridge-next poll instead of a new job file.
# ---------------------------------------------------------------------

_sessions = {}
_sessions_lock = threading.Lock()


class Ticket:
    """One client request awaiting one agent answer."""

    def __init__(self, req, key_name):
        self.id = uuid.uuid4().hex
        self.req = req
        self.key_name = key_name
        self.reply = None       # raw payload string from the agent
        self.reply_via = None   # "session" or "outbox"
        self.rendered = None    # (msg, finish) built once by /reply
        self.event = threading.Event()


class Session:
    def __init__(self, sid, secret, key_name):
        self.sid = sid
        self.secret = secret
        self.key_name = key_name
        self.state = "awaiting_first"   # awaiting_first | live | closed
        self.created = time.time()
        self.last_activity = time.time()
        self.cond = threading.Condition()
        self.first_ticket = None        # Ticket answered via job/outbox
        self.pending_ticket = None      # routed, waiting for bridge-next
        self.current_ticket = None      # fetched by agent, awaiting reply
        self.last_messages = None       # messages of last answered request
        self.last_assistant_msg = None  # exact assistant message emitted
        self.steps = 0

    def touch(self):
        self.last_activity = time.time()


def _session_file(sid):
    return os.path.join(SESSIONS_DIR, sid + ".session")


def _write_session_file(sess):
    os.makedirs(SESSIONS_DIR, exist_ok=True)
    tmp = _session_file(sess.sid) + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"secret": sess.secret, "port": PORT}, f)
    os.chmod(tmp, 0o600)
    os.rename(tmp, _session_file(sess.sid))


def _close_session(sess, reason):
    """Mark a session closed and wake anything waiting on it."""
    with sess.cond:
        if sess.state == "closed":
            return
        sess.state = "closed"
        sess.cond.notify_all()
    with _sessions_lock:
        _sessions.pop(sess.sid, None)
    try:
        os.unlink(_session_file(sess.sid))
    except OSError:
        pass
    print("session %s closed (%s) after %d step(s)"
          % (sess.sid[:8], reason, sess.steps), flush=True)


def _reap_sessions():
    now = time.time()
    with _sessions_lock:
        stale = [s for s in _sessions.values()
                 if s.state != "closed"
                 and now - s.last_activity > SESSION_IDLE]
    for sess in stale:
        _close_session(sess, "idle timeout")


def _live_session():
    with _sessions_lock:
        for sess in _sessions.values():
            if sess.state in ("awaiting_first", "live"):
                return sess
    return None


def _norm_msg(m):
    """A message normalized the way a client may echo it back: some
    clients (opencode does) turn a null content into an empty
    string, or drop the field. Compare with that tolerance;
    everything else (roles, tool call ids, names, arguments) must
    match exactly."""
    if not isinstance(m, dict):
        return m
    m = dict(m)
    if m.get("content") is None:
        m["content"] = ""
    return m


def _msgs_equal(a, b):
    return (len(a) == len(b)
            and all(_norm_msg(x) == _norm_msg(y) for x, y in zip(a, b)))


def _continues(sess, messages):
    """True when `messages` is the session's history plus the
    assistant tool_calls message this server emitted (compared
    with _norm_msg tolerance), plus only tool-role messages
    after it."""
    if sess.state != "live" or sess.last_messages is None:
        return False
    if sess.last_assistant_msg is None:
        return False
    prev = sess.last_messages
    if len(messages) <= len(prev):
        return False
    if not _msgs_equal(messages[:len(prev)], prev):
        return False
    if _norm_msg(messages[len(prev)]) != _norm_msg(sess.last_assistant_msg):
        return False
    rest = messages[len(prev) + 1:]
    if not rest:
        return False
    return all(m.get("role") == "tool" for m in rest)


def parse_envelope(payload):
    """Parse an agent reply as a tool_calls envelope.

    Returns a list of {"name": str, "arguments": dict-or-str} when the
    payload is exactly such an envelope, else None (plain text)."""
    text = payload.strip()
    if not text.startswith("{"):
        return None
    try:
        obj = json.loads(text)
    except ValueError:
        return None
    if not isinstance(obj, dict):
        return None
    calls = obj.get("tool_calls")
    if not isinstance(calls, list) or not calls:
        return None
    out = []
    for call in calls:
        if not isinstance(call, dict):
            return None
        name = call.get("name")
        args = call.get("arguments")
        if not isinstance(name, str) or not name:
            return None
        if not isinstance(args, (dict, str)):
            return None
        out.append({"name": name, "arguments": args})
    return out


def build_reply(req, payload):
    """Translate a raw agent payload into (message, finish_reason,
    assistant_msg), where assistant_msg is the exact message dict the
    client is expected to echo back in a continuing request."""
    calls = parse_envelope(payload)
    model = req.get("model") or "muse"
    if calls is None:
        msg = {"role": "assistant", "content": payload}
        return msg, "stop"
    tool_calls = []
    for call in calls:
        args = call["arguments"]
        if not isinstance(args, str):
            args = json.dumps(args)
        tool_calls.append({
            "id": "call_" + uuid.uuid4().hex[:24],
            "type": "function",
            "function": {"name": call["name"], "arguments": args},
        })
    msg = {"role": "assistant", "content": None, "tool_calls": tool_calls}
    return msg, "tool_calls"


def completion_obj(job_id, req, msg, finish):
    return {
        "id": "chatcmpl-" + job_id,
        "object": "chat.completion",
        "created": int(time.time()),
        "model": req.get("model") or "muse",
        "choices": [{
            "index": 0,
            "message": msg,
            "finish_reason": finish,
        }],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }


def stream_body(job_id, req, msg, finish, payload):
    model = req.get("model") or "muse"
    if finish == "tool_calls":
        delta = {"role": "assistant", "tool_calls": [
            {"index": i, "id": tc["id"], "type": "function",
             "function": tc["function"]}
            for i, tc in enumerate(msg["tool_calls"])]}
    else:
        delta = {"role": "assistant", "content": payload}
    chunk = {
        "id": "chatcmpl-" + job_id,
        "object": "chat.completion.chunk",
        "created": int(time.time()), "model": model,
        "choices": [{"index": 0, "delta": delta, "finish_reason": None}],
    }
    final = {
        "id": "chatcmpl-" + job_id,
        "object": "chat.completion.chunk",
        "created": int(time.time()), "model": model,
        "choices": [{"index": 0, "delta": {}, "finish_reason": finish}],
    }
    return ("data: %s\n\ndata: %s\n\ndata: [DONE]\n\n"
            % (json.dumps(chunk), json.dumps(final))).encode()


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

    def _read_json_body(self):
        length = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(length) or b"{}")

    # ------------------------- client API -------------------------

    def do_GET(self):
        if self.path == "/health":
            self._send_json(200, {"status": "ok"})
            return
        if self.path.startswith("/session/"):
            self._session_next()
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
        if self.path.startswith("/session/"):
            if self.path.endswith("/reply"):
                self._session_reply()
            elif self.path.endswith("/close"):
                self._session_close()
            else:
                self._send_json(404, {"error": {"message": "not found",
                                                "type": "invalid_request_error"}})
            return
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
            req = self._read_json_body()
            messages = req["messages"]
            if not isinstance(messages, list) or not messages:
                raise ValueError("messages must be a non-empty list")
        except Exception as e:
            self._send_json(400, {"error": {"message": str(e),
                                            "type": "invalid_request_error"}})
            return

        _reap_sessions()

        # Session continuation: route to the live agent turn when this
        # request strictly continues the session's history.
        sess = _live_session()
        if sess is not None and _continues(sess, messages):
            if self._serve_via_session(sess, req, key_name):
                return
            # Session died mid-wait: fall through to the job path.

        self._serve_via_job(req, key_name)

    def _respond_completion(self, ticket, payload, rendered=None):
        req = ticket.req
        msg, finish = rendered or build_reply(req, payload)
        if req.get("stream"):
            body = stream_body(ticket.id, req, msg, finish, payload)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self._send_json(200, completion_obj(ticket.id, req, msg, finish))
        return msg, finish

    def _serve_via_session(self, sess, req, key_name):
        """Hand a continuing request to the live agent turn and wait
        for its answer. Returns False when the session died first, in
        which case the caller falls back to the job path."""
        ticket = Ticket(req, key_name)
        with sess.cond:
            if sess.state != "live" or sess.pending_ticket is not None \
                    or sess.current_ticket is not None:
                return False
            sess.pending_ticket = ticket
            sess.touch()
            sess.cond.notify_all()
        print("request routed to session %s key=%s"
              % (sess.sid[:8], key_name), flush=True)
        deadline = time.time() + TIMEOUT
        while time.time() < deadline:
            if ticket.event.wait(0.25):
                break
            if sess.state == "closed" and ticket.reply is None:
                return False
        if ticket.reply is None:
            return False
        payload = ticket.reply
        msg, finish = self._respond_completion(ticket, payload,
                                               ticket.rendered)
        with sess.cond:
            sess.steps += 1
            sess.last_messages = req["messages"]
            sess.last_assistant_msg = msg if finish == "tool_calls" else None
            sess.current_ticket = None
            sess.touch()
        print("session %s step answered (%s, %d chars)"
              % (sess.sid[:8], finish, len(payload)), flush=True)
        if finish != "tool_calls":
            _close_session(sess, "final answer")
        return True

    def _serve_via_job(self, req, key_name):
        messages = req["messages"]
        with JOB_LOCK:
            job_id = uuid.uuid4().hex
            ticket = Ticket(req, key_name)
            ticket.id = job_id

            has_tools = isinstance(req.get("tools"), list) \
                and len(req["tools"]) > 0
            sess = None
            if has_tools and _live_session() is None:
                sess = Session(job_id, uuid.uuid4().hex, key_name)
                sess.first_ticket = ticket
                with _sessions_lock:
                    _sessions[job_id] = sess
                _write_session_file(sess)

            job_req = {"model": req.get("model"), "messages": messages}
            if has_tools:
                job_req["tools"] = req["tools"]
                if "tool_choice" in req:
                    job_req["tool_choice"] = req["tool_choice"]
            job_req["session_available"] = sess is not None
            job = {"id": job_id, "created": int(time.time()),
                   "request": job_req}
            job_path = os.path.join(INBOX, job_id + ".json")
            out_path = os.path.join(OUTBOX, job_id + ".txt")
            tmp = job_path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(job, f)
            os.rename(tmp, job_path)
            print("job %s queued key=%s" % (job_id, key_name), flush=True)

            deadline = time.time() + TIMEOUT
            content = None
            via = None
            while time.time() < deadline:
                if ticket.event.is_set():
                    content = ticket.reply
                    via = "session"
                    break
                if os.path.exists(out_path):
                    with open(out_path) as f:
                        content = f.read()
                    via = "outbox"
                    break
                time.sleep(0.25)

            for p in (job_path, out_path):
                try:
                    os.unlink(p)
                except OSError:
                    pass

            if content is None:
                print("job %s timed out" % job_id, flush=True)
                if sess is not None:
                    _close_session(sess, "first answer timed out")
                self._send_json(504, {"error": {
                    "message": "agent did not respond in time",
                    "type": "timeout"}})
                return

            print("job %s answered (%d chars)" % (job_id, len(content)),
                  flush=True)
            rendered = ticket.rendered if via == "session" else None
            msg, finish = self._respond_completion(ticket, content,
                                                   rendered)

            if sess is not None:
                if via == "session" and finish == "tool_calls":
                    pass  # /reply already made the session live
                else:
                    _close_session(sess, "no session (one-shot answer)")

    # ------------------------- session API ------------------------
    # Called by the agent's bridge-session tools, from the VM only.
    # The per-session secret (in ~/bridge/sessions/<sid>.session,
    # mode 600) is the credential; it never leaves the machine.

    def _session_from_path(self):
        parts = self.path.split("/")
        # ["", "session", "<sid>", "<action>"]
        if len(parts) != 4:
            return None
        sid = parts[2]
        with _sessions_lock:
            return _sessions.get(sid)

    def _session_secret_ok(self, sess, secret):
        return sess is not None and secret is not None \
            and sess.secret == secret

    def _session_reply(self):
        sess = self._session_from_path()
        try:
            body = self._read_json_body()
        except Exception:
            self._send_json(400, {"error": {"message": "bad json",
                                            "type": "invalid_request_error"}})
            return
        if not self._session_secret_ok(sess, body.get("secret")):
            self._send_json(404, {"error": {"message": "no such session",
                                            "type": "invalid_request_error"}})
            return
        _reap_sessions()
        payload = body.get("reply")
        if not isinstance(payload, str):
            self._send_json(400, {"error": {"message": "reply must be a string",
                                            "type": "invalid_request_error"}})
            return
        with sess.cond:
            sess.touch()
            if sess.state == "awaiting_first":
                ticket = sess.first_ticket
            else:
                ticket = sess.current_ticket
            if ticket is None or ticket.reply is not None:
                self._send_json(409, {"error": {
                    "message": "no pending request for this session",
                    "type": "conflict"}})
                return
            ticket.reply = payload
            ticket.reply_via = "session"
            msg, finish = build_reply(ticket.req, payload)
            ticket.rendered = (msg, finish)
            ticket.event.set()
            if sess.state == "awaiting_first" and finish == "tool_calls":
                # Go live here, not in the job handler: the agent may
                # call bridge-next the moment this reply returns, and
                # it must already find a live session.
                sess.state = "live"
                sess.steps = 1
                sess.last_messages = ticket.req["messages"]
                sess.last_assistant_msg = msg
                sess.first_ticket = None
                print("session %s live key=%s"
                      % (sess.sid[:8], sess.key_name), flush=True)
            sess.cond.notify_all()
        live = parse_envelope(payload) is not None
        self._send_json(200, {"status": "delivered",
                              "session": "live" if live else "closed"})

    def _session_next(self):
        sess = self._session_from_path()
        from urllib.parse import urlparse, parse_qs
        secret = parse_qs(urlparse(self.path).query).get("secret", [None])[0]
        if not self._session_secret_ok(sess, secret):
            self._send_json(404, {"error": {"message": "no such session",
                                            "type": "invalid_request_error"}})
            return
        _reap_sessions()
        deadline = time.time() + NEXT_WAIT
        with sess.cond:
            sess.touch()
            while True:
                if sess.state == "closed":
                    self._send_json(410, {"status": "closed"})
                    return
                if sess.state == "awaiting_first":
                    self._send_json(409, {"status": "not_started"})
                    return
                if sess.pending_ticket is not None:
                    ticket = sess.pending_ticket
                    sess.pending_ticket = None
                    sess.current_ticket = ticket
                    sess.touch()
                    self._send_json(200, {"status": "request",
                                          "request": ticket.req})
                    return
                remaining = deadline - time.time()
                if remaining <= 0:
                    self._send_json(200, {"status": "none"})
                    return
                sess.cond.wait(min(remaining, 1.0))

    def _session_close(self):
        sess = self._session_from_path()
        try:
            body = self._read_json_body()
        except Exception:
            body = {}
        if not self._session_secret_ok(sess, body.get("secret")):
            self._send_json(404, {"error": {"message": "no such session",
                                            "type": "invalid_request_error"}})
            return
        _close_session(sess, "agent closed it")
        self._send_json(200, {"status": "closed"})


if __name__ == "__main__":
    os.makedirs(INBOX, exist_ok=True)
    os.makedirs(OUTBOX, exist_ok=True)
    os.makedirs(SESSIONS_DIR, exist_ok=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
