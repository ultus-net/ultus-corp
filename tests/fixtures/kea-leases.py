import json
import socket
import sys

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect("/var/run/kea/kea4-ctrl-socket")
s.sendall(
    json.dumps({"command": "lease4-get-all", "service": ["dhcp4"]}).encode() + b"\n"
)
data = b""
try:
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
except socket.timeout:
    pass
reply = json.loads(data)
if reply.get("result") != 0 or "arguments" not in reply:
    print(f"raw reply: {data.decode(errors='replace')}", file=sys.stderr)
    print(f"kea text: {reply.get('text', '')}", file=sys.stderr)
    sys.exit(1)
print(json.dumps(reply["arguments"]["leases"]))
