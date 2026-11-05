"""A loopback VNC server for the viewer test: no sign-in, an 8x4 desktop.

Usage: python3 -I scripts/fake-vnc-server.py RECORD_JSON
Prints the port, serves one client, then writes what the client sent.

Update 1 (on the first request): top row red, bottom row blue, the rest
black, as raw BGRX with padding bytes of 0. Update 2, sent when the first
pointer event arrives so the two never merge: pixel (1, 1) green.
"""
import json
import socket
import struct
import sys

record_path = sys.argv[1]
listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen(1)
listener.settimeout(30)
print(listener.getsockname()[1], flush=True)
client, _ = listener.accept()
client.settimeout(30)
record = {"keys": [], "pointer": [], "requests": [], "encodings": [], "pixel_format": None}


def read(count):
    data = b""
    while len(data) < count:
        chunk = client.recv(count - len(data))
        if not chunk:
            raise EOFError
        data += chunk
    return data


def raw(x, y, w, h, pixels):
    return struct.pack(">HHHHi", x, y, w, h, 0) + b"".join(pixels)


RED, BLUE, BLACK, GREEN = b"\x00\x00\xc8\x00", b"\xc8\x00\x00\x00", b"\x00\x00\x00\x00", b"\x00\xc8\x00\x00"
updates = [
    b"\x00\x00" + struct.pack(">H", 1) + raw(0, 0, 8, 4, [RED] * 8 + [BLACK] * 16 + [BLUE] * 8),
    b"\x00\x00" + struct.pack(">H", 1) + raw(1, 1, 1, 1, [GREEN]),
]
try:
    client.sendall(b"RFB 003.008\n")
    assert read(12) == b"RFB 003.008\n"
    client.sendall(b"\x01\x01")  # one type: None
    assert read(1) == b"\x01"
    client.sendall(struct.pack(">I", 0))
    record["shared"] = read(1)[0]
    pixel_format = struct.pack(">BBBBHHHBBB3x", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
    name = b"viewer test"
    client.sendall(struct.pack(">HH", 8, 4) + pixel_format + struct.pack(">I", len(name)) + name)
    while True:
        kind = read(1)[0]
        if kind == 0:
            record["pixel_format"] = list(read(19)[3:])
        elif kind == 2:
            count = struct.unpack(">xH", read(3))[0]
            record["encodings"] = list(struct.unpack(f">{count}i", read(4 * count)))
        elif kind == 3:
            record["requests"].append(list(struct.unpack(">BHHHH", read(9))))
            if len(record["requests"]) == 1:
                client.sendall(updates.pop(0))
        elif kind == 4:
            down, keysym = struct.unpack(">B2xI", read(7))
            record["keys"].append([down, keysym])
        elif kind == 5:
            record["pointer"].append(list(struct.unpack(">BHH", read(5))))
            if len(record["pointer"]) == 1:
                client.sendall(updates.pop(0))
        else:
            record["error"] = f"unexpected message {kind}"
            break
except (EOFError, ConnectionError, socket.timeout):
    pass
with open(record_path, "w") as out:
    json.dump(record, out)
