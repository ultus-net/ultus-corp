import json
import socket

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
print(json.dumps(json.loads(data)["arguments"]["leases"]))
