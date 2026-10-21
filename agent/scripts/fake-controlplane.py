#!/usr/bin/env python3
"""A stand-in control plane for trying the agent end to end before the real one (controlplane/)
is deployed. Speaks the agent half of the API from protocol/Sources/MaccheriProtocol plus a
minimal host-side signaling WebSocket, and adds test endpoints to queue work:

    POST /test/simulator            queue a simulator session  → {"sessionID": ...}
    POST /test/ci?jit=...           queue a CI job             → {"jobID": ...}
    POST /test/end/<session id>     end a session (DELETE): bye on signaling + endedSessions
    GET  /test/state                everything the agent reported

    fake-controlplane.py [--port 8080] [--image macos-27-xcode-27.2-v1]
"""
import argparse
import base64
import hashlib
import json
import socket
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lock = threading.Condition()
queue = []          # WorkLease JSON objects
state = {"hosts": {}, "heartbeats": 0, "lastCapacity": None, "completed": {}, "reports": {}, "ended": []}
sockets = {}        # session id → host signaling socket
args = None


def now_iso(offset=0):
    return (datetime.now(timezone.utc) + timedelta(seconds=offset)).strftime("%Y-%m-%dT%H:%M:%SZ")


def ws_frame(text):
    data = text.encode()
    header = bytes([0x81])
    if len(data) < 126:
        header += bytes([len(data)])
    else:
        header += bytes([126]) + len(data).to_bytes(2, "big")
    return header + data


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        print("%s %s" % (self.command, self.path.split("?token")[0]), flush=True)

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length) or b"null")

    def reply(self, status, obj=None):
        data = b"" if obj is None else json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        path = self.path.split("?")[0]
        parts = path.strip("/").split("/")
        if path == "/v1/hosts/enroll":
            request = self.body()
            host = str(uuid.uuid4()).upper()
            state["hosts"][host] = request["name"]
            return self.reply(200, {"hostID": host, "agentToken": "agent-" + host})
        if path == "/agent/v1/heartbeat":
            heartbeat = self.body()
            with lock:
                state["heartbeats"] += 1
                state["lastCapacity"] = heartbeat["capacity"]
                ended = list(state["ended"])
            return self.reply(200, {"endedSessions": ended})
        if path == "/agent/v1/work":
            request = self.body()
            with lock:
                deadline = time.time() + 25
                while not queue and time.time() < deadline:
                    lock.wait(deadline - time.time())
                lease = queue.pop(0) if queue and request["freeSlots"] > 0 else None
            return self.reply(200, lease) if lease else self.reply(204)
        if len(parts) == 5 and parts[:3] == ["agent", "v1", "jobs"] and parts[4] == "complete":
            state["completed"][parts[3]] = self.body()
            print("  job", parts[3], state["completed"][parts[3]], flush=True)
            return self.reply(204)
        if len(parts) == 5 and parts[:3] == ["agent", "v1", "sessions"] and parts[4] == "state":
            report = self.body()
            state["reports"].setdefault(parts[3], []).append(report)
            print("  session", parts[3], report, flush=True)
            if parts[3] in state["ended"] and report["state"] in ("starting", "ready"):
                return self.reply(410)
            return self.reply(204)
        if path == "/test/simulator":
            session = str(uuid.uuid4()).upper()
            host = self.headers.get("Host")
            lease = {"simulator": {"_0": {
                "sessionID": session, "image": args.image, "timeoutSeconds": 1800,
                "device": {"deviceType": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                           "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-27-2"},
                "signaling": {"url": "ws://%s/v1/sessions/%s/signal?role=host&token=t" % (host, session),
                              "token": "t", "iceServers": []},
            }}}
            with lock:
                queue.append(lease)
                lock.notify_all()
            return self.reply(200, {"sessionID": session})
        if path == "/test/ci":
            job = str(uuid.uuid4()).upper()
            jit = self.path.split("jit=", 1)[1] if "jit=" in self.path else "not-a-real-jit-config"
            lease = {"ci": {"_0": {"jobID": job, "githubJobID": 1, "repository": "test/fake", "image": args.image,
                                   "jitConfig": jit, "timeoutSeconds": 1800}}}
            with lock:
                queue.append(lease)
                lock.notify_all()
            return self.reply(200, {"jobID": job})
        if len(parts) == 3 and parts[:2] == ["test", "end"]:
            session = parts[2].upper()
            with lock:
                state["ended"].append(session)
            ws = sockets.pop(session, None)
            if ws:
                try:
                    ws.sendall(ws_frame(json.dumps({"bye": {"reason": "user ended the session"}})))
                except OSError:
                    pass
            return self.reply(204)
        self.reply(404, {"error": path})

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/test/state":
            return self.reply(200, state)
        parts = path.strip("/").split("/")
        if len(parts) == 4 and parts[3] == "signal" and self.headers.get("Upgrade", "").lower() == "websocket":
            key = self.headers["Sec-WebSocket-Key"]
            accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept)
            self.end_headers()
            session = parts[2].upper()
            sockets[session] = self.connection
            print("  signaling: host joined", session, flush=True)
            # Hold the connection until the peer closes it; frames from the host are ignored.
            try:
                while self.connection.recv(4096):
                    pass
            except OSError:
                pass
            sockets.pop(session, None)
            print("  signaling: host left", session, flush=True)
            self.close_connection = True
            return
        self.reply(404, {"error": path})


def main():
    global args
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--image", default="macos-27-xcode-27.2-v1")
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print("fake control plane on http://127.0.0.1:%d, image %s" % (args.port, args.image), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
