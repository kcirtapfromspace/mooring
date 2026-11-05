"""Live, credential-free check of `mooring connect` through an SSH tunnel.

Usage: python3 scripts/test-ssh-tunnel-live.py MOORING_BINARY SSH_TARGET \
           [--user-target USER@HOST] [--expect-types 129,5,30] [--expect-version 003.008]

This is a live check against a real SSH host and VNC server, separate from the
local CI tests. It never signs in: it reads the RFB greeting and the offered
security types, then disconnects without choosing one. The desktop cases run
Mooring's read-only lock check; they never lock, unlock or wake the desktop. SSH uses this Mac's own
keys and agent. The missing-key case uses an isolated ssh config that offers no
key at all, and Mooring disables password and keyboard-interactive sign-in, so
the remote PAM stack is never asked to check a password.

Each case uses an isolated --config-dir; saved connections are not touched.
"""
import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("binary")
parser.add_argument("target")
parser.add_argument("--user-target")
parser.add_argument("--expect-types", default="129,5,30")
parser.add_argument("--expect-version", default="003.008")
options = parser.parse_args()
binary = str(Path(options.binary).resolve())
expected_types = [int(value) for value in options.expect_types.split(",")]
results = []


def record(name, detail):
    results.append((name, detail))
    print(f"PASS {name}: {detail}", flush=True)


def run(directory, *args, env=None, expect_ok=True):
    started = time.monotonic()
    result = subprocess.run([binary, "--config-dir", directory, *args], capture_output=True,
                            text=True, timeout=60, env=env)
    elapsed = time.monotonic() - started
    if expect_ok and result.returncode != 0:
        raise AssertionError(f"{args} failed: {result.stderr.strip()}")
    return result, elapsed


def add(directory, *args):
    result, _ = run(directory, "add", "--name", "Live SSH fixture", *args)
    return json.loads(result.stdout)["id"]


def ssh_children(pid):
    found = subprocess.run(["/usr/bin/pgrep", "-P", str(pid)], capture_output=True, text=True)
    return [int(line) for line in found.stdout.split()]


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def wait_gone(pids, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if not any(alive(pid) for pid in pids):
            return True
        time.sleep(0.05)
    return False


def lan_address():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.connect(("192.0.2.1", 9))  # no packet is sent for UDP connect
        return probe.getsockname()[0]


class Tunnel:
    """A running `mooring connect --no-viewer` and its JSON event stream."""

    def __init__(self, directory, connection, *extra, env=None):
        self.process = subprocess.Popen(
            [binary, "--config-dir", directory, "connect", connection, "--no-viewer", *extra],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        self.events = []

    def next_event(self, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            line = self.process.stdout.readline()
            if not line:
                break
            event = json.loads(line)
            self.events.append(event)
            return event
        raise AssertionError(f"no event; seen {[e.get('event') for e in self.events]}")

    def until(self, name, timeout=30):
        while True:
            event = self.next_event(timeout)
            if event.get("event") == name:
                return event
            if event.get("event") in ("failed", "closed") and name not in ("failed", "closed"):
                raise AssertionError(f"tunnel ended early: {event}")

    def finish(self, timeout=20):
        self.process.wait(timeout=timeout)
        for line in self.process.stdout:
            self.events.append(json.loads(line))
        return self.events[-1], self.process.returncode


def viewer_handshake(port):
    stream = socket.create_connection(("127.0.0.1", port), timeout=10)
    greeting = b""
    while len(greeting) < 12:
        chunk = stream.recv(12 - len(greeting))
        assert chunk, "tunnel closed during the greeting"
        greeting += chunk
    stream.sendall(b"RFB 003.008\n")
    count = stream.recv(1)[0]
    types = b""
    while len(types) < count:
        types += stream.recv(count - len(types))
    return greeting, list(types), stream


with tempfile.TemporaryDirectory(prefix="mooring-ssh-live-") as directory:
    connection = add(directory, "--ssh", options.target, "--server", "vnc")

    # 1. inspect through SSH: greeting and security types, no sign-in.
    result, elapsed = run(directory, "inspect", connection)
    check = json.loads(result.stdout)
    assert check["rfb_version"] == options.expect_version, check
    assert check["security_types"] == expected_types, check
    # macOS 27 Screen Sharing signs in to non-Mac servers only with type 2.
    assert check["apple_viewer_compatible"] is (2 in expected_types or
                                                options.expect_version == "003.889"), check
    record("inspect", f"RFB {check['rfb_version']} types {check['security_types']} "
                      f"{check['security_type_names']} in {elapsed:.2f}s")
    assert check["desktop"]["lock"] in ("locked", "unlocked"), check.get("desktop", check)
    record("inspect desktop", f"{check['desktop']['title']}")
    if options.user_target:
        other = add(directory, "--ssh", options.user_target, "--server", "vnc")
        result, elapsed = run(directory, "inspect", other)
        assert json.loads(result.stdout)["security_types"] == expected_types
        record("inspect user@host", f"{options.user_target} in {elapsed:.2f}s")

    # 1b. The read-only desktop check: locked or not, display on or off.
    def desktop_status(saved, label):
        result, elapsed = run(directory, "desktop-status", saved)
        status = json.loads(result.stdout)
        assert status["session"] == "found", status
        assert status["lock"] in ("locked", "unlocked"), status
        assert status["evidence"] != "none", status
        assert status["display"] in ("on", "off"), status
        assert elapsed < 5, f"desktop-status took {elapsed:.1f}s"
        record(label, f"{status['lock']}, display {status['display']} by {status['evidence']} "
                      f"(user {status.get('session_user')}) in {elapsed:.2f}s: {status['message']}")
        return status
    first_desktop = desktop_status(connection, "desktop-status")

    # 1c. Mooring's own VNC sign-in handshake, stopped at the credential
    # request: RSA-AES keys, hashes and the AES-EAX layer all match the
    # server's, and no credentials are sent, so no password is checked.
    def wayvnc_pid():
        found = subprocess.run(["/usr/bin/ssh", "-o", "BatchMode=yes", "--", options.target,
                                "pgrep -x wayvnc"], capture_output=True, text=True, timeout=30)
        return found.stdout.strip()
    pid_before = wayvnc_pid()
    result, elapsed = run(directory, "vnc-check", connection)
    vnc = json.loads(result.stdout)
    assert vnc["status"] == "ok" and vnc["credentials_sent"] is False, vnc
    assert vnc["negotiated"]["security"] == "rsa_aes256", vnc
    assert vnc["credentials_requested"]["username_needed"] is True, vnc
    assert vnc["credentials_requested"]["server_key_bits"] >= 2048, vnc
    pid_after = wayvnc_pid()
    assert pid_before and pid_before == pid_after, f"wayvnc restarted: {pid_before} -> {pid_after}"
    record("vnc-check", f"{vnc['negotiated']['security']} with a {vnc['credentials_requested']['server_key_bits']}-bit "
                        f"server key reached the credential request in {elapsed:.2f}s; none sent; wayvnc pid "
                        f"{pid_after} unchanged")
    if options.user_target:
        same = desktop_status(other, "desktop-status user@host")
        assert same["session_user"] == first_desktop["session_user"]

    # 2. A full session: tunnel, viewer handshake through 127.0.0.1, idle close.
    tunnel = Tunnel(directory, connection, "--idle-seconds", "2", "--wait-seconds", "30")
    ready = tunnel.until("ready")
    port = ready["local_port"]
    assert ready["local_host"] == "127.0.0.1"
    greeting, types, stream = viewer_handshake(port)
    assert greeting == f"RFB {options.expect_version}\n".encode(), greeting
    assert types == expected_types, types
    tunnel.until("connection_opened")
    children = [pid for pid in ssh_children(tunnel.process.pid) if "-W" in
                subprocess.run(["/bin/ps", "-o", "args=", "-p", str(pid)], capture_output=True,
                               text=True).stdout]
    assert len(children) == 1, f"expected one ssh -W, found {children}"
    try:
        socket.create_connection((lan_address(), port), timeout=2).close()
        raise AssertionError("the tunnel accepted a connection on the LAN address")
    except OSError:
        pass
    stream.close()
    closed = tunnel.until("connection_closed")
    assert closed["failed"] is False, closed
    final, code = tunnel.finish()
    assert code == 0 and final["event"] == "closed" and final["reason"] == "session_ended", final
    names = [event["event"] for event in tunnel.events]
    assert "desktop" in names and names.index("desktop") > names.index("ready"), names
    desktop_event = tunnel.events[names.index("desktop")]
    assert desktop_event["lock"] in ("locked", "unlocked"), desktop_event
    assert wait_gone(children, 1), f"ssh {children} outlived the session"
    record("session", f"127.0.0.1:{port} relayed {greeting.decode().strip()} and types {types}; "
                      f"{closed['bytes_to_viewer']} bytes to viewer; closed {final['reason']} after "
                      f"{final['duration_ms']} ms; ssh {children} reaped; LAN address refused; "
                      f"desktop event {desktop_event['lock']}")

    # 3. Ctrl-C while a viewer is connected.
    tunnel = Tunnel(directory, connection, "--idle-seconds", "30")
    port = tunnel.until("ready")["local_port"]
    _, _, stream = viewer_handshake(port)
    tunnel.until("connection_opened")
    children = ssh_children(tunnel.process.pid)
    started = time.monotonic()
    tunnel.process.send_signal(signal.SIGINT)
    final, code = tunnel.finish()
    stream.settimeout(5)
    assert stream.recv(16) == b"", "viewer socket left open"
    assert code == 0 and final["reason"] == "cancelled", final
    assert wait_gone(children, 1), f"ssh {children} survived Ctrl-C"
    record("ctrl-c", f"closed in {time.monotonic() - started:.2f}s; ssh {children} reaped")

    # 4. The supervisor is killed outright: ssh must still exit on its own.
    tunnel = Tunnel(directory, connection, "--idle-seconds", "30")
    port = tunnel.until("ready")["local_port"]
    _, _, stream = viewer_handshake(port)
    tunnel.until("connection_opened")
    children = ssh_children(tunnel.process.pid)
    tunnel.process.kill()
    tunnel.process.wait(timeout=5)
    started = time.monotonic()
    gone = wait_gone(children, 10)
    stream.close()
    assert gone, f"ssh {children} was orphaned after SIGKILL"
    record("sigkill", f"orphaned ssh {children} exited by itself in {time.monotonic() - started:.2f}s")

    # 5. Failures: each must end quickly with a JSON error and exit 1.
    def expect_failure(name, kind, limit, *add_args, env=None, ssh_target=None, saved=None):
        failing = saved or add(directory, "--ssh", ssh_target or options.target, "--server",
                               "vnc", *add_args)
        tunnel = Tunnel(directory, failing, env=env)
        started = time.monotonic()
        final, code = tunnel.finish(timeout=limit + 10)
        elapsed = time.monotonic() - started
        assert code == 1 and final["event"] == "failed", final
        error = final["error"]
        assert error["kind"] == kind, error
        assert elapsed < limit, f"{name} took {elapsed:.1f}s"
        assert not any(e.get("event") == "ready" for e in tunnel.events), tunnel.events
        stderr = tunnel.process.stderr.read().strip()
        assert stderr.startswith("Mooring: "), stderr
        record(name, f"{kind} in {elapsed:.2f}s: {error['message']} | ssh: {error['ssh_output'][-1:]}")
        return failing

    expect_failure("wrong host", "host_not_found", 5, ssh_target="no-such-host.invalid")
    expect_failure("unreachable host", "host_unreachable", 9, ssh_target="192.0.2.1")
    closed_port = expect_failure("remote port closed", "remote_port_closed", 8, "--port", "5999")
    result, _ = run(directory, "inspect", closed_port, expect_ok=False)
    inspect_error = json.loads(result.stdout)
    assert result.returncode == 1 and inspect_error["error"]["kind"] == "remote_port_closed"
    record("inspect error", "inspect also returns a JSON error and exit 1")

    with tempfile.TemporaryDirectory(prefix="mooring-ssh-nokey-") as keyless:
        config = Path(keyless) / "config"
        known_hosts = Path.home() / ".ssh" / "known_hosts"
        resolved = subprocess.run(["/usr/bin/ssh", "-G", options.target], capture_output=True,
                                  text=True, check=True).stdout.split("\n")
        settings = dict(line.split(" ", 1) for line in resolved if " " in line)
        config.write_text(
            f"Host {options.target}\n"
            f"  HostName {settings['hostname']}\n  User {settings['user']}\n"
            f"  Port {settings['port']}\n"
            "  IdentityFile /nonexistent/mooring-no-key\n  IdentitiesOnly yes\n"
            "  IdentityAgent none\n"
            f"  UserKnownHostsFile {known_hosts}\n")
        env = dict(os.environ, MOORING_SSH_CONFIG=str(config))
        expect_failure("missing key", "authentication_failed", 8, env=env, saved=connection)
        result, elapsed = run(directory, "desktop-status", connection, env=env, expect_ok=False)
        refused = json.loads(result.stdout)
        assert result.returncode == 1 and refused["error"]["kind"] == "authentication_failed", refused
        assert elapsed < 8, f"desktop check with no key took {elapsed:.1f}s"
        record("desktop missing key", f"authentication_failed in {elapsed:.2f}s")

    leftovers = [subprocess.run(["/usr/bin/pgrep", "-fl", "--", pattern], capture_output=True,
                                text=True).stdout.strip()
                 for pattern in (f"-W 127.0.0.1:5900 -- {options.target}",
                                 f"-T -- {options.target} /bin/sh -s")]
    assert not any(leftovers), f"ssh processes left behind: {leftovers}"
    record("no orphans", "no Mooring ssh -W or desktop-check processes remain")

print(f"Live SSH tunnel check passed: {len(results)} cases.")
