#!/usr/bin/env python3
"""End-to-end check of the real FarsideWatchdog binary against a stand-in host app.

Only processes started here are signalled. State lives under the fixture's own bundle id.
"""
import glob, json, os, shutil, signal, subprocess, sys, time

APP = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else sys.exit("usage: drive.py WatchdogFixture.app")
HERE = os.path.dirname(APP)
HELPER = os.path.join(APP, "Contents/MacOS/FarsideWatchdog")
STATE_ROOT = os.path.expanduser("~/Library/Application Support/com.roshan.PocketDesk.WatchdogFixture")
results = []


def state_dir():
    dirs = glob.glob(os.path.join(STATE_ROOT, "Watchdog", "*"))
    return dirs[0] if dirs else None


def read(name):
    d = state_dir()
    if not d:
        return None
    try:
        with open(os.path.join(d, name)) as f:
            return json.load(f)
    except Exception:
        return None


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def wait(predicate, timeout, step=0.2):
    end = time.time() + timeout
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print(("PASS " if ok else "FAIL ") + name + (f" — {detail}" if detail else ""), flush=True)


def command(word):
    d = state_dir()
    with open(os.path.join(d, "command"), "w") as f:
        f.write(word)


def launches():
    d = state_dir()
    try:
        with open(os.path.join(d, "launches.log")) as f:
            return f.read().strip().splitlines()
    except Exception:
        return []


def open_fixture():
    subprocess.run(["/usr/bin/open", "-g", "-j", APP], check=True)
    return wait(lambda: (lambda r: r if r and alive(r["pid"]) and not r.get("cleanExit") else None)(read("host.json")), 10)


def running_record(previous_launch):
    r = read("host.json")
    if r and r["launchID"] != previous_launch and alive(r["pid"]):
        return r
    return None


def start_helper(log_name):
    log = open(os.path.join(HERE, log_name), "w")
    return subprocess.Popen([HELPER], stdout=log, stderr=subprocess.STDOUT)


def stop_helper(helper):
    helper.send_signal(signal.SIGTERM)
    try:
        helper.wait(5)
    except subprocess.TimeoutExpired:
        helper.kill()


def quit_fixture():
    r = read("host.json")
    if r and alive(r["pid"]) and not r.get("cleanExit"):
        command("quit")
        wait(lambda: not alive(r["pid"]), 5)


shutil.rmtree(STATE_ROOT, ignore_errors=True)

# 1-3. Crash → relaunch, twice; third crash → one safe-mode launch; fourth → nothing.
first = open_fixture()
check("fixture host started", first)
helper = start_helper("helper-crashloop.log")
time.sleep(1.5)
check("helper stays idle while the host is healthy", read("watchdog.json") is None or read("watchdog.json").get("relaunches", 0) == 0)

current = first
for attempt in (1, 2):
    command("crash")
    started = time.time()
    nxt = wait(lambda: running_record(current["launchID"]), 12)
    check(f"crash {attempt} relaunched the host", nxt, f"{time.time() - started:.1f}s")
    check(f"relaunch {attempt} carries --farside-recovered", nxt and "--farside-recovered" in launches()[-1], launches()[-1] if launches() else "")
    current = nxt or current

command("crash")
nxt = wait(lambda: running_record(current["launchID"]), 12)
check("third crash in five minutes opens once in safe mode", nxt and "--farside-safe-mode" in launches()[-1], launches()[-1] if launches() else "")
ledger = read("watchdog.json") or {}
check("ledger records the crash-loop stop", ledger.get("stoppedAt"), json.dumps({k: ledger.get(k) for k in ("relaunches", "stoppedAt", "lastExit")}))
current = nxt or current

command("crash")
time.sleep(6)
r = read("host.json")
check("while stopped, a further crash is not relaunched", r and r["launchID"] == current["launchID"] and not alive(r["pid"]))
check("exactly four launches were made", len(launches()) == 4, f"{len(launches())} launches")
stop_helper(helper)

# 4. Clean quit is respected.
shutil.rmtree(STATE_ROOT, ignore_errors=True)
first = open_fixture()
helper = start_helper("helper-quit.log")
time.sleep(1.5)
command("quit")
time.sleep(6)
r = read("host.json")
check("a clean quit is never relaunched", r and r.get("cleanExit") and not alive(r["pid"]) and len(launches()) == 1)
stop_helper(helper)

# 5. A hung host (heartbeat stops; curtain up → 6 s) is ended and relaunched.
shutil.rmtree(STATE_ROOT, ignore_errors=True)
first = open_fixture()
helper = start_helper("helper-hang.log")
time.sleep(1.5)
command("hang")
started = time.time()
nxt = wait(lambda: running_record(first["launchID"]), 20)
check("a hung host is ended and relaunched", nxt, f"{time.time() - started:.1f}s after the heartbeat stopped")
ledger = read("watchdog.json") or {}
check("the exit is recorded as a hang", ledger.get("lastExit") == "hang", str(ledger.get("lastExit")))
check("the hung process is gone", not alive(first["pid"]))
stop_helper(helper)
quit_fixture()

shutil.rmtree(STATE_ROOT, ignore_errors=True)
failed = [n for n, ok, _ in results if not ok]
print(f"\n{len(results) - len(failed)}/{len(results)} checks passed")
sys.exit(1 if failed else 0)
