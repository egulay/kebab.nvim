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

def click(col, row, count=1, gap=0.08):
    seq = []
    for _ in range(count):
        seq += [sgr(0, col, row, True), sgr(0, col, row, False), gap]
    return seq

if __name__ == "__main__":
    spec = json.load(open(sys.argv[1]))
    acts = []
    for a in spec["actions"]:
        if a["kind"] == "wait":
            acts.append(a["seconds"])
        elif a["kind"] == "click":
            acts += click(a["col"], a["row"], a.get("count", 1))
        elif a["kind"] == "keys":
            acts.append(a["text"])
    raw = run(spec["nvim_args"], acts, spec["report"], idle=spec.get("idle", 8), limit=spec.get("limit", 120))
    sys.stdout.write("--- report exists: %s\n" % os.path.exists(spec["report"]))
