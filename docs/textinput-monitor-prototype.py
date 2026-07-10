#!/usr/bin/env python3
# Persistent variant of the text-input probe: binds zwp_input_method_v2 and
# prints every activate/deactivate as it happens, for ~20s. Diagnostic only.
import os, socket, struct, sys, time

def msg(obj, opcode, body=b""):
    return struct.pack("<IHH", obj, opcode, 8 + len(body)) + body

def wstr(s):
    b = s.encode() + b"\0"
    return struct.pack("<I", len(b)) + b + b"\0" * (-len(b) % 4)

xdg = os.environ.get("XDG_RUNTIME_DIR"); disp = os.environ.get("WAYLAND_DISPLAY", "wayland-1")
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(f"{xdg}/{disp}")
s.settimeout(0.3)
DISPLAY, REGISTRY, SYNC1, SEAT, IMM, IM = 1, 2, 3, 4, 5, 6
s.sendall(msg(DISPLAY, 1, struct.pack("<I", REGISTRY)) + msg(DISPLAY, 0, struct.pack("<I", SYNC1)))
seat = imm = None; buf = b""; t0 = time.monotonic()
print("listening 20s — click into/out of text fields now...", flush=True)
while time.monotonic() - t0 < 20:
    try:
        data = s.recv(65536)
    except socket.timeout:
        continue
    if not data: break
    buf += data
    while len(buf) >= 8:
        obj, opcode, size = struct.unpack_from("<IHH", buf, 0)
        if size < 8 or len(buf) < size: break
        body = buf[8:size]; buf = buf[size:]
        if obj == REGISTRY and opcode == 0:
            name, slen = struct.unpack_from("<II", body, 0)
            iface = body[8:8+slen-1].decode()
            ver = struct.unpack_from("<I", body, 8 + slen + (-slen % 4))[0]
            if iface == "wl_seat" and not seat: seat = (name, min(ver, 5))
            if iface == "zwp_input_method_manager_v2": imm = (name, 1)
        elif obj == SYNC1 and opcode == 0:
            out = msg(REGISTRY, 0, struct.pack("<I", seat[0]) + wstr("wl_seat") + struct.pack("<II", seat[1], SEAT))
            out += msg(REGISTRY, 0, struct.pack("<I", imm[0]) + wstr("zwp_input_method_manager_v2") + struct.pack("<II", imm[1], IMM))
            out += msg(IMM, 0, struct.pack("<II", SEAT, IM))
            s.sendall(out)
            print("bound; waiting for events", flush=True)
        elif obj == IM:
            names = {0: "ACTIVATE", 1: "deactivate", 5: "done", 6: "UNAVAILABLE (another IME bound)"}
            n = names.get(opcode, f"event {opcode}")
            print(f"{time.monotonic()-t0:5.1f}s  {n}", flush=True)
