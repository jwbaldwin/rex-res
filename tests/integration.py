import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


REX = os.environ.get("REX_RES_REX") or shutil.which("rex")
PLUGIN = Path(__file__).resolve().parents[1] / "lua/plugin.lua"
TEMPORARY = tempfile.TemporaryDirectory(prefix="rex-res-", dir=os.environ.get("REX_RES_TEST_ROOT"))
ROOT = Path(TEMPORARY.name).resolve()
WORK = ROOT / "work"
ELSEWHERE = ROOT / "elsewhere"
ENDPOINT = "unix://" + str(ROOT / "rex.sock")
CONFIG = ROOT / "init.lua"
STATE = ROOT / "snapshots"
SNAPSHOT = STATE / "workspace.json"
ENV = {k: v for k, v in os.environ.items() if not k.startswith("REX_")}
TERMINAL = "com.superlogical.terminal"

CONFIG_TEXT = f"""
local execute = rex.exec
local notifications = {{}}
rex.exec = function(argv, options)
  if argv[1] == "/usr/bin/osascript" then
    notifications[#notifications + 1] = {{ title = argv[4], subtitle = argv[5], message = argv[6] }}
    return {{ ok = true, stdout = "", stderr = "" }}
  end
  return execute(argv, options)
end
rex.action {{ name = "test_notifications", title = "Test Notifications", run = function() return notifications end }}
dofile({json.dumps(str(PLUGIN))}).setup {{ state_dir = {json.dumps(str(STATE))}, programs = {{ "sleep", "tail" }} }}
"""


def cli(*args, check=True):
    result = subprocess.run(
        [REX, "--server", ENDPOINT, "--autostart=false", "--timeout", "30s", *args],
        capture_output=True, text=True, timeout=40, env=ENV,
    )
    if check and result.returncode:
        raise AssertionError(result.stderr)
    return result


def api(method, **args):
    return json.loads(cli("api", "call", method, json.dumps(args)).stdout)


def action(name, *args, origin="cli"):
    return json.loads(cli("do", name, *args, "--origin", origin, "--json").stdout)


def failed_action(name):
    result = cli("do", name, check=False)
    assert result.returncode != 0, result.stdout
    return result.stderr


def wait_for(predicate, what):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    raise AssertionError("Timed out waiting for " + what)


def start():
    log = (ROOT / "server.log").open("a")
    process = subprocess.Popen(
        [REX, "server", "run", "--listen", ENDPOINT, "--config", str(CONFIG), "--state-dir", str(ROOT / "server")],
        stdin=subprocess.DEVNULL, stdout=log, stderr=log, env=ENV,
    )
    wait_for(lambda: cli("api", "call", "server.status", check=False).returncode == 0, "the server")
    return process


def stop(process):
    cli("server", "stop", check=False)
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.terminate()
        process.wait(timeout=10)


def foreground(session, block):
    process = api(f"{TERMINAL}.process", session_id=session, block_id=block, args={})
    return process.get("foreground") or {}


def running(session, block, name):
    return foreground(session, block).get("name") == name


def at_shell(session, block):
    return foreground(session, block).get("name") in ("zsh", "bash", "fish", "sh")


def type_into(session, block, text):
    api(f"{TERMINAL}.write", session_id=session, block_id=block, args={"data": text + "\r"})


def shell(cwd=WORK):
    return {"block": {"flavor": f"{TERMINAL}.shell", "options": {"cwd": str(cwd)}}}


def snapshot():
    return json.loads(SNAPSHOT.read_text())


def run():
    WORK.mkdir()
    ELSEWHERE.mkdir()
    (WORK / "app.log").write_text("test\n")
    CONFIG.write_text(CONFIG_TEXT)
    process = start()
    try:
        layout = {"split": {"direction": "horizontal", "ratio": 0.4, "before": shell(),
            "after": {"split": {"direction": "vertical", "ratio": 0.5, "before": shell(), "after": shell()}}}}
        one = api("session.create", label="one", initial_windows=[{"window_label": "work", "layout": layout}])
        session = one["session_id"]
        sleeper, tailer, idle = one["initial_windows"][0]["block_ids"]
        two = api("session.create", label="two", initial_windows=[{"window_label": "other", "layout": shell(ELSEWHERE)}])
        other_session = two["session_id"]
        unlisted = two["initial_windows"][0]["block_ids"][0]
        for s, b in [(session, sleeper), (session, tailer), (session, idle), (other_session, unlisted)]:
            wait_for(lambda: at_shell(s, b), "a shell")
        type_into(session, sleeper, "sleep 301")
        type_into(session, tailer, "tail -f app.log")
        type_into(other_session, unlisted, "cat")
        wait_for(lambda: running(session, sleeper, "sleep"), "sleep")
        wait_for(lambda: running(session, tailer, "tail"), "tail")
        wait_for(lambda: running(other_session, unlisted, "cat"), "cat")

        saved_message = action("res_save", origin="palette")
        notice = action("test_notifications")[-1]
        assert notice == {"title": "Rex Resurrect", "subtitle": "Saved 2 programs", "message": "sleep, tail"}, notice
        assert saved_message == "Saved 2 programs\nsleep, tail", saved_message
        assert oct(STATE.stat().st_mode & 0o777) == "0o700"
        panes = {p["block_id"]: p for p in snapshot()["panes"]}
        assert panes.keys() == {sleeper, tailer}, panes
        assert panes[sleeper]["command"] == "sleep 301" and panes[sleeper]["cwd"] == str(WORK)
        assert panes[tailer]["command"] == "tail -f app.log" and panes[tailer]["session"] == "one"

        assert action("res_restore") == "Started 0 programs\n2 panes already busy · 0 panes gone"
        assert "2 programs saved" in action("res_status") and "waiting" not in action("res_status")

        stop(process)
        process = start()
        assert [s["label"] for s in api("session.list")["sessions"]] == ["one", "two"]
        for b in (sleeper, tailer, idle):
            wait_for(lambda: at_shell(session, b), "a restored shell")
        assert "waiting to restore" in action("res_status")

        before = SNAPSHOT.read_bytes()
        assert "Run Restore first" in failed_action("res_save")
        assert SNAPSHOT.read_bytes() == before

        type_into(session, sleeper, "cd " + str(ELSEWHERE))
        wait_for(lambda: foreground(session, sleeper).get("cwd") == str(ELSEWHERE), "cd")
        assert action("res_restore") == "Started 2 programs\n0 panes already busy · 0 panes gone"
        wait_for(lambda: running(session, sleeper, "sleep"), "restored sleep")
        wait_for(lambda: running(session, tailer, "tail"), "restored tail")
        assert foreground(session, sleeper)["cwd"] == str(WORK)
        assert at_shell(session, idle) and at_shell(other_session, unlisted)
        assert action("res_restore") == "Started 0 programs\n2 panes already busy · 0 panes gone"
        assert "waiting" not in action("res_status")

        api("block.close", session_id=session, block_id=tailer)
        assert action("res_restore") == "Started 0 programs\n1 panes already busy · 1 panes gone"
        assert action("res_save") == "Saved 1 programs\nsleep"

        stop(process)
        process = start()
        assert action("res_save", "force=true") == "Saved 0 programs\nnothing running"

        SNAPSHOT.write_text('{"format":"rex-res-lua","version":1,"sessions":[]}')
        assert "run Save to replace it" in failed_action("res_restore")
        assert action("res_save") == "Saved 0 programs\nnothing running"
        SNAPSHOT.write_text(json.dumps({"format": "rex-res", "version": 2, "server": "x",
            "panes": [{"block_id": sleeper, "command": "sleep 1\rrm -rf ~"}]}))
        assert "Invalid saved command" in failed_action("res_restore")
        print(f"rex-res integration passed: {ROOT}")
    finally:
        stop(process)


if __name__ == "__main__":
    try:
        run()
    finally:
        TEMPORARY.cleanup()
