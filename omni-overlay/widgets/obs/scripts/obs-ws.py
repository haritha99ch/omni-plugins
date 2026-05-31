#!/usr/bin/env python3
"""
OBS WebSocket bridge  -  connects to obs-websocket v5 (port 4455).
Emits JSON events to stdout, accepts commands from stdin.

Exit codes:
  0  -  clean exit
  1  -  OBS not reachable (will retry from QML)
"""

import base64
import hashlib
import json
import os
import random
import select
import socket
import struct
import sys
import time
import uuid

OBS_CONFIG_PATH = os.path.expanduser(
    "~/.config/obs-studio/plugin_config/obs-websocket/config.json"
)
POLL_INTERVAL = 2.5   # seconds between status polls
RECONNECT_DELAY = 5.0


# Helpers

def emit(t, data=None):
    print(json.dumps({"type": t, "data": data or {}}), flush=True)


def obs_auth_response(password, salt, challenge):
    secret = base64.b64encode(
        hashlib.sha256((password + salt).encode()).digest()
    ).decode()
    return base64.b64encode(
        hashlib.sha256((secret + challenge).encode()).digest()
    ).decode()


def load_obs_config():
    try:
        with open(OBS_CONFIG_PATH) as f:
            return json.load(f)
    except Exception:
        return {}


# WebSocket (stdlib only)

def _ws_handshake_key():
    return base64.b64encode(bytes(random.randint(0, 255) for _ in range(16))).decode()


def ws_connect(host, port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(5)
    sock.connect((host, port))
    sock.settimeout(None)

    key = _ws_handshake_key()
    sock.sendall((
        f"GET / HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        f"Upgrade: websocket\r\n"
        f"Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n"
        f"\r\n"
    ).encode())

    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("WebSocket handshake: connection closed")
        buf += chunk

    if b" 101 " not in buf:
        raise ConnectionError(f"WebSocket handshake failed: {buf[:200]}")
    return sock


def ws_send(sock, data):
    payload = json.dumps(data).encode()
    length = len(payload)
    mask = bytes(random.randint(0, 255) for _ in range(4))

    if length < 126:
        header = bytes([0x81, 0x80 | length])
    elif length < 65536:
        header = bytes([0x81, 0x80 | 126]) + struct.pack(">H", length)
    else:
        header = bytes([0x81, 0x80 | 127]) + struct.pack(">Q", length)

    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(header + mask + masked)


def _recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def ws_recv(sock):
    hdr = _recv_exact(sock, 2)
    if hdr is None:
        return None

    opcode = hdr[0] & 0x0f
    masked = (hdr[1] & 0x80) != 0
    length = hdr[1] & 0x7f

    if length == 126:
        ext = _recv_exact(sock, 2)
        if ext is None: return None
        length = struct.unpack(">H", ext)[0]
    elif length == 127:
        ext = _recv_exact(sock, 8)
        if ext is None: return None
        length = struct.unpack(">Q", ext)[0]

    if masked:
        mask = _recv_exact(sock, 4)
        if mask is None: return None

    payload = _recv_exact(sock, length)
    if payload is None:
        return None

    if masked:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))

    if opcode == 8:   # Close
        return None
    if opcode == 9:   # Ping -> Pong
        ws_send_pong(sock)
        return "ping"
    if opcode == 1:   # Text
        return json.loads(payload.decode())
    return "binary"


def ws_send_pong(sock):
    sock.sendall(bytes([0x8A, 0x80]) + bytes(4))  # masked pong


# OBS protocol

_pending = {}  # request_id -> response (or None while waiting)

def obs_request(sock, req_type, data=None):
    rid = str(uuid.uuid4())[:8]
    msg = {"op": 6, "d": {"requestType": req_type, "requestId": rid, "requestData": data or {}}}
    ws_send(sock, msg)
    return rid


def obs_request_sync(sock, req_type, data=None, timeout=3.0):
    """Send request and wait for response, queuing other messages."""
    rid = obs_request(sock, req_type, data)
    deadline = time.time() + timeout
    while time.time() < deadline:
        remaining = deadline - time.time()
        r, _, _ = select.select([sock], [], [], max(0.1, remaining))
        if not r:
            break
        msg = ws_recv(sock)
        if msg is None:
            return None
        if isinstance(msg, dict) and msg.get("op") == 7:
            d = msg.get("d", {})
            if d.get("requestId") == rid:
                return d.get("responseData", {})
            _pending[d.get("requestId")] = d.get("responseData", {})
    return None


def get_status(sock):
    rec  = obs_request_sync(sock, "GetRecordStatus")
    stm  = obs_request_sync(sock, "GetStreamStatus")
    rpl  = obs_request_sync(sock, "GetReplayBufferStatus")
    if rec is None:
        return None
    return {
        "recording":       rec.get("outputActive", False),
        "streaming":       stm.get("outputActive", False) if stm else False,
        "replay_buffer":   rpl.get("outputActive", False) if rpl else False,
        "record_ms":       rec.get("outputDuration", 0),
        "stream_ms":       stm.get("outputDuration", 0) if stm else 0,
    }


# Main loop

def run():
    cfg = load_obs_config()
    port     = cfg.get("server_port", 4455)
    password = cfg.get("server_password", "")
    auth_req = cfg.get("auth_required", False)

    # Connect
    try:
        sock = ws_connect("127.0.0.1", port)
    except Exception as e:
        emit("obs_error", {"message": f"Cannot connect to OBS: {e}"})
        sys.exit(1)

    # OBS Hello handshake (op=0)
    hello = ws_recv(sock)
    if not isinstance(hello, dict) or hello.get("op") != 0:
        emit("obs_error", {"message": "OBS WebSocket Hello not received"})
        sys.exit(1)

    d = hello.get("d", {})
    rpc_version = d.get("rpcVersion", 1)
    auth_info   = d.get("authentication")

    identify = {"op": 1, "d": {"rpcVersion": rpc_version}}
    if auth_info and auth_req and password:
        identify["d"]["authentication"] = obs_auth_response(
            password, auth_info["salt"], auth_info["challenge"]
        )
    ws_send(sock, identify)

    # Identified (op=2)
    ident = ws_recv(sock)
    if not isinstance(ident, dict) or ident.get("op") != 2:
        emit("obs_error", {"message": "OBS authentication failed"})
        sys.exit(1)

    emit("obs_connected")

    last_poll = 0.0

    while True:
        now = time.time()
        wait = max(0.0, POLL_INTERVAL - (now - last_poll))

        try:
            r, _, _ = select.select([sock, sys.stdin], [], [], wait)
        except (OSError, ValueError):
            break

        # stdin command
        if sys.stdin in r:
            line = sys.stdin.readline()
            if not line:
                continue
            line = line.strip()
            if not line:
                continue
            try:
                cmd = json.loads(line)
                action = cmd.get("action", "")
                if action == "toggle_record":
                    status = obs_request_sync(sock, "GetRecordStatus")
                    if status is not None:
                        obs_request_sync(sock, "StopRecord" if status.get("outputActive") else "StartRecord")
                elif action == "toggle_stream":
                    status = obs_request_sync(sock, "GetStreamStatus")
                    if status is not None:
                        obs_request_sync(sock, "StopStream" if status.get("outputActive") else "StartStream")
                elif action == "toggle_replay":
                    status = obs_request_sync(sock, "GetReplayBufferStatus")
                    if status is not None:
                        obs_request_sync(sock, "StopReplayBuffer" if status.get("outputActive") else "StartReplayBuffer")
                elif action == "save_replay":
                    obs_request_sync(sock, "SaveReplayBuffer")
            except Exception:
                pass

        # WebSocket message from OBS (events, responses)
        if sock in r:
            msg = ws_recv(sock)
            if msg is None:
                break  # disconnected
            # handle event updates inline (don't need them beyond poll)

        # Poll status
        if time.time() - last_poll >= POLL_INTERVAL:
            last_poll = time.time()
            status = get_status(sock)
            if status is None:
                break
            emit("obs_status", status)

    emit("obs_disconnected")


if __name__ == "__main__":
    try:
        run()
    except Exception as e:
        emit("obs_error", {"message": str(e)})
        sys.exit(1)
