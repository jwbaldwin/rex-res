import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import time


REX = os.environ.get("REX_RES_REX") or shutil.which("rex")
PLUGIN = Path(__file__).resolve().parents[1] / "lua/plugin.lua"
TEMPORARY = tempfile.TemporaryDirectory(prefix="rex-lua-", dir=os.environ.get("REX_RES_TEST_ROOT"))
ROOT = Path(TEMPORARY.name)
ENDPOINT = "unix://" + str(ROOT / "rex.sock")
CONFIG = ROOT / "init.lua"
STATE = ROOT / "snapshots"
SNAPSHOT = STATE / "workspace.json"


def cli(*args, check=True):
    result = subprocess.run(
        [REX, "--server", ENDPOINT, "--autostart=false", "--timeout", "30s", *args],
        capture_output=True, text=True, timeout=40,
        env={k: v for k, v in os.environ.items() if not k.startswith("REX_")},
    )
    if check and result.returncode:
        raise AssertionError(result.stderr)
    return result


def api(method, **args):
    return json.loads(cli("api", "call", method, json.dumps(args)).stdout)


def action(name):
    return json.loads(cli("do", name, "--json").stdout)


def wait_for(predicate):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError("Timed out waiting for terminal")


def start(number):
    with (ROOT / f"server-{number}.log").open("w") as log:
        process = subprocess.Popen(
            [REX, "server", "run", "--listen", ENDPOINT, "--config", str(CONFIG),
             "--state-dir", str(ROOT / f"server-{number}")],
            stdin=subprocess.DEVNULL, stdout=log, stderr=log,
            env={k: v for k, v in os.environ.items() if not k.startswith("REX_")},
        )
    try:
        wait_for(lambda: cli("api", "call", "server.status", check=False).returncode == 0)
    except BaseException:
        process.terminate()
        process.wait(timeout=10)
        raise
    return process


def blocks(view):
    return [block for window in view.get("windows", []) for layer in window["layers"] for block in layer["blocks"]]


def terminal(session, block):
    return api("com.superlogical.terminal.process", session_id=session, block_id=block, args={})


def foreground(session, block, name):
    process = terminal(session, block)
    active = process.get("foreground") or process.get("child") or {}
    if active.get("name") == "login":
        rows = subprocess.check_output(["/bin/ps", "-axww", "-o", "pid=,ppid=,comm="], text=True)
        for row in rows.splitlines():
            pid, parent, executable = row.strip().split(None, 2)
            if int(parent) == active["pid"]:
                return Path(executable).name.lstrip("-") == name
    return active.get("name") == name


def layout(command=None, initial_input=None):
    options = {"cwd": str(ROOT)}
    if command:
        options.update(command=command, shell="none", exit={"on_completion": False})
    if initial_input:
        options["initial_input"] = initial_input
    return {"block": {"flavor": "com.superlogical.terminal.shell", "options": options}}


def shape(node):
    if "block_id" in node:
        return "pane"
    split = node["split"]
    return (split["direction"], round(split["ratio"], 3), shape(split["before"]), shape(split["after"]))


def run():
    CONFIG.write_text(f"dofile({json.dumps(str(PLUGIN))}).setup {{ state_dir = {json.dumps(str(STATE))}, programs = {{ 'sleep' }} }}\n")
    process = start(1)
    try:
        probe = api("session.create", label="initial-input", initial_windows=[{
            "window_label": "probe", "layout": layout(initial_input=" /bin/sleep 119\r")
        }])
        probe_id = probe["initial_windows"][0]["block_ids"][0]
        wait_for(lambda: foreground(probe["session_id"], probe_id, "sleep"))
        api("session.destroy", session_id=probe["session_id"])

        logfile = ROOT / "tail.log"
        logfile.write_text("test\n")
        split = {"split": {"direction": "horizontal", "ratio": 0.3,
            "before": layout(["/bin/sleep", "121"]),
            "after": {"split": {"direction": "vertical", "ratio": 0.6,
                "before": layout(["/bin/sleep", "122"]), "after": layout(["/usr/bin/tail", "-f", str(logfile)])}}}}
        one = api("session.create", label="one", initial_windows=[{"window_label": "work", "layout": split}])
        session = one["session_id"]
        window = one["initial_windows"][0]
        api("session.new_layer", session_id=session, window_id=window["window_id"], bounds=[0.1, 0.2, 0.4, 0.5], layout=layout(), focus=False)
        two = api("session.create", label="two", initial_windows=[{"window_label": "shell", "layout": layout()}])
        for block, name in zip(window["block_ids"], ["sleep", "sleep", "tail"]):
            wait_for(lambda: foreground(session, block, name))
        shell_id = two["initial_windows"][0]["block_ids"][0]
        wait_for(lambda: foreground(two["session_id"], shell_id, "zsh"))
        api("session.focus_block", session_id=session, block_id=window["block_ids"][1])
        api("session.set_block_label", session_id=session, block_id=window["block_ids"][2], label="log viewer")
        api("session.zoom_block", session_id=session, block_id=window["block_ids"][1], zoom=True)
        original = api("session.view", session_id=session)
        assert "2 sessions and 5 panes" in action("res_save")
        assert stat.S_IMODE(STATE.stat().st_mode) == 0o700
        assert stat.S_IMODE(SNAPSHOT.stat().st_mode) == 0o600
        saved = SNAPSHOT.read_bytes()
        snapshot = json.loads(saved)
        panes = []

        def collect(node):
            if "pane" in node:
                panes.append(node["pane"])
            else:
                collect(node["split"]["before"])
                collect(node["split"]["after"])

        for entry in snapshot["sessions"]:
            for tab in entry["windows"]:
                for layer in tab["layers"]:
                    collect(layer["layout"])
        assert sum("command" in pane for pane in panes) == 3, panes
        assert all(pane["cwd"] == str(ROOT) for pane in panes), panes
        pids = [terminal(session, b)["foreground"]["pid"] for b in window["block_ids"]]
        assert "Created 0 panes" in action("res_restore")
        assert pids == [terminal(session, b)["foreground"]["pid"] for b in window["block_ids"]]

        duplicate = api("session.create", label="one")
        assert cli("do", "res_save", check=False).returncode != 0
        assert SNAPSHOT.read_bytes() == saved
        api("session.destroy", session_id=duplicate["session_id"])
        cli("server", "stop")
        process.wait(timeout=10)
        process = start(2)
        assert "Created 5 panes; replayed 2 commands; skipped 1" in action("res_restore")
        listed = api("session.list")["sessions"]
        assert [s["label"] for s in listed] == ["one", "two"]
        session = listed[0]["session_id"]
        restored = api("session.view", session_id=session)
        assert shape(restored["windows"][0]["layers"][0]["layout"]) == shape(original["windows"][0]["layers"][0]["layout"])
        assert restored["windows"][0]["layers"][1]["bounds"] == [0.1, 0.2, 0.4, 0.5]
        restored_ids = [b["block_id"] for b in blocks(restored)]
        for block in restored_ids[:2]:
            wait_for(lambda: foreground(session, block, "sleep"))
        assert restored["windows"][0]["focused_block_id"] == restored_ids[1]
        assert restored["windows"][0]["zoomed_block_id"] == restored_ids[1]
        wait_for(lambda: foreground(session, restored_ids[2], "zsh"))
        assert "Created 0 panes" in action("res_restore")
        assert SNAPSHOT.read_bytes() == saved

        api("block.close", session_id=session, block_id=restored_ids[2])
        before = terminal(session, restored_ids[0])["foreground"]["pid"]
        assert "Created 1 panes" in action("res_restore")
        assert terminal(session, restored_ids[0])["foreground"]["pid"] == before
        assert len(blocks(api("session.view", session_id=session))) == 4
        assert any(b["label"] == "log viewer" for b in blocks(api("session.view", session_id=session)))
        assert "Created 0 panes" in action("res_restore")

        api("session.close_window", session_id=session, window_id=restored["windows"][0]["window_id"])
        assert "Created 4 panes" in action("res_restore")
        assert "Created 0 panes" in action("res_restore")

        SNAPSHOT.write_text('{"format":"rex-res-lua","version":1,"sessions":[{"label":"bad","windows":[{}]}]}')
        count = len(api("session.list")["sessions"])
        assert cli("do", "res_restore", check=False).returncode != 0
        assert len(api("session.list")["sessions"]) == count
        SNAPSHOT.write_bytes(saved)
        assert "2 sessions and 5 panes" in action("res_status")

        CONFIG.write_text(f"dofile({json.dumps(str(PLUGIN))}).setup {{ state_dir = {json.dumps(str(STATE))}, programs = {{}} }}\n")
        api("server.config_reload")
        api("session.destroy", session_id=session)
        assert "Created 4 panes; replayed 0 commands; skipped 3" in action("res_restore")
        recreated = next(s for s in api("session.list")["sessions"] if s["label"] == "one")
        for block in blocks(api("session.view", session_id=recreated["session_id"])):
            wait_for(lambda: foreground(recreated["session_id"], block["block_id"], "zsh"))
        for entry in api("session.list")["sessions"]:
            api("session.destroy", session_id=entry["session_id"])
        assert "0 sessions and 0 panes" in action("res_save")
        assert "Created 0 panes" in action("res_restore")
        print(f"Lua integration passed: {ROOT}")
    finally:
        try:
            cli("server", "stop", check=False)
        finally:
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=10)


if __name__ == "__main__":
    try:
        run()
    finally:
        TEMPORARY.cleanup()
