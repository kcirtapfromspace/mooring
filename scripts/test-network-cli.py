"""Packaged CLI contract check using a loopback-only, credential-free fixture."""
import json
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="maclink-network-cli-") as directory:
    def run(*args):
        result = subprocess.run([binary, "--config-dir", directory, *args], check=True,
                                capture_output=True, text=True, timeout=10)
        return json.loads(result.stdout)

    with socket.socket() as server:
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        server.settimeout(5)
        received = []

        def serve():
            connection, _ = server.accept()
            with connection:
                connection.settimeout(5)
                connection.sendall(b"RFB 003.889\n")
                received.append(connection.recv(16))

        worker = threading.Thread(target=serve)
        worker.start()
        mac = run("add", "--name", "Loopback fixture", "--host", "127.0.0.1",
                  "--port", str(server.getsockname()[1]))
        response = run("network-probe", mac["id"])
        worker.join(timeout=6)
        assert not worker.is_alive() and received == [b""], "probe sent application data"
        assert response["status"] == "rfb_ready"
        inspection = response["inspection"]
        assert inspection["resolved_address"] == "127.0.0.1"
        assert inspection["tcp_connect_ms"] >= 0 and inspection["rfb_greeting_ms"] >= 0
        now = int(time.monotonic() * 1000)
        request = {"now_ms": now, "context": {
            "trusted_home_baseline": False, "allow_high_performance_override": False,
            "high_performance_supported": False, "transport": "unknown", "vpn": "unknown"
        }, "probes": [{"observed_at_ms": now, "status": response["status"],
                       "tcp_connect_ms": inspection["tcp_connect_ms"],
                       "rfb_greeting_ms": inspection["rfb_greeting_ms"]}], "state": None}
        decision = run("network-evaluate", json.dumps(request))
        assert decision["recommended_mode"] == "standard"
        request["state"] = decision["state"]
        request["probes"] = []
        assert run("network-evaluate", json.dumps(request))["recommended_mode"] == "standard"
    assert run("network-probe", mac["id"])["status"] == "connect_failed"
print("Packaged network CLI: live loopback, zero writes, policy round-trip, refusal passed.")
