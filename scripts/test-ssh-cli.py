"""Packaged CLI contract for SSH and non-Mac connections; no network or keys.

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
    mac = json.loads(run("add", "--name", "Office", "--host", "office.local").stdout)
    linux = json.loads(run("add", "--name", "M1 Linux", "--ssh", "alex@192.0.2.20",
                           "--server", "vnc").stdout)
    assert linux["ssh"] == {"target": "alex@192.0.2.20"}, linux
    assert (linux["host"], linux["port"], linux["server"]) == ("127.0.0.1", 5900, "vnc")
    direct_vnc = json.loads(run("add", "--name", "Desk", "--host", "desk.local",
                                "--server", "vnc").stdout)
    saved = json.loads(store.read_text())["connections"]
    # A plain Mac keeps exactly the fields it had before SSH support.
    assert set(saved[0]) == {"id", "name", "host", "port"}, saved[0]
    assert "password" not in store.read_text().lower()

    for target in ["-oProxyCommand=id", "host -v", "host:22", "user@", "a;b"]:
        refused = run("add", "--name", "Bad", "--ssh", target, ok=False)
        assert refused.stderr.startswith("Mooring: "), refused.stderr
    assert len(json.loads(run("list").stdout)) == 3

    assert "through SSH" in run("connect-mode", linux["id"], "standard", ok=False).stderr
    assert "only for Macs" in run("connect-mode", direct_vnc["id"], "high_performance",
                                  ok=False).stderr
    assert "goes through SSH" in run("network-probe", linux["id"], ok=False).stderr
    assert "only to connections saved with --ssh" in run("connect", mac["id"], "--no-viewer",
                                                         ok=False).stderr

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
        bad_env = dict(os.environ, MOORING_SSH_CONFIG="relative/config")
        assert "MOORING_SSH_CONFIG" in run("inspect", linux["id"], env=bad_env, ok=False).stderr

    doctor = json.loads(run("doctor").stdout)
    assert doctor["ssh_available"] is True and "127.0.0.1 only" in doctor["ssh_tunnel"]
print("Packaged SSH CLI: saved fields, legacy shape, target validation, Mac-only modes, "
      f"real ssh failure as JSON in {elapsed:.2f}s passed.")
