#!/usr/bin/env python3
"""Read-only SSH command through an ephemeral Linux internet-link fixture.

Build both helpers on the local Mac first. This deploys only the supplied Linux
binary into a private temporary directory, generates disposable identities,
retains SSH known-host verification, and removes the fixture on exit. It does
not change desktop state, credentials, installed services or saved connections.
"""
import argparse
import json
import os
import signal
import sys
from pathlib import Path
import re
import selectors
import shlex
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("mac_helper", type=Path)
parser.add_argument("linux_helper", type=Path)
parser.add_argument("ssh_target")
parser.add_argument("--relay", help="Explicit HTTPS Iroh relay; omit for direct connectivity")
parser.add_argument("--relay-only", action="store_true")
parser.add_argument("--owned-session", action="store_true", help="exercise two concurrent SSH channels and session cleanup")
args = parser.parse_args()
if args.relay_only and not args.relay:
    parser.error("--relay-only requires --relay")
ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]
mac = str(args.mac_helper.resolve())
remote = None
host = None
started = time.monotonic()


def remote_run(command, **kwargs):
    return subprocess.run([*ssh, args.ssh_target, command], check=True, capture_output=True,
                          text=True, timeout=20, **kwargs)


try:
    remote = remote_run("umask 077; mktemp -d /tmp/mooring-link-live.XXXXXXXX").stdout.strip()
    if not re.fullmatch(r"/tmp/mooring-link-live\.[A-Za-z0-9]+", remote):
        raise RuntimeError("Unexpected remote temporary path")
    subprocess.run(["scp", "-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                    str(args.linux_helper.resolve()), f"{args.ssh_target}:{remote}/mooring-link"],
                   check=True, capture_output=True, timeout=30)
    remote_run(shlex.join(["chmod", "700", f"{remote}/mooring-link"]))
    remote_run(shlex.join([f"{remote}/mooring-link", "identity", f"{remote}/host.key"]))
    with tempfile.TemporaryDirectory(prefix="mooring-link-client-") as directory:
        key = str(Path(directory) / "client.key")
        public = subprocess.run([mac, "identity", key], check=True, capture_output=True,
                                text=True, timeout=10).stdout.strip()
        relay = ["--relay", args.relay] if args.relay else []
        only = ["--relay-only"] if args.relay_only else []
        command = [f"{remote}/mooring-link", "serve", "--key", f"{remote}/host.key",
                   "--allow", public, "--service", "ssh", *relay, *only]
        host = subprocess.Popen([*ssh, args.ssh_target,
                                 f"echo $$ > {shlex.quote(remote + '/pid')}; exec {shlex.join(command)}"],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        selector = selectors.DefaultSelector()
        selector.register(host.stdout, selectors.EVENT_READ)
        if not selector.select(25):
            raise RuntimeError("Linux link did not become ready before its deadline")
        event = json.loads(host.stdout.readline())
        selector.close()
        ticket = Path(directory) / "host.ticket"
        ticket.write_text(event["ticket"])
        proxy = shlex.join([mac, "proxy", "--key", key, "--ticket", str(ticket),
                            "--service", "ssh", *relay, *only])
        session_config = None
        if args.owned_session:
            exercise = """import concurrent.futures, os, subprocess, sys
config = os.environ['MOORING_SSH_CONFIG']
print('config:' + config, flush=True)
def control_path(user=None):
    command = ['ssh', '-G', '-F', config]
    if user: command += ['-l', user]
    output = subprocess.run([*command, sys.argv[1]], check=True, capture_output=True, text=True, timeout=5).stdout
    return next(line for line in output.splitlines() if line.startswith('controlpath '))
assert control_path() != control_path('mooring_fixture_other_account'), 'Remote accounts share the control socket'
def check(_):
    return subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-F', config, sys.argv[1], "printf 'mooring-link-ssh-ok\\n'; uname -m"], check=True, capture_output=True, text=True, timeout=20).stdout
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    for output in pool.map(check, range(2)): print(output, end='', flush=True)
"""
            client_args = [mac, "ssh-session", "--key", key, "--ticket", str(ticket), "--service", "ssh", "--target", args.ssh_target, *relay, *only, "--", sys.executable, "-c", exercise, args.ssh_target]
        else:
            client_args = [*ssh, "-o", f"ProxyCommand={proxy}", args.ssh_target, "printf 'mooring-link-ssh-ok\\n'; uname -m"]
        client = subprocess.Popen(client_args,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                  start_new_session=True)
        try:
            stdout, stderr = client.communicate(timeout=45)
        except subprocess.TimeoutExpired:
            os.killpg(client.pid, signal.SIGKILL)
            stdout, stderr = client.communicate(timeout=5)
            raise RuntimeError("SSH link exceeded its deadline: " + stderr[-4096:]) from None
        if client.returncode:
            raise RuntimeError("SSH link failed: " + stderr[-4096:])
        lines = stdout.splitlines()
        if args.owned_session:
            session_config = Path(lines.pop(0).removeprefix("config:"))
            if session_config.exists() or session_config.parent.exists():
                raise RuntimeError("The owned SSH session left its private configuration")
        if lines != ["mooring-link-ssh-ok", "aarch64"] * (2 if args.owned_session else 1):
            raise RuntimeError("Unexpected SSH response through the link")
        print(json.dumps({"result": "passed", "transport": "forced-relay" if args.relay_only else "automatic" if args.relay else "direct",
                          "ssh_host_key_verification": "enabled", "remote_command": "read-only",
                          "concurrent_ssh_channels": 2 if args.owned_session else 1,
                          "control_socket_account_isolation": args.owned_session,
                          "owned_session_config_removed": not session_config.exists() if session_config else None,
                          "seconds": round(time.monotonic() - started, 2)}))
finally:
    if remote and re.fullmatch(r"/tmp/mooring-link-live\.[A-Za-z0-9]+", remote):
        # Signal only the exact PID created by this fixture; never use pkill.
        cleanup = (f"if test -f {remote}/pid; then p=$(cat {remote}/pid); "
                   "case \"$p\" in ''|*[!0-9]*) exit 1;; esac; kill -INT \"$p\" 2>/dev/null || true; fi")
        try:
            remote_run(cleanup)
            if host:
                host.communicate(timeout=8)
            remote_run(shlex.join(["rm", "-rf", "--", remote]))
        finally:
            if host and host.poll() is None:
                host.terminate()
                host.communicate(timeout=5)
