#!/usr/bin/env python3
import json
import os
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time


daemon, cli, seed = sys.argv[1:4]
root = tempfile.TemporaryDirectory(prefix="minni-hardening-")
state = os.path.join(root.name, "state")
run_dir = os.path.join(root.name, "run")
sock = os.path.join(run_dir, "minni.sock")
config = os.path.join(root.name, "config")
os.mkdir(run_dir, 0o700)
with open(config, "w", encoding="utf-8") as output:
    output.write("max_unpinned_items=2\n")
subprocess.run([seed, state, "2"], check=True)


def start(socket_path=sock):
    process = subprocess.Popen(
        [daemon, "--no-x11", "--config", config, "--state-dir", state, "--socket", socket_path],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    for _ in range(200):
        if process.poll() is not None:
            raise RuntimeError(process.stderr.read())
        if os.path.exists(socket_path) and stat.S_ISSOCK(os.lstat(socket_path).st_mode):
            probe = socket.socket(socket.AF_UNIX)
            try:
                probe.connect(socket_path)
                probe.close()
                return process
            except OSError:
                probe.close()
        time.sleep(0.01)
    raise RuntimeError("daemon did not create socket")


def request(connection, request_id, operation, args=None):
    value = {"v": 1, "id": request_id, "op": operation, "args": args or {}}
    data = json.dumps(value, separators=(",", ":")).encode()
    connection.sendall(struct.pack(">I", len(data)) + data)
    header = connection.recv(4)
    assert len(header) == 4
    length = struct.unpack(">I", header)[0]
    payload = bytearray()
    while len(payload) < length:
        payload.extend(connection.recv(length - len(payload)))
    return json.loads(payload)


def connect():
    connection = socket.socket(socket.AF_UNIX)
    connection.settimeout(3)
    connection.connect(sock)
    assert request(connection, "hello", "hello", {"min_version": 1, "max_version": 1})["ok"]
    return connection


insecure = os.path.join(root.name, "insecure")
os.mkdir(insecure, 0o755)
rejected = subprocess.run(
    [daemon, "--no-x11", "--config", config, "--state-dir", state, "--socket", os.path.join(insecure, "minni.sock")],
    text=True,
    capture_output=True,
)
assert rejected.returncode != 0
assert stat.S_IMODE(os.stat(insecure).st_mode) == 0o755

symlink_path = os.path.join(run_dir, "symlink.sock")
os.symlink(os.path.join(root.name, "target"), symlink_path)
rejected = subprocess.run(
    [daemon, "--no-x11", "--config", config, "--state-dir", state, "--socket", symlink_path],
    text=True,
    capture_output=True,
)
assert rejected.returncode != 0 and stat.S_ISLNK(os.lstat(symlink_path).st_mode)

process = start()
status = subprocess.run([cli, "--socket", sock, "--json", "status"], check=True, text=True, capture_output=True)
assert json.loads(status.stdout)["result"]["item_count"] == 2
assert stat.S_IMODE(os.stat(sock).st_mode) == 0o600
assert stat.S_IMODE(os.stat(state).st_mode) == 0o700
assert stat.S_IMODE(os.stat(os.path.join(state, "minni.db")).st_mode) == 0o600
for directory, _, files in os.walk(os.path.join(state, "blobs")):
    for name in files:
        assert stat.S_IMODE(os.stat(os.path.join(directory, name)).st_mode) == 0o600

process.send_signal(signal.SIGKILL)
process.wait(timeout=5)
assert os.path.exists(sock)
process = start()
status = subprocess.run([cli, "--socket", sock, "--json", "status"], check=True, text=True, capture_output=True)
assert json.loads(status.stdout)["result"]["item_count"] == 2
process.terminate()
process.wait(timeout=5)
assert not os.path.exists(sock)
root.cleanup()

print("Hardening integration: 12 passed")
