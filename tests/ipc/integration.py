#!/usr/bin/env python3
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time


daemon, cli, seed = sys.argv[1:4]
root = tempfile.TemporaryDirectory(prefix="minni-ipc-")
state = os.path.join(root.name, "state")
cache = os.path.join(root.name, "cache")
sock = os.path.join(root.name, "run", "minni.sock")
asset = os.path.join(os.path.dirname(os.path.dirname(seed)), "assets", "minni.png")
subprocess.run([seed, state, "-1", asset], check=True)


def start():
    process = subprocess.Popen(
        [daemon, "--no-x11", "--state-dir", state, "--cache-dir", cache, "--socket", sock],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    for _ in range(200):
        if os.path.exists(sock):
            return process
        if process.poll() is not None:
            raise RuntimeError(process.stderr.read())
        time.sleep(0.01)
    raise RuntimeError("daemon did not create its socket")


def stop(process):
    process.terminate()
    process.wait(timeout=5)


def send(connection, value):
    data = json.dumps(value, separators=(",", ":")).encode()
    connection.sendall(struct.pack(">I", len(data)) + data)


def receive(connection):
    header = connection.recv(4)
    if len(header) != 4:
        raise RuntimeError("short IPC header")
    length = struct.unpack(">I", header)[0]
    chunks = bytearray()
    while len(chunks) < length:
        chunk = connection.recv(length - len(chunks))
        if not chunk:
            raise RuntimeError("short IPC frame")
        chunks.extend(chunk)
    return json.loads(chunks)


def connect():
    connection = socket.socket(socket.AF_UNIX)
    connection.settimeout(3)
    connection.connect(sock)
    send(connection, {"v": 1, "id": "hello", "op": "hello", "args": {"min_version": 1, "max_version": 1}})
    assert receive(connection)["ok"]
    return connection


process = start()
try:
    assert os.stat(os.path.dirname(sock)).st_mode & 0o777 == 0o700
    assert os.stat(sock).st_mode & 0o777 == 0o600

    status = subprocess.run([cli, "--socket", sock, "--json", "status"], check=True, text=True, capture_output=True)
    assert json.loads(status.stdout)["result"]["item_count"] == 4

    listing = subprocess.run([cli, "--socket", sock, "--json", "list", "--limit", "10"], check=True, text=True, capture_output=True)
    image = next(item for item in json.loads(listing.stdout)["result"]["items"] if item["kind"] == "image")
    preview = subprocess.run([cli, "--socket", sock, "--json", "preview", image["id"]], check=True, text=True, capture_output=True)
    preview_result = json.loads(preview.stdout)["result"]
    assert preview_result["width"] > 0 and preview_result["height"] > 0
    assert os.path.commonpath((cache, preview_result["path"])) == cache
    assert os.stat(preview_result["path"]).st_mode & 0o777 == 0o600
    exported_path = os.path.join(root.name, "exported.png")
    exported = subprocess.run([cli, "--socket", sock, "--json", "export", image["id"], "--output", exported_path], check=True, text=True, capture_output=True)
    assert json.loads(exported.stdout)["byte_length"] == os.path.getsize(asset)
    with open(exported_path, "rb") as output, open(asset, "rb") as expected:
        assert output.read() == expected.read()
    refused = subprocess.run([cli, "--socket", sock, "export", image["id"], "--output", exported_path], text=True, capture_output=True)
    assert refused.returncode == 1

    page = subprocess.run([cli, "--socket", sock, "--json", "list", "--limit", "1"], check=True, text=True, capture_output=True)
    first = json.loads(page.stdout)
    assert len(first["result"]["items"]) == 1
    assert first["result"]["next_cursor"]

    subscriber = connect()
    writer = connect()
    send(subscriber, {"v": 1, "id": "sub", "op": "subscribe", "args": {"after_seq": first["seq"]}})
    assert receive(subscriber)["result"]["subscribed"]
    item_id = first["result"]["items"][0]["id"]
    send(writer, {"v": 1, "id": "pin", "op": "pin", "args": {"item_id": item_id}})
    pinned = receive(writer)
    assert pinned["ok"] and pinned["result"]["item"]["pinned"]
    event = receive(subscriber)
    assert event["event"] == "item_updated" and event["seq"] == pinned["seq"]
    subscriber.close()
    writer.close()

    stale = subprocess.run([cli, "--socket", sock, "--json", "list", "--cursor", first["result"]["next_cursor"]], text=True, capture_output=True)
    assert stale.returncode == 5 and json.loads(stale.stdout)["error"]["code"] == "CURSOR_STALE"

    search = subprocess.run([cli, "--socket", sock, "--json", "search", "beta"], check=True, text=True, capture_output=True)
    beta = json.loads(search.stdout)["result"]["items"][0]
    shown = subprocess.run([cli, "--socket", sock, "--json", "show", beta["id"]], check=True, text=True, capture_output=True)
    assert json.loads(shown.stdout)["result"]["item"]["preview_text"] == "beta"
    rejected_preview = subprocess.run([cli, "--socket", sock, "--json", "preview", beta["id"]], text=True, capture_output=True)
    assert rejected_preview.returncode == 1 and json.loads(rejected_preview.stdout)["error"]["code"] == "BAD_REQUEST"

    paused = subprocess.run([cli, "--socket", sock, "--json", "pause"], check=True, text=True, capture_output=True)
    assert json.loads(paused.stdout)["result"]["paused"]
    resumed = subprocess.run([cli, "--socket", sock, "--json", "resume"], check=True, text=True, capture_output=True)
    assert not json.loads(resumed.stdout)["result"]["paused"]

    subprocess.run([cli, "--socket", sock, "--json", "unpin", item_id], check=True, text=True, capture_output=True)
    removed = subprocess.run([cli, "--socket", sock, "--json", "remove", beta["id"]], check=True, text=True, capture_output=True)
    assert json.loads(removed.stdout)["result"]["removed_count"] == 1
    cleared = subprocess.run([cli, "--socket", sock, "--json", "clear", "--unpinned"], check=True, text=True, capture_output=True)
    assert json.loads(cleared.stdout)["result"]["removed_count"] == 3

    missing = subprocess.run([cli, "--socket", sock, "--json", "show", "0" * 32], text=True, capture_output=True)
    assert missing.returncode == 4

    malformed = socket.socket(socket.AF_UNIX)
    malformed.settimeout(3)
    malformed.connect(sock)
    body = b'{"v":1,"v":1}'
    malformed.sendall(struct.pack(">I", len(body)) + body)
    assert malformed.recv(1) == b""
    malformed.close()

    final_status = subprocess.run([cli, "--socket", sock, "--json", "status"], check=True, text=True, capture_output=True)
    sequence = json.loads(final_status.stdout)["seq"]
finally:
    stop(process)

process = start()
try:
    subscriber = connect()
    send(subscriber, {"v": 1, "id": "sub", "op": "subscribe", "args": {"after_seq": sequence}})
    reply = receive(subscriber)
    assert reply["result"]["current_seq"] > sequence
    assert receive(subscriber)["event"] == "resync_required"
    subscriber.close()
finally:
    stop(process)
    root.cleanup()

print("IPC integration: 28 passed")
