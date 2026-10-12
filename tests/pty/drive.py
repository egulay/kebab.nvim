"""Drive a real Neovim in a pty and send real terminal mouse sequences."""
import os, pty, select, sys, time, json

def run(nvim_args, actions, report, idle=1.0, limit=120):
    pid, fd = pty.fork()
    if pid == 0:
        env = dict(os.environ, TERM="xterm-256color", REPORT=report, LINES="40", COLUMNS="120")
        os.execvpe("nvim", ["nvim"] + nvim_args, env)
    out = bytearray()
    start = time.time()
    def pump(seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.1)
            if r:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    return False
                if not chunk:
                    return False
                out.extend(chunk)
        return True
    pump(idle)
    for act in actions:
        if isinstance(act, (int, float)):
            pump(act)
        elif isinstance(act, tuple) and act[0] == "target":
            spec = act[1]
            row, col = read_target(spec["file"], spec["name"], spec.get("timeout", 40))
            for part in click(col, row, spec.get("count", 1), button=spec.get("button", 0)):
                if isinstance(part, (int, float)):
                    pump(part)
                else:
                    os.write(fd, part.encode())
        else:
            os.write(fd, act if isinstance(act, bytes) else act.encode())
    while time.time() - start < limit:
        if not pump(0.5):
            break
        if os.path.exists(report):
            pump(1.0)
            break
    try:
        os.kill(pid, 15)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0) if False else None
    return bytes(out)

def sgr(button, col, row, press=True):
    """SGR mouse report: 1-based col/row, button 0 = left."""
    return "\033[<%d;%d;%d%s" % (button, col, row, "M" if press else "m")

def click(col, row, count=1, gap=0.08, button=0):
    """button 0 = left, 1 = middle, 2 = right."""
    seq = []
    for _ in range(count):
        seq += [sgr(button, col, row, True), sgr(button, col, row, False), gap]
    return seq

def read_target(path, name, timeout=40.0):
    """Wait for the editor to say where `name` is on screen, as "name row col".

    The editor rewrites this file as the layout changes, so a click is aimed at
    where the thing is *now*. Hardcoding screen rows made one fixture change
    break five unrelated cases.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with open(path) as fh:
                for line in fh:
                    parts = line.split()
                    if len(parts) == 3 and parts[0] == name:
                        return int(parts[1]), int(parts[2])
        except OSError:
            pass
        time.sleep(0.2)
    raise SystemExit("the editor never reported a target called %r" % name)


if __name__ == "__main__":
    spec = json.load(open(sys.argv[1]))
    acts = []
    for a in spec["actions"]:
        if a["kind"] == "wait":
            acts.append(a["seconds"])
        elif a["kind"] == "click":
            acts += click(a["col"], a["row"], a.get("count", 1), button=a.get("button", 0))
        elif a["kind"] == "click_target":
            # resolved while the editor is running, not now
            acts.append(("target", a))
        elif a["kind"] == "keys":
            acts.append(a["text"])
    raw = run(spec["nvim_args"], acts, spec["report"], idle=spec.get("idle", 8), limit=spec.get("limit", 120))
    sys.stdout.write("--- report exists: %s\n" % os.path.exists(spec["report"]))
