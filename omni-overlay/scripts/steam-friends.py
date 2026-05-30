#!/usr/bin/env python3
"""
Steam friends & chat bridge  -  persistent history, avatars, rich presence,
persona-state callbacks, game invites.

Events -> stdout (JSON):
  steam_ready
  steam_error      {message}
  steam_friends    {friends:[{steamid,name,state,stateid,gameid,richpresence,avatar_b64}]}
  steam_message    {steamid, name, text, outgoing, ts}
  steam_persona    {steamid, name, state, stateid, gameid, richpresence}

Commands <- stdin (JSON):
  {"action":"send",    "steamid":"...", "text":"..."}
  {"action":"invite",  "steamid":"..."}
  {"action":"refresh"}
"""

import base64, ctypes, json, os, select, signal, struct, sys, time, zlib

SO_PATH   = os.path.expanduser("~/.local/share/Steam/steamrt64/libsteam_api.so")
APPID     = "480"
POLL_S    = 10.0
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
HISTORY_FILE = os.path.join(SCRIPT_DIR, "..", "steam-chat-history.json")

PERSONA_STATE = {0:"Offline",1:"Online",2:"Busy",3:"Away",4:"Snooze",5:"Trade",6:"Play"}

# PNG from raw RGBA

def _png_chunk(tag, data):
    payload = tag + data
    return struct.pack(">I", len(data)) + payload + struct.pack(">I", zlib.crc32(payload) & 0xFFFFFFFF)

def rgba_to_b64_png(w, h, rgba):
    raw = b"".join(b"\x00" + rgba[y*w*4:(y+1)*w*4] for y in range(h))
    chunks = (b"\x89PNG\r\n\x1a\n"
              + _png_chunk(b"IHDR", struct.pack(">II5B", w, h, 8, 6, 0, 0, 0))
              + _png_chunk(b"IDAT", zlib.compress(raw))
              + _png_chunk(b"IEND", b""))
    return base64.b64encode(chunks).decode()

# Persistent history

def load_history():
    try:
        with open(HISTORY_FILE) as f:
            return json.load(f)
    except Exception:
        return {}

def save_history(history):
    try:
        os.makedirs(os.path.dirname(HISTORY_FILE), exist_ok=True)
        with open(HISTORY_FILE, "w") as f:
            json.dump(history, f)
    except Exception:
        pass

# Emit

def emit(t, data=None):
    print(json.dumps({"type": t, "data": data or {}}), flush=True)

# SDK setup

appid_path = os.path.join(SCRIPT_DIR, "steam_appid.txt")
with open(appid_path, "w") as f:
    f.write(APPID)
os.environ["SteamAppId"]  = APPID
os.environ["STEAM_APPID"] = APPID

try:
    sdk = ctypes.CDLL(SO_PATH)
except OSError as e:
    emit("steam_error", {"message": f"Cannot load libsteam_api.so: {e}"}); sys.exit(1)

sdk.SteamAPI_InitFlat.restype  = ctypes.c_int
sdk.SteamAPI_InitFlat.argtypes = [ctypes.c_char_p]
sdk.SteamAPI_RunCallbacks.restype  = None
sdk.SteamAPI_RunCallbacks.argtypes = []
sdk.SteamAPI_Shutdown.restype  = None
sdk.SteamAPI_Shutdown.argtypes = []

sdk.SteamAPI_SteamFriends_v018.restype  = ctypes.c_void_p
sdk.SteamAPI_SteamFriends_v018.argtypes = []
sdk.SteamAPI_SteamUtils_v010.restype  = ctypes.c_void_p
sdk.SteamAPI_SteamUtils_v010.argtypes = []

# ISteamFriends
def _sf(name, res, *args):
    fn = getattr(sdk, f"SteamAPI_ISteamFriends_{name}")
    fn.restype = res; fn.argtypes = list(args)

_sf("GetFriendCount",          ctypes.c_int,     ctypes.c_void_p, ctypes.c_int)
_sf("GetFriendByIndex",        ctypes.c_uint64,  ctypes.c_void_p, ctypes.c_int, ctypes.c_int)
_sf("GetFriendPersonaName",    ctypes.c_char_p,  ctypes.c_void_p, ctypes.c_uint64)
_sf("GetFriendPersonaState",   ctypes.c_int,     ctypes.c_void_p, ctypes.c_uint64)
_sf("GetFriendRichPresence",   ctypes.c_char_p,  ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p)
_sf("GetSmallFriendAvatar",    ctypes.c_int,     ctypes.c_void_p, ctypes.c_uint64)
_sf("ReplyToFriendMessage",    ctypes.c_bool,    ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p)
_sf("GetFriendMessage",        ctypes.c_int,     ctypes.c_void_p, ctypes.c_uint64, ctypes.c_int,
    ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_int))
_sf("InviteUserToGame",        ctypes.c_bool,    ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p)

class FriendGameInfo(ctypes.Structure):
    _fields_ = [("m_gameID",ctypes.c_uint64),("m_unGameIP",ctypes.c_uint32),
                ("m_usGamePort",ctypes.c_uint16),("m_usQueryPort",ctypes.c_uint16),
                ("m_steamIDLobby",ctypes.c_uint64)]

sdk.SteamAPI_ISteamFriends_GetFriendGamePlayed.restype  = ctypes.c_bool
sdk.SteamAPI_ISteamFriends_GetFriendGamePlayed.argtypes = [
    ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(FriendGameInfo)]

# ISteamUtils
sdk.SteamAPI_ISteamUtils_GetImageSize.restype  = ctypes.c_bool
sdk.SteamAPI_ISteamUtils_GetImageSize.argtypes = [
    ctypes.c_void_p, ctypes.c_int,
    ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)]
sdk.SteamAPI_ISteamUtils_GetImageRGBA.restype  = ctypes.c_bool
sdk.SteamAPI_ISteamUtils_GetImageRGBA.argtypes = [
    ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]

# Callback machinery
RUN_FN  = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p)
RUN2_FN = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_bool, ctypes.c_uint64)
DEST_FN = ctypes.CFUNCTYPE(None, ctypes.c_void_p)

class VTable(ctypes.Structure):
    _fields_ = [("Run",RUN_FN),("Run2",RUN2_FN),("Destroy",DEST_FN)]

class CCallbackBase(ctypes.Structure):
    _fields_ = [("vtable",ctypes.POINTER(VTable)),
                ("m_nCallbackFlags",ctypes.c_ubyte),
                ("m_iCallback",ctypes.c_int)]

sdk.SteamAPI_RegisterCallback.restype  = None
sdk.SteamAPI_RegisterCallback.argtypes = [ctypes.c_void_p, ctypes.c_int]
sdk.SteamAPI_UnregisterCallback.restype  = None
sdk.SteamAPI_UnregisterCallback.argtypes = [ctypes.c_void_p]

class FriendChatMsg(ctypes.Structure):
    _fields_ = [("m_steamIDUser",ctypes.c_uint64),("m_iMessageID",ctypes.c_int)]

class PersonaStateChange(ctypes.Structure):
    _fields_ = [("m_ulSteamID",ctypes.c_uint64),("m_nChangeFlags",ctypes.c_int)]

CHAT_CB_ID    = 344   # GameConnectedFriendChatMsg_t
PERSONA_CB_ID = 304   # PersonaStateChange_t

# Helpers

def get_avatar_b64(utils, friends, sid):
    handle = sdk.SteamAPI_ISteamFriends_GetSmallFriendAvatar(friends, sid)
    if handle <= 0:
        return ""
    w = ctypes.c_uint32(0); h = ctypes.c_uint32(0)
    if not sdk.SteamAPI_ISteamUtils_GetImageSize(utils, handle, ctypes.byref(w), ctypes.byref(h)):
        return ""
    size = int(w.value) * int(h.value) * 4
    if size <= 0:
        return ""
    buf = ctypes.create_string_buffer(size)
    if not sdk.SteamAPI_ISteamUtils_GetImageRGBA(utils, handle, buf, size):
        return ""
    try:
        return rgba_to_b64_png(int(w.value), int(h.value), buf.raw)
    except Exception:
        return ""

def get_rich_presence(friends, sid):
    rp = sdk.SteamAPI_ISteamFriends_GetFriendRichPresence(friends, sid, b"steam_display")
    if rp:
        return rp.decode("utf-8", errors="replace")
    rp = sdk.SteamAPI_ISteamFriends_GetFriendRichPresence(friends, sid, b"status")
    return rp.decode("utf-8", errors="replace") if rp else ""

def build_friend(friends, utils, sid):
    name_b = sdk.SteamAPI_ISteamFriends_GetFriendPersonaName(friends, sid)
    name   = (name_b or b"").decode("utf-8", errors="replace") or "Unknown"
    state  = sdk.SteamAPI_ISteamFriends_GetFriendPersonaState(friends, sid)
    gi     = FriendGameInfo()
    in_game = sdk.SteamAPI_ISteamFriends_GetFriendGamePlayed(friends, sid, ctypes.byref(gi))
    gameid  = int(gi.m_gameID) if in_game else 0
    rp      = get_rich_presence(friends, sid) if state > 0 else ""
    av      = get_avatar_b64(utils, friends, sid)
    return {"steamid": str(sid), "name": name,
            "state": PERSONA_STATE.get(state, "Offline"), "stateid": state,
            "gameid": gameid, "richpresence": rp, "avatar_b64": av}

def get_all_friends(friends, utils):
    k_EFriendFlagImmediate = 4
    count = sdk.SteamAPI_ISteamFriends_GetFriendCount(friends, k_EFriendFlagImmediate)
    if count < 0:
        return []
    result = []
    for i in range(count):
        sid = sdk.SteamAPI_ISteamFriends_GetFriendByIndex(friends, i, k_EFriendFlagImmediate)
        result.append(build_friend(friends, utils, sid))
    result.sort(key=lambda f: (0 if f["stateid"] > 0 else 1,
                               0 if f["gameid"] else 1,
                               f["name"].lower()))
    return result

# Main

_shutdown_called = False

def _clean_shutdown(signum=None, frame=None):
    global _shutdown_called
    if _shutdown_called:
        return
    _shutdown_called = True
    try:
        sdk.SteamAPI_Shutdown()
    except Exception:
        pass
    sys.exit(0)

signal.signal(signal.SIGTERM, _clean_shutdown)
signal.signal(signal.SIGINT,  _clean_shutdown)

def main():
    err_buf = ctypes.create_string_buffer(1024)
    if sdk.SteamAPI_InitFlat(err_buf) != 0:
        msg = err_buf.value.decode("utf-8", errors="replace") or "Init failed"
        emit("steam_error", {"message": f"Steam init failed: {msg}"}); sys.exit(1)

    friends = sdk.SteamAPI_SteamFriends_v018()
    utils   = sdk.SteamAPI_SteamUtils_v010()
    if not friends:
        emit("steam_error", {"message": "ISteamFriends unavailable"}); sys.exit(1)

    history = load_history()
    emit("steam_ready")

    # Send persisted history to QML
    for sid, msgs in history.items():
        for m in msgs:
            emit("steam_message", m)

    # Callbacks
    noop2 = RUN2_FN(lambda s, p, f, c: None)
    noop_d = DEST_FN(lambda s: None)

    def on_chat(self_ptr, pvParam):
        try:
            d = ctypes.cast(pvParam, ctypes.POINTER(FriendChatMsg)).contents
            sid, mid = d.m_steamIDUser, d.m_iMessageID
            buf = ctypes.create_string_buffer(2048)
            etype = ctypes.c_int(0)
            n = sdk.SteamAPI_ISteamFriends_GetFriendMessage(
                friends, sid, mid, buf, len(buf), ctypes.byref(etype))
            if n > 0 and etype.value == 1:
                name_b = sdk.SteamAPI_ISteamFriends_GetFriendPersonaName(friends, sid)
                name   = (name_b or b"").decode("utf-8", errors="replace")
                text   = buf.value[:n].decode("utf-8", errors="replace")
                msg    = {"steamid": str(sid), "name": name,
                          "text": text, "outgoing": False, "ts": int(time.time())}
                key = str(sid)
                history.setdefault(key, []).append(msg)
                save_history(history)
                emit("steam_message", msg)
        except Exception:
            pass

    def on_persona(self_ptr, pvParam):
        try:
            d = ctypes.cast(pvParam, ctypes.POINTER(PersonaStateChange)).contents
            sid = d.m_steamIDUser
            info = build_friend(friends, utils, sid)
            emit("steam_persona", info)
        except Exception:
            pass

    vt_chat = VTable(RUN_FN(on_chat), noop2, noop_d)
    cb_chat = CCallbackBase(ctypes.pointer(vt_chat), 0, CHAT_CB_ID)
    sdk.SteamAPI_RegisterCallback(ctypes.byref(cb_chat), CHAT_CB_ID)

    vt_persona = VTable(RUN_FN(on_persona), noop2, noop_d)
    cb_persona = CCallbackBase(ctypes.pointer(vt_persona), 0, PERSONA_CB_ID)
    sdk.SteamAPI_RegisterCallback(ctypes.byref(cb_persona), PERSONA_CB_ID)

    # Initial friends list
    emit("steam_friends", {"friends": get_all_friends(friends, utils)})
    last_poll = time.time()

    # Main loop
    while True:
        sdk.SteamAPI_RunCallbacks()
        try:
            r, _, _ = select.select([sys.stdin], [], [], 1.0)
        except (OSError, ValueError):
            break

        if sys.stdin in r:
            line = sys.stdin.readline()
            if not line:
                break
            line = line.strip()
            if not line:
                continue
            try:
                cmd = json.loads(line)
                action = cmd.get("action", "")
                if action == "send":
                    sid  = int(cmd.get("steamid", "0"))
                    text = cmd.get("text", "")
                    if sdk.SteamAPI_ISteamFriends_ReplyToFriendMessage(
                            friends, ctypes.c_uint64(sid), text.encode("utf-8")):
                        name_b = sdk.SteamAPI_ISteamFriends_GetFriendPersonaName(
                            friends, ctypes.c_uint64(sid))
                        name = (name_b or b"").decode("utf-8", errors="replace")
                        msg = {"steamid": str(sid), "name": name,
                               "text": text, "outgoing": True, "ts": int(time.time())}
                        history.setdefault(str(sid), []).append(msg)
                        save_history(history)
                        emit("steam_message", msg)
                elif action == "invite":
                    sid = int(cmd.get("steamid", "0"))
                    sdk.SteamAPI_ISteamFriends_InviteUserToGame(
                        friends, ctypes.c_uint64(sid), b"")
                elif action == "refresh":
                    emit("steam_friends", {"friends": get_all_friends(friends, utils)})
                    last_poll = time.time()
            except Exception:
                pass

        if time.time() - last_poll >= POLL_S:
            emit("steam_friends", {"friends": get_all_friends(friends, utils)})
            last_poll = time.time()

    sdk.SteamAPI_UnregisterCallback(ctypes.byref(cb_chat))
    sdk.SteamAPI_UnregisterCallback(ctypes.byref(cb_persona))
    _clean_shutdown()

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        emit("steam_error", {"message": str(e)}); sys.exit(1)
