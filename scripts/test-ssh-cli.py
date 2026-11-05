"""Packaged CLI contract for Linux desktops through SSH, and for addresses
saved for Apple Screen Sharing before Mooring stopped using it; no network
or keys.

Real /usr/bin/ssh is run with an isolated config whose every host resolves to
a closed loopback port, so the failure path is exercised without contacting
anything. The live tunnel check is scripts/test-ssh-tunnel-live.py.
"""
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="mooring-ssh-cli-") as directory:
    def run(*args, env=None, ok=True):
        result = subprocess.run([binary, "--config-dir", directory, *args], capture_output=True,
                                text=True, timeout=30, env=env)
        assert (result.returncode == 0) == ok, (args, result.returncode, result.stderr)
        return result

    store = Path(directory) / "connections.json"
    # Addresses saved before: a Mac for Screen Sharing (the original shape) and
    # a VNC server without SSH. Both still load, and are never rewritten away.
    legacy_mac = {"id": "18e40000000000aa-1-0", "name": "Office", "host": "office.local", "port": 5900}
    direct = {"id": "18e40000000000bb-1-0", "name": "Desk", "host": "desk.local", "port": 5900, "server": "vnc"}
    store.write_text(json.dumps({"version": 1, "connections": [legacy_mac, direct]}))
    mac, direct_vnc = legacy_mac, direct
    linux = json.loads(run("add", "--name", "M1 Linux", "--ssh", "alex@192.0.2.20").stdout)
    assert linux["ssh"] == {"target": "alex@192.0.2.20"}, linux
    assert (linux["host"], linux["port"], linux["server"]) == ("127.0.0.1", 5900, "vnc")
    saved = json.loads(store.read_text())["connections"]
    assert saved[0] == legacy_mac, saved[0]
    assert "password" not in store.read_text().lower()
    # New Macs are paired, not saved; VNC servers need SSH.
    assert "pair" in run("add", "--name", "Mac", "--host", "mac.local", ok=False).stderr
    assert "Pair Macs" in run("add", "--name", "Mac", "--ssh", "mac", "--server", "mac",
                              ok=False).stderr

    for target in ["-oProxyCommand=id", "host -v", "host:22", "user@", "a;b"]:
        refused = run("add", "--name", "Bad", "--ssh", target, ok=False)
        assert refused.stderr.startswith("Mooring: "), refused.stderr
    assert len(json.loads(run("list").stdout)) == 3

    for gone in ["connect-mode", "network-probe", "network-evaluate", "home-network"]:
        assert "Unknown command" in run(gone, linux["id"], ok=False).stderr, gone
    assert "Pair it with Mooring" in run("connect", mac["id"], ok=False).stderr
    assert "only through SSH" in run("connect", direct_vnc["id"], ok=False).stderr
    assert "only to connections saved with --ssh" in run("desktop-status", mac["id"],
                                                         ok=False).stderr
    assert "only to connections saved with --ssh" in run("vnc-check", mac["id"], ok=False).stderr
    assert "desktop-status ID" in subprocess.run([binary, "--help"], capture_output=True,
                                                 text=True, timeout=10, check=True).stdout

    with tempfile.TemporaryDirectory(prefix="mooring-ssh-config-") as isolated:
        config = Path(isolated) / "config"
        config.write_text("Host *\n  HostName 127.0.0.1\n  Port 1\n  IdentityAgent none\n")
        env = dict(os.environ, MOORING_SSH_CONFIG=str(config))
        started = time.monotonic()
        result = run("connect", linux["id"], "--no-viewer", env=env, ok=False)
        elapsed = time.monotonic() - started
        events = [json.loads(line) for line in result.stdout.splitlines()]
        assert [event["event"] for event in events] == ["starting", "checking", "failed"], events
        assert events[0]["local_only"] is True
        failure = events[-1]
        assert failure["reason"] == "check_failed"
        assert failure["error"]["kind"] == "ssh_port_refused", failure
        assert any("Connection refused" in line for line in failure["error"]["ssh_output"])
        assert elapsed < 5, f"refused SSH took {elapsed:.1f}s"
        assert result.stderr.startswith("Mooring: "), result.stderr
        inspected = run("inspect", linux["id"], env=env, ok=False)
        assert json.loads(inspected.stdout)["error"]["kind"] == "ssh_port_refused"
        started = time.monotonic()
        desktop = run("desktop-status", linux["id"], env=env, ok=False)
        desktop_elapsed = time.monotonic() - started
        desktop_failure = json.loads(desktop.stdout)
        assert desktop_failure["status"] == "failed", desktop_failure
        assert desktop_failure["error"]["kind"] == "ssh_port_refused", desktop_failure
        assert desktop_failure["connection"]["ssh_target"] == "alex@192.0.2.20"
        assert desktop_elapsed < 5, f"refused desktop check took {desktop_elapsed:.1f}s"
        assert desktop.stderr.startswith("Mooring: "), desktop.stderr
        started = time.monotonic()
        vnc = run("vnc-check", linux["id"], env=env, ok=False)
        vnc_elapsed = time.monotonic() - started
        vnc_failure = json.loads(vnc.stdout)
        assert vnc_failure["status"] == "failed", vnc_failure
        assert vnc_failure["error"]["kind"] == "ssh_port_refused", vnc_failure
        assert vnc_elapsed < 5, f"refused vnc-check took {vnc_elapsed:.1f}s"
        bad_env = dict(os.environ, MOORING_SSH_CONFIG="relative/config")
        assert "MOORING_SSH_CONFIG" in run("inspect", linux["id"], env=bad_env, ok=False).stderr

    doctor = json.loads(run("doctor").stdout)
    assert doctor["ssh_available"] is True and "127.0.0.1 only" in doctor["ssh_tunnel"]
    assert "no longer used" in doctor["mac_backend"] and "never stored" in doctor["password_storage"]
    assert "never types a password" in doctor["desktop_status"]
print("Packaged SSH CLI: saved fields, legacy shape, target validation, old Mac addresses kept, Screen Sharing commands gone, "
      f"real ssh failure as JSON in {elapsed:.2f}s, desktop check failure in "
      f"{desktop_elapsed:.2f}s passed.")
