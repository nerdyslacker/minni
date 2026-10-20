#!/usr/bin/env python3
import concurrent.futures
import json
import os
import statistics
import subprocess
import sys
import tempfile
import time


daemon, cli = sys.argv[1:3]
idle_seconds = int(os.environ.get("MINNI_IDLE_SECONDS", "300"))
root = tempfile.TemporaryDirectory(prefix="minni-release-")
state = os.path.join(root.name, "state")
cache = os.path.join(root.name, "cache")
run_dir = os.path.join(root.name, "run")
sock = os.path.join(run_dir, "minni.sock")
config = os.path.join(root.name, "config")
os.mkdir(run_dir, 0o700)
with open(config, "w", encoding="utf-8") as output:
    output.write("max_unpinned_items=250\n")


def command(*arguments, check=True):
    result = subprocess.run(
        [cli, "--socket", sock, "--json", *arguments],
        text=True,
        capture_output=True,
        check=check,
    )
    return json.loads(result.stdout) if result.stdout else None


def start():
    started = time.monotonic_ns()
    process = subprocess.Popen(
        [daemon, "--config", config, "--state-dir", state, "--cache-dir", cache, "--socket", sock],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    for _ in range(500):
        if process.poll() is not None:
            raise RuntimeError(process.stderr.read())
        if os.path.exists(sock):
            try:
                command("status")
                return process, (time.monotonic_ns() - started) / 1_000_000
            except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
                pass
        time.sleep(0.005)
    raise RuntimeError("daemon startup timed out")


def stop(process):
    process.terminate()
    process.wait(timeout=5)


def list_items():
    return command("list", "--limit", "200")["result"]["items"]


def wait_text(value):
    for _ in range(300):
        items = command("search", value, "--limit", "10")["result"]["items"]
        if any(item.get("preview_text") == value for item in items):
            return
        time.sleep(0.005)
    raise RuntimeError(f"capture timed out: {value}")


def publish(data, target, expected_text=None, expect_stored=True):
    owner = subprocess.Popen(
        ["xclip", "-silent", "-loops", "2", "-selection", "clipboard", "-target", target, "-in"],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    owner.stdin.write(data)
    owner.stdin.close()
    if not expect_stored:
        owner.wait(timeout=5)
        return
    if expected_text is not None:
        wait_text(expected_text)
    else:
        before = time.monotonic() + 5
        while time.monotonic() < before:
            if any(item["mime_type"] == target for item in list_items()):
                break
            time.sleep(0.01)
        else:
            owner.terminate()
            owner.wait(timeout=5)
            raise RuntimeError(f"image capture timed out: {target}; items={list_items()[:3]}")
    owner.wait(timeout=5)


def memory(pid):
    values = {}
    with open(f"/proc/{pid}/smaps_rollup", encoding="ascii") as source:
        for line in source:
            name, _, rest = line.partition(":")
            if name in ("Rss", "Pss", "Private_Clean", "Private_Dirty"):
                values[f"{name.lower()}_kib"] = int(rest.split()[0])
    return values


def activity(pid):
    with open(f"/proc/{pid}/stat", encoding="ascii") as source:
        fields = source.read().split(") ", 1)[1].split()
    ticks = int(fields[11]) + int(fields[12])
    switches = 0
    with open(f"/proc/{pid}/status", encoding="ascii") as source:
        for line in source:
            if line.startswith(("voluntary_ctxt_switches:", "nonvoluntary_ctxt_switches:")):
                switches += int(line.split()[1])
    return ticks, switches


process = None
try:
    process, first_start = start()
    baseline_memory = memory(process.pid)

    capture_started = time.monotonic_ns()
    capture_timings = []
    for index in range(100):
        value = f"phase6-{index:03d}-աշխարհ"
        item_started = time.monotonic_ns()
        publish(value.encode(), "UTF8_STRING", value)
        capture_timings.append((time.monotonic_ns() - item_started) / 1_000_000)
    capture_ms = (time.monotonic_ns() - capture_started) / 1_000_000
    assert command("status")["result"]["item_count"] == 100

    for _ in range(20):
        publish(b"phase6-099-\xd5\xa1\xd5\xb7\xd5\xad\xd5\xa1\xd6\x80\xd5\xb0", "UTF8_STRING", "phase6-099-աշխարհ")
    assert command("status")["result"]["item_count"] == 100

    command("pause")
    publish(b"paused-value", "UTF8_STRING", expect_stored=False)
    time.sleep(0.1)
    assert command("status")["result"]["item_count"] == 100
    command("resume")

    png = os.path.join(root.name, "image.png")
    jpeg = os.path.join(root.name, "image.jpg")
    subprocess.run(["magick", "-size", "512x384", "plasma:fractal", f"PNG24:{png}"], check=True)
    subprocess.run(["magick", png, "-quality", "91", jpeg], check=True)
    with open(png, "rb") as source:
        publish(source.read(), "image/png")
    with open(jpeg, "rb") as source:
        publish(source.read(), "image/jpeg")

    images = [item for item in list_items() if item["kind"] == "image"]
    assert len(images) == 2
    command("pin", images[0]["id"])
    preview = command("preview", images[0]["id"])["result"]
    assert os.path.isfile(preview["path"]) and os.stat(preview["path"]).st_mode & 0o777 == 0o600

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        responses = list(executor.map(lambda _: command("status"), range(200)))
    assert all(response["ok"] for response in responses)

    loaded_memory = memory(process.pid)
    ticks_before, switches_before = activity(process.pid)
    time.sleep(idle_seconds)
    ticks_after, switches_after = activity(process.pid)
    clock_ticks = os.sysconf("SC_CLK_TCK")

    startup_ms = [first_start]
    for _ in range(10):
        stop(process)
        process, elapsed = start()
        startup_ms.append(elapsed)
        pinned = command("list", "--pinned")["result"]["items"]
        assert len(pinned) == 1 and pinned[0]["id"] == images[0]["id"]

    deletable = [item for item in list_items() if not item["pinned"]][:50]
    delete_started = time.monotonic_ns()
    for item in deletable:
        command("remove", item["id"])
    delete_ms = (time.monotonic_ns() - delete_started) / 1_000_000
    command("clear", "--unpinned")
    assert command("status")["result"]["item_count"] == 1
    command("clear", "--all")
    assert command("status")["result"]["item_count"] == 0

    result = {
        "captures": 100,
        "capture_total_ms": round(capture_ms, 3),
        "capture_mean_ms": round(statistics.mean(capture_timings), 3),
        "capture_median_ms": round(statistics.median(capture_timings), 3),
        "capture_max_ms": round(max(capture_timings), 3),
        "concurrent_requests": len(responses),
        "delete_count": len(deletable),
        "delete_total_ms": round(delete_ms, 3),
        "restart_cycles": 10,
        "startup_ms": {
            "min": round(min(startup_ms), 3),
            "median": round(statistics.median(startup_ms), 3),
            "max": round(max(startup_ms), 3),
        },
        "memory_baseline": baseline_memory,
        "memory_loaded": loaded_memory,
        "idle_seconds": idle_seconds,
        "idle_cpu_seconds": round((ticks_after - ticks_before) / clock_ticks, 6),
        "idle_context_switches": switches_after - switches_before,
    }
    print(json.dumps(result, indent=2, sort_keys=True))
finally:
    if process is not None and process.poll() is None:
        stop(process)
    root.cleanup()
