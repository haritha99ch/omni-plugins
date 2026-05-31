#!/usr/bin/env python3
"""
Discord RPC bridge  -  voice state + controls via local IPC with OAuth.

Requires a registered Discord application (client_id + client_secret from
https://discord.com/developers/applications, RPC feature enabled).

Exit codes:
  0   -  clean disconnect
  1   -  Discord not running
  2   -  fatal protocol error
"""

import atexit
import collections
import datetime
import json
import os
import select
import socket
import struct
import sys
import time
import uuid
import urllib.request
import urllib.parse

_logfile = open("/tmp/discord-ipc-debug.log", "a")
atexit.register(_logfile.close)

def _log(*args):
    msg = " ".join(str(a) for a in args)
    _logfile.write(f"[{datetime.datetime.now().isoformat()}] {msg}\n")
    _logfile.flush()

SOCKET_NAMES = ["discord-ipc-0", "discord-ipc-1", "discord-ipc-2"]
TOKEN_PATH  = os.path.expanduser("~/.config/omni-overlay/discord/auth.json")
CONFIG_PATH = os.path.expanduser("~/.config/omni-overlay/discord/config.json")
SCOPES = ["rpc", "rpc.voice.write"]

_event_queue = collections.deque(maxlen=64)


def find_socket():
    runtime = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    for name in SOCKET_NAMES:
        path = os.path.join(runtime, name)
        if os.path.exists(path):
            return path
    return None


def send_msg(sock, op, payload):
    data = json.dumps(payload).encode()
    sock.sendall(struct.pack("<II", op, len(data)) + data)


def recv_msg(sock):
    header = b""
    while len(header) < 8:
        chunk = sock.recv(8 - len(header))
        if not chunk:
            return None, None
        header += chunk
    op, length = struct.unpack("<II", header)
    data = b""
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            return None, None
        data += chunk
    return op, json.loads(data)


def send_cmd(sock, cmd, args=None):
    """Send a command and return its response, queuing any events that arrive first."""
    nonce = str(uuid.uuid4())[:8]
    send_msg(sock, 1, {"cmd": cmd, "args": args or {}, "nonce": nonce})
    while True:
        op, msg = recv_msg(sock)
        if msg is None:
            return op, msg
        if msg.get("evt") and msg.get("nonce") != nonce:
            _event_queue.append((op, msg))
        else:
            return op, msg


def subscribe(sock, evt, args=None):
    """Subscribe to an event, queuing any unsolicited events that arrive first."""
    nonce = str(uuid.uuid4())[:8]
    send_msg(sock, 1, {"cmd": "SUBSCRIBE", "evt": evt, "args": args or {}, "nonce": nonce})
    while True:
        op, msg = recv_msg(sock)
        if msg is None:
            return op, msg
        if msg.get("nonce") != nonce:
            _event_queue.append((op, msg))
        else:
            return op, msg


def emit(t, data):
    print(json.dumps({"type": t, "data": data}), flush=True)


def load_config():
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except Exception:
        return {}


def load_token():
    try:
        with open(TOKEN_PATH) as f:
            return json.load(f)
    except Exception:
        return None


def save_token(data):
    os.makedirs(os.path.dirname(TOKEN_PATH), exist_ok=True)
    data["_stored_at"] = time.time()
    with open(TOKEN_PATH, "w") as f:
        json.dump(data, f)


def has_required_scopes(token_data):
    scope = token_data.get("scope", "")
    scope_set = set(scope.split())
    return all(s in scope_set for s in SCOPES)


def api_token_request(params):
    data = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request(
        "https://discord.com/api/oauth2/token",
        data=data,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "DiscordBot (https://github.com/discord/discord-rpc, 1)",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {e.code}: {body}")


_subscribed_channel_id = None

def subscribe_channel_events(sock, channel_id):
    global _subscribed_channel_id
    if channel_id == _subscribed_channel_id:
        return
    _subscribed_channel_id = channel_id
    args = {"channel_id": channel_id}
    for evt in ("SPEAKING_START", "SPEAKING_STOP", "VOICE_STATE_CREATE",
                "VOICE_STATE_UPDATE", "VOICE_STATE_DELETE"):
        subscribe(sock, evt, args)


def process_voice_channel_select(sock, data, current_channel_id):
    """Handle VOICE_CHANNEL_SELECT: fetch channel name, emit, subscribe to channel events."""
    new_channel_id = data.get("channel_id")
    if new_channel_id:
        op2, ch_resp = send_cmd(sock, "GET_CHANNEL", {"channel_id": new_channel_id})
        _log("GET_CHANNEL:", json.dumps(ch_resp)[:200])
        if ch_resp and ch_resp.get("data"):
            data["channel_name"] = ch_resp["data"].get("name", "")
            for member in ch_resp["data"].get("voice_states", []):
                emit("VOICE_STATE_CREATE", member)
        else:
            data["channel_name"] = ""
    else:
        data["channel_name"] = ""

    _log("emit VOICE_CHANNEL_SELECT:", json.dumps(data))
    emit("VOICE_CHANNEL_SELECT", data)

    if new_channel_id and new_channel_id != current_channel_id:
        subscribe_channel_events(sock, new_channel_id)
        return new_channel_id
    elif not new_channel_id:
        return None
    return current_channel_id


def handle_event(sock, evt, data, current_channel_id):
    """Dispatch a single Discord event. Returns updated current_channel_id."""
    if evt == "VOICE_CHANNEL_SELECT":
        return process_voice_channel_select(sock, data, current_channel_id)
    elif evt in ("VOICE_STATE_CREATE", "VOICE_STATE_UPDATE", "VOICE_STATE_DELETE",
                 "SPEAKING_START", "SPEAKING_STOP"):
        emit(evt, data)
    return current_channel_id


def handle_stdin_cmd(sock, cmd):
    """Process a command written to stdin by QML."""
    action = cmd.get("action")
    _log("stdin cmd:", action)
    if action == "mute":
        _, resp = send_cmd(sock, "SET_VOICE_SETTINGS", {"mute": bool(cmd.get("value", True))})
        _log("SET_VOICE_SETTINGS mute resp:", json.dumps(resp)[:120] if resp else None)
    elif action == "deafen":
        _, resp = send_cmd(sock, "SET_VOICE_SETTINGS", {"deaf": bool(cmd.get("value", True))})
        _log("SET_VOICE_SETTINGS deaf resp:", json.dumps(resp)[:120] if resp else None)
    elif action == "disconnect":
        _, resp = send_cmd(sock, "SELECT_VOICE_CHANNEL", {"channel_id": None})
        _log("SELECT_VOICE_CHANNEL disconnect resp:", json.dumps(resp)[:120] if resp else None)
    elif action == "get_guilds":
        _, resp = send_cmd(sock, "GET_GUILDS", {})
        guilds = (resp or {}).get("data", {}).get("guilds", [])
        _log("GET_GUILDS:", len(guilds), "guilds")
        emit("guilds", {"guilds": guilds})
    elif action == "get_channels":
        guild_id = cmd.get("guild_id", "")
        _, resp = send_cmd(sock, "GET_CHANNELS", {"guild_id": guild_id})
        channels = (resp or {}).get("data", {}).get("channels", [])
        _log("GET_CHANNELS:", guild_id, len(channels), "channels")
        emit("channels", {"guild_id": guild_id, "channels": channels})
    elif action == "join_channel":
        channel_id = cmd.get("channel_id", "")
        _, resp = send_cmd(sock, "SELECT_VOICE_CHANNEL", {"channel_id": channel_id, "force": True})
        _log("SELECT_VOICE_CHANNEL join resp:", json.dumps(resp)[:120] if resp else None)


def main():
    config = load_config()
    client_id = config.get("discord_client_id", "").strip()
    client_secret = config.get("discord_client_secret", "").strip()

    if not client_id or not client_secret:
        emit("needs_setup", {"message": "credentials_missing"})
        sys.exit(0)

    sock_path = find_socket()
    if not sock_path:
        emit("error", {"message": "Discord not running"})
        sys.exit(1)

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(sock_path)
    except OSError as e:
        emit("error", {"message": str(e)})
        sys.exit(1)

    # Handshake
    send_msg(sock, 0, {"v": 1, "client_id": client_id})
    op, resp = recv_msg(sock)
    if not resp or resp.get("code") == 4000:
        emit("error", {"message": "Invalid client_id  -  check discord.com/developers/applications"})
        sys.exit(2)

    user = resp.get("data", {}).get("user", {})
    _log("READY user:", user.get("username"), "id:", user.get("id"))

    # Load stored token; discard if it's missing required scopes (force re-auth)
    token_data = load_token()
    if token_data and not has_required_scopes(token_data):
        _log("Stored token missing required scopes, forcing re-auth")
        token_data = None
        try:
            os.unlink(TOKEN_PATH)
        except Exception:
            pass

    access_token = None
    if token_data:
        stored_at = token_data.get("_stored_at", 0)
        expires_in = token_data.get("expires_in", 604800)
        if time.time() > stored_at + expires_in - 3600:
            try:
                new_token = api_token_request({
                    "grant_type": "refresh_token",
                    "refresh_token": token_data.get("refresh_token", ""),
                    "client_id": client_id,
                    "client_secret": client_secret,
                })
                save_token(new_token)
                access_token = new_token.get("access_token")
            except Exception:
                access_token = token_data.get("access_token")
        else:
            access_token = token_data.get("access_token")

    # Authenticate with stored/refreshed token
    authenticated = False
    if access_token:
        op, auth_resp = send_cmd(sock, "AUTHENTICATE", {"access_token": access_token})
        _log("AUTHENTICATE (stored):", auth_resp.get("evt") if auth_resp else None)
        if auth_resp and auth_resp.get("data", {}).get("application"):
            authenticated = True
            auth_user = auth_resp.get("data", {}).get("user", user)
            emit("connected", {
                "username": auth_user.get("username", ""),
                "discriminator": auth_user.get("discriminator", ""),
                "user_id": auth_user.get("id", user.get("id", "")),
            })
        else:
            access_token = None

    # OAuth flow if not yet authenticated
    if not authenticated:
        emit("needs_auth", {"message": "Waiting for Discord authorization..."})
        op, auth_resp = send_cmd(sock, "AUTHORIZE", {
            "client_id": client_id,
            "scopes": SCOPES,
        })
        _log("AUTHORIZE:", json.dumps(auth_resp))
        if not auth_resp or not auth_resp.get("data", {}).get("code"):
            emit("error", {"message": f"Authorization failed: {auth_resp}"})
            sys.exit(2)
        code = auth_resp["data"]["code"]
        try:
            token_data = api_token_request({
                "grant_type": "authorization_code",
                "code": code,
                "client_id": client_id,
                "client_secret": client_secret,
            })
            _log("Token OK, scopes:", token_data.get("scope"))
            save_token(token_data)
            access_token = token_data["access_token"]
        except Exception as e:
            _log("Token exchange failed:", e)
            emit("error", {"message": f"Token exchange failed: {e}"})
            sys.exit(2)
        op, auth_result = send_cmd(sock, "AUTHENTICATE", {"access_token": access_token})
        _log("AUTHENTICATE (new token):", json.dumps(auth_result)[:100])
        emit("connected", {
            "username": user.get("username", ""),
            "discriminator": user.get("discriminator", ""),
            "user_id": user.get("id", ""),
        })

    # Subscribe to VOICE_CHANNEL_SELECT
    subscribe(sock, "VOICE_CHANNEL_SELECT")

    # Get current voice channel state
    current_channel_id = None
    op, resp = send_cmd(sock, "GET_SELECTED_VOICE_CHANNEL")
    _log("GET_SELECTED_VOICE_CHANNEL:", json.dumps(resp)[:300])
    if resp and resp.get("data") and resp["data"].get("id"):
        channel = resp["data"]
        startup_data = {
            "channel_id": channel.get("id"),
            "guild_id": channel.get("guild_id"),
            "channel_name": channel.get("name", ""),
        }
        current_channel_id = process_voice_channel_select(sock, startup_data, None)

    # Drain queued events before entering the select loop
    while _event_queue:
        _, msg = _event_queue.popleft()
        evt = msg.get("evt")
        data = msg.get("data") or {}
        _log("QUEUED EVENT:", evt)
        current_channel_id = handle_event(sock, evt, data, current_channel_id)

    # Main event loop  -  multiplex Discord socket + stdin commands
    while True:
        try:
            readable, _, _ = select.select([sock, sys.stdin], [], [], 30.0)
        except (OSError, ValueError) as e:
            _log("select error:", e)
            break

        for fd in readable:
            if fd is sys.stdin:
                line = sys.stdin.readline()
                if not line:
                    continue
                line = line.strip()
                if not line:
                    continue
                try:
                    handle_stdin_cmd(sock, json.loads(line))
                except Exception as e:
                    _log("stdin cmd error:", e)
                # Drain events queued inside send_cmd during stdin handling
                while _event_queue:
                    _, qmsg = _event_queue.popleft()
                    qevt = qmsg.get("evt")
                    qdata = qmsg.get("data") or {}
                    _log("QUEUED EVENT (post-cmd):", qevt)
                    current_channel_id = handle_event(sock, qevt, qdata, current_channel_id)

            elif fd is sock:
                op, msg = recv_msg(sock)
                if not msg:
                    emit("disconnected", {})
                    return
                evt = msg.get("evt")
                data = msg.get("data") or {}
                _log("EVENT:", evt, json.dumps(data)[:150])
                current_channel_id = handle_event(sock, evt, data, current_channel_id)


if __name__ == "__main__":
    main()
