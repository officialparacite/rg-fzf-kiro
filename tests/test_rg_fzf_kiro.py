#!/usr/bin/env python3
"""End-to-end tests for rg-fzf-kiro.

Builds a fake Kiro sessions folder, runs the real script in a pseudo-terminal, sends
keypresses, and reads results back through fzf's --listen API. A fake kiro-cli records
how it was started, and background processes named kiro-cli-chat stand in for running
sessions. Nothing touches your real sessions or index.

Usage: python3 tests/test_rg_fzf_kiro.py     (needs rg, fzf, jq, perl, bat)
"""
import calendar, fcntl, json, urllib.error, os, pty, re, select, shutil, signal, struct, subprocess, sys, tempfile, termios, time, urllib.request

signal.alarm(840)  # hard stop so the suite can never hang
SCRIPT = os.environ.get("RGFK_SCRIPT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "rg-fzf-kiro.sh")
PORT = int(os.environ.get("RGFK_PORT", "6380"))
ESC_RE = re.compile(rb"\x1b\[[0-9;?]*[a-zA-Z]")

H = os.path.realpath(tempfile.mkdtemp())   # harness root; also used as $HOME
ROOT = f"{H}/sessions"                     # $KIRO_SESSIONS_DIR: V3 sessions in <workspace>/<id>/
SESS = f"{ROOT}/cli"                       # V2 sessions
CACHE = f"{H}/cache"
WORK = f"{H}/work dir"                     # a session directory, with a space
DEEP = f"{H}/proj/a b/c"                   # nested directory
OUT = "/var/rgfk-outside-home"             # not under $HOME: shown as an absolute path
for d in (SESS, WORK, DEEP, f"{H}/bin"):
    os.makedirs(d)

fails = 0
def check(name, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else f"  -> {str(detail)[:500]}"))
    fails += 0 if cond else 1

# ---------- background processes ----------
# Started detached (the launching shell exits at once), so the system reaps them when
# they end, like a real kiro-cli. A child of this test would linger as a zombie, which
# still looks alive to kill -0.
def spawn(cmd):
    r = subprocess.run(["bash", "-c", f"( {cmd} ) </dev/null >/dev/null 2>&1 & echo $!"], capture_output=True, text=True)
    return int(r.stdout)
def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False
LIVE = spawn("exec -a kiro-cli-chat sleep 900")             # a running kiro-cli
LIVE2 = spawn("exec -a kiro-cli-chat sleep 900")            # a second running kiro-cli
STUBBORN = spawn("exec -a kiro-cli-chat sleep 900")         # a third
OTHER = spawn("exec sleep 900")                              # unrelated program reusing a dead kiro's pid
DEAD = spawn("exit 0")                                       # a pid that no longer exists
time.sleep(0.5)
def command_of(pid):
    r = subprocess.run(["bash", "-c", f"ps -p {pid} -o command= 2>/dev/null || pgrep -lf . | awk '$1=={pid}'"], capture_output=True)
    return r.stdout
CAN_SEE = b"kiro-cli" in command_of(LIVE)
check("test setup: background processes running", all(alive(p) for p in (LIVE, LIVE2, STUBBORN, OTHER)) and not alive(DEAD))

# ---------- fake sessions ----------
def rec(kind, data=None):
    r = {"version": "v1", "kind": kind}
    if data is not None:
        r["data"] = data
    return json.dumps(r)
def prompt(text):
    return rec("Prompt", {"message_id": "m", "content": [{"kind": "text", "data": text}]})
def reply(text, tool=None):
    content = [{"kind": "thinking", "data": {"text": "secret thoughts"}}, {"kind": "text", "data": text}]
    if tool:
        content.append({"kind": "toolUse", "data": {"toolUseId": "t1", "name": tool[0], "input": tool[1]}})
    return rec("AssistantMessage", {"message_id": "m", "content": content})
def results(text):
    return rec("ToolResults", {"message_id": "m", "content": [
        {"kind": "toolResult", "data": {"toolUseId": "t1", "content": [{"kind": "text", "data": text}], "status": "success"}}]})

KEYS = ["a1", "b2", "c3", "d4", "e5", "f6", "aa7", "g8", "h9", "ab1", "ac2", "ad3"]
ID = {k: f"{k}{'0' * (8 - len(k))}-1111-2222-3333-444444444444" for k in KEYS}
short = {k: v[:8] for k, v in ID.items()}
CREATED = {}

def session(key, title, created, updated, lines, cwd=WORK, lock=None, **extra):
    sid = ID[key]
    CREATED[key] = created
    meta = {"session_id": sid, "cwd": cwd, "created_at": created, "updated_at": updated,
            "title": title, "session_state": {}, **extra}
    open(f"{SESS}/{sid}.json", "w").write(json.dumps(meta))
    open(f"{SESS}/{sid}.jsonl", "w").write("".join(l + "\n" for l in lines))
    if lock is not None:
        open(f"{SESS}/{sid}.lock", "w").write(json.dumps({"pid": lock, "started_at": "x"}))

session("a1", "Fix the parser bug", "2026-10-01T10:00:00Z", "2026-10-10T10:00:00Z", [
    prompt("why does the parser crash on unicode input?"),
    reply("The tokenizer splits multi-byte characters.\nUse a char iterator instead."),
    "{ this line is not json",
    prompt("thanks, that fixed it \u0007bell\u001b[31mred"),
    rec("Compaction", {"summary": "## OBJECTIVE\nFix parser unicode crash"}),
])
session("b2", "Deploy plan: prod/us-east-1 \\ rollout", "2026-10-02T10:00:00Z", "2026-10-12T10:00:00Z", [
    prompt("how do we roll out the deploy to prod safely?"),
    reply("Use a canary stage first, then promote."),
], cwd=DEEP)
session("c3", "Live chat", "2026-10-03T10:00:00Z", "2026-10-14T10:00:00Z", [
    prompt("this session is still open somewhere"), reply("Yes, it is live.")], lock=LIVE)
session("d4", "Stale lock", "2026-10-04T10:00:00Z", "2026-10-09T10:00:00Z",
        [prompt("stale lock session talks about canary too")], lock=DEAD)
session("e5", "helper task", "2026-10-05T10:00:00Z", "2026-10-13T10:00:00Z",
        [prompt("subagent instructions: find canary configs")],
        session_created_reason="subagent", parent_session_id=ID["b2"])
session("f6", "Fix the parser bug", "2026-10-06T10:00:00Z", "2026-10-11T10:00:00Z",
        [prompt("rewound copy mentions tokenizer")], session_created_reason="rewind", parent_session_id=ID["a1"])
session("aa7", None, "2026-10-07T10:00:00Z", "2026-10-15T10:00:00Z", [])          # empty, untitled
session("g8", "Reused pid", "2026-10-08T10:00:00Z", "2026-10-08T12:00:00Z",
        [prompt("lock points at an unrelated process")], lock=OTHER)
session("h9", "Stop me", "2026-09-01T10:00:00Z", "2026-10-16T09:00:00Z",
        [prompt("please stop this kiro session\n<!-- kiro · 9 -->")], lock=LIVE2)
session("ab1", "Outside home", "2026-09-02T10:00:00Z", "2026-09-05T10:00:00Z",
        [prompt("session outside the home folder")], cwd=OUT)
session("ac2", "Stubborn", "2026-09-03T10:00:00Z", "2026-09-06T10:00:00Z",
        [prompt("stubborn kiro ignores sigterm")], lock=STUBBORN)
session("ad3", "Same dir twin", "2026-10-01T10:00:00Z", "2026-09-07T10:00:00Z", [
    prompt("twin session in the same directory on the same day"),
    reply("Reading the file now.", ("read", {"path": "/src/other.rs"})),
    results("fn main() { magicToolWord }"),
    reply("wrapme " + "x" * 400 + " ZZTAILWORD"),
])
open(f"{SESS}/broken.json", "w").write("{ not json")   # unreadable metadata
open(f"{SESS}/notes.txt", "w").write("not a session")

editor_log = f"{H}/editor.log"
open(f"{H}/bin/fake-editor", "w").write(f"#!/bin/bash\nprintf '%s\\n' \"$@\" > '{editor_log}'\n")
os.chmod(f"{H}/bin/fake-editor", 0o755)

# Copies of the script that also listen on a port, so tests can read fzf's state.
# run2 is the second rg-fzf-kiro in a chain.
run, run2 = f"{H}/run.sh", f"{H}/run2.sh"
for path, port in ((run, PORT), (run2, PORT + 1)):
    open(path, "w").write(open(SCRIPT).read().replace("\nfzf \\\n", f"\nfzf --listen {port} \\\n", 1))
ENV = dict(os.environ, HOME=H, KIRO_SESSIONS_DIR=ROOT, RG_FZF_KIRO_CACHE=CACHE,
           EDITOR=f"{H}/bin/fake-editor", PATH=f"{H}/bin:" + os.environ["PATH"])
ENV.pop("XDG_CACHE_HOME", None)

def local(ts, fmt):
    """UTC timestamp from a session file -> local time, as the tool shows it."""
    return time.strftime(fmt, time.localtime(calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ"))))

class Session:
    """rg-fzf-kiro in a pseudo-terminal. cmd: a bash command line to run instead (for pipes)."""
    def __init__(self, *args, env=ENV, cmd=None, v2=True):
        self.out = b""
        self.last_key = 0
        self.port = PORT
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(H)
            if cmd:
                os.execvpe("bash", ["bash", "-c", cmd], env)
            os.execvpe("bash", ["bash", run, *(["--v2"] if v2 else []), *args], env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 170, 0, 0))
        self.pump(3)

    def pump(self, t):
        end = time.time() + t
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                try:
                    self.out += os.read(self.fd, 65536)
                except OSError:
                    return

    def key(self, b, wait=1.0):
        if b.startswith(CLR):
            # Clear the query in one step (one change event) rather than with dozens
            # of backspaces, each of which runs a helper script
            self.pump(0.1)
            urllib.request.urlopen(urllib.request.Request(f"http://localhost:{self.port}", data=b"change-query()"), timeout=10).read()
            self.last_key = time.time()
            b = b[len(CLR):]
            if not b:
                self.pump(wait)
                return
            self.pump(0.3)
        try:
            os.write(self.fd, b)
        except OSError:  # it already exited; the checks that follow will fail
            pass
        self.last_key = time.time()
        self.pump(wait)

    def api(self):
        # fzf answers 503 while it is blocked writing to the terminal, so keep reading
        # its output between tries (or isn't listening yet, as the second of a chain)
        for attempt in range(80):
            try:
                return json.load(urllib.request.urlopen(f"http://localhost:{self.port}?limit=300", timeout=5))
            except urllib.error.HTTPError as e:
                if e.code != 503 or attempt == 79:
                    raise
                self.pump(0.25)
            except urllib.error.URLError:
                if attempt == 79:
                    raise
                self.pump(0.25)

    def state(self):
        """Results once fzf has finished loading them and they stopped changing. A search
        starts a moment after a keystroke, so wait for that first."""
        self.pump(max(0, self.last_key + 1.0 - time.time()))
        last, end = None, time.time() + 20
        while True:
            d = self.api()
            cur = (d["query"], [m["text"] for m in d["matches"]])
            if not d["reading"] and cur == last or time.time() > end:
                return cur
            last = cur
            self.pump(0.4)

    def until(self, mark, needle, timeout=10):
        """Screen text since mark, once it contains needle (or after timeout)."""
        end = time.time() + timeout
        while needle not in self.screen(mark) and time.time() < end:
            self.pump(0.2)
        return self.screen(mark)

    def find(self, text, key):
        """Search for text and wait until the results are that one session's lines."""
        self.key(CLR + text)
        return self.wait_for(lambda q, m: q == text.decode() and m and set(ids(m)) == {short[key]})

    def wait_for(self, pred, timeout=20):
        """Poll the results until pred(query, matches) holds; returns the last state."""
        end = time.time() + timeout
        while True:
            cur = self.state()
            if pred(*cur) or time.time() > end:
                return cur
            self.pump(0.3)

    def screen(self, since=0):
        return ESC_RE.sub(b"", self.out[since:])

    def finish(self, keys):
        self.key(keys, 2.5)
        self.pump(1)
        os.waitpid(self.pid, 0)
        tail = self.out[self.out.rfind(b"\x1b[?1049l"):]
        return ESC_RE.sub(b"", tail).replace(b"\r", b"").strip()

CLR = b"\x00CLEAR\x00"      # key() clears the query (Ctrl-U scrolls the preview here)
fields = lambda line: line.split("\x00:")
def sid8(line):
    m = re.search(r"#([0-9a-z]{8})(?:_[A-Za-z0-9]+)?\.chat$", fields(line)[0])
    return m.group(1) if m else "?"
ids = lambda m: [sid8(x) for x in m]

def cli(*args, env=ENV):
    p = subprocess.run(["bash", SCRIPT, *args], cwd=H, env=env, capture_output=True, text=True,
                       stdin=subprocess.DEVNULL, timeout=60)
    return p.returncode, p.stdout, p.stderr

def cli_in(data, *args):
    """rg-fzf-kiro with data piped to stdin (only for runs that stop before fzf opens)."""
    p = subprocess.run(["bash", SCRIPT, *args], cwd=H, env=ENV, input=data, capture_output=True, timeout=60)
    return p.returncode, p.stderr.decode(errors="replace").strip()

def text_files():
    out = []
    for root, _, files in os.walk(f"{CACHE}/text"):
        out += [os.path.relpath(os.path.join(root, f), f"{CACHE}/text") for f in files]
    return sorted(out)

EXTRACT_JQ = re.search(r"cat > \"\$STATE/extract.jq\" << 'JQ'\n(.*?)\nJQ\n", open(SCRIPT).read(), re.S).group(1)
def extract_full(sid, path=None, asker=None):
    """What reading the whole session from scratch gives, using the script's own extractor."""
    asker = asker or ("agent" if sid == ID["e5"] else "you")
    r = subprocess.run(["jq", "-Rnr", "--arg", "asker", asker, "--argjson", "base", "0", EXTRACT_JQ],
                       stdin=open(path or f"{SESS}/{sid}.jsonl", "rb"), capture_output=True)
    return r.stdout

def index_file(key, ext):
    hits = [f for f in text_files() if f.endswith(f"#{short[key]}.{ext}")]
    return f"{CACHE}/text/{hits[0]}" if len(hits) == 1 else None

def index_matches_full(key):
    c = index_file(key, "chat")
    return bool(c) and open(c, "rb").read() == extract_full(ID[key])

def expected_files(moved_g8=False, without=()):
    where = {k: "~/work dir" for k in KEYS}
    where.update(b2="~/proj/a b/c", ab1="var/rgfk-outside-home")
    if moved_g8:
        where["g8"] = "~/moved here"
    return sorted(f"{where[k]}/{local(CREATED[k], '%Y-%m-%d')} #{short[k]}.{e}"
                  for k in KEYS if k not in without for e in ("chat",))

CACHE_PARTS = ["lock", "meta", "seen", "sessions.tsv", "state", "text", "version"]

# =====================================================================================
print("--- command line")
rc, out, err = cli("-h")
check("-h prints help", rc == 0 and "Usage:" in out and "Alt-Enter" in out and "Alt-G" in out and "Alt-K" not in out and not re.search(r"Alt-E\b", out))
check("-h lists Alt-U, Alt-R, Ctrl-O, piping, --v2 and -0", all(k in out for k in ("Alt-U", "Alt-R", "Ctrl-O", "command | rg-fzf-kiro", "--v2", "-0, --null")), out)
check("-h no longer lists Alt-T", "Alt-T" not in out and "tool output" not in out, out)
rc, out, err = cli("-x")
check("unknown option is an error", rc == 1 and "unknown option" in err, err)
def without(tool):
    """Runs rg-fzf-kiro with a PATH that has every tool it needs except one."""
    d = tempfile.mkdtemp()
    for c in ["rg", "fzf", "jq", "perl", "bat", "bash", "cat", "sed", "grep", "cut", "tr", "xargs", "mktemp", "chmod",
              "rm", "touch", "sleep", "sort", "awk", "getconf", "ps", "pgrep", "mkdir", "find"]:
        if c != tool and shutil.which(c):
            os.symlink(shutil.which(c), f"{d}/{c}")
    p = subprocess.run(["/bin/bash", SCRIPT], cwd=H, env={"PATH": d, "HOME": H, "KIRO_SESSIONS_DIR": ROOT,
                       "RG_FZF_KIRO_CACHE": f"{H}/cache-without"}, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=20)
    shutil.rmtree(d)
    return p.returncode, p.stderr.strip()
for tool in ("rg", "fzf", "jq", "perl", "bat"):
    check(f"refuses to start without {tool}", without(tool) == (1, f"rg-fzf-kiro: {tool} is not installed"), without(tool))
check("...and builds no index then", not os.path.exists(f"{H}/cache-without"))
rc, out, err = cli(env=dict(ENV, KIRO_SESSIONS_DIR=f"{H}/nope"))
check("missing sessions folder is an error", rc == 1 and "no Kiro sessions" in err, err)

print("--- indexing")
rc, out, err = cli("--index-only")
check("--index-only builds the index and exits", rc == 0 and out == "", (rc, out, err))
check("index mirrors each session's directory, ~ for home", text_files() == expected_files(),
      sorted(set(text_files()) ^ set(expected_files())))
check("every session's index equals reading it from scratch", all(index_matches_full(k) for k in KEYS),
      [k for k in KEYS if not index_matches_full(k)])
chat_a1 = open(index_file("a1", "chat"), "rb").read()
check("control characters and escape codes removed", b"\x07" not in chat_a1 and b"\x1b" not in chat_a1 and b"bell[31mred" in chat_a1, chat_a1)
check("corrupt record skipped, the rest kept", b"not json" not in chat_a1 and b"thanks, that fixed it" in chat_a1)
check("compaction summaries indexed, with their record", b"\n<!-- summary \xc2\xb7 5 -->\n## OBJECTIVE\nFix parser unicode crash\n\n" in chat_a1, chat_a1)
check("copy is Markdown: a marker comment per message, text unlabelled",
      chat_a1.startswith(b"<!-- you \xc2\xb7 1 -->\nwhy does the parser crash on unicode input?\n\n<!-- kiro \xc2\xb7 2 -->\nThe tokenizer splits"), chat_a1[:200])
check("thinking never indexed", all(b"secret thoughts" not in open(index_file(k, "chat"), "rb").read() for k in KEYS))
chat_ad3 = open(index_file("ad3", "chat"), "rb").read()
check("tool calls and output are not indexed", not any(f.endswith(".tools") for f in text_files())
      and b"magicToolWord" not in chat_ad3 and b"other.rs" not in chat_ad3 and b"Reading the file now." in chat_ad3, chat_ad3)
check("cache has only index parts", sorted(os.listdir(CACHE)) == CACHE_PARTS, os.listdir(CACHE))
rows = [l.split("\t") for l in open(f"{CACHE}/sessions.tsv").read().splitlines()]
check("session list: one row per readable session, 10 columns", len(rows) == 12 and all(len(r) == 10 for r in rows), rows)
check("...each a V2 session, with its file", all(r[8] == "v2" and r[9] == f"{SESS}/{r[0]}.jsonl" for r in rows), rows[:2])
check("session list sorted by last update", [r[0][:8] for r in rows][:3] == [short["h9"], short["aa7"], short["c3"]], [r[0][:8] for r in rows])
byid = {r[0]: r for r in rows}
check("title kept exactly, including / and \\", byid[ID["b2"]][7] == "Deploy plan: prod/us-east-1 \\ rollout", byid[ID["b2"]])
check("untitled session", byid[ID["aa7"]][7] == "untitled")
check("subagent and /rewind sessions told apart", byid[ID["e5"]][1] == "sub" and byid[ID["f6"]][1] == "main")
check("prompts in a subagent session are labelled agent", open(index_file("e5", "chat"), "rb").read() == b"<!-- agent \xc2\xb7 1 -->\nsubagent instructions: find canary configs\n\n")
check("a text line that looks like a marker is escaped", b"\n <!-- kiro \xc2\xb7 9 -->\n" in open(index_file("h9", "chat"), "rb").read(), open(index_file("h9", "chat"), "rb").read())

def read_pos(key):
    return int(open(f"{CACHE}/state/{ID[key]}").read().split("\t")[1])
check("each session read exactly to its end", all(read_pos(k) == os.path.getsize(f"{SESS}/{ID[k]}.jsonl") for k in KEYS),
      {k: (read_pos(k), os.path.getsize(f"{SESS}/{ID[k]}.jsonl")) for k in KEYS})
t0 = time.time()
rc, _, err = cli("--index-only")
print(f"     (no-change run took {time.time() - t0:.2f}s)")
check("unchanged: no work, no message", rc == 0 and err == "", err)

with open(f"{SESS}/{ID['b2']}.jsonl", "a") as f:
    f.write(prompt("appended zebra message") + "\n")
cli("--index-only")
check("appended record indexed", b"zebra" in open(index_file("b2", "chat"), "rb").read() and index_matches_full("b2"))
with open(f"{SESS}/{ID['b2']}.jsonl", "a") as f:
    f.write('{"version":"v1","kind":"Prompt","data":{"content":[{"kind":"text","data":"half wri')
cli("--index-only")
check("record still being written is not indexed yet", b"half wri" not in open(index_file("b2", "chat"), "rb").read())
with open(f"{SESS}/{ID['b2']}.jsonl", "a") as f:
    f.write('tten giraffe"}]}}\n')
cli("--index-only")
check("...and is indexed once complete", b"half written giraffe" in open(index_file("b2", "chat"), "rb").read() and index_matches_full("b2"))
check("read position ends at the file's end", read_pos("b2") == os.path.getsize(f"{SESS}/{ID['b2']}.jsonl"))

def rewrite_same_size(key, idx, old, new):
    p = f"{SESS}/{ID[key]}.jsonl"
    data = open(p, "rb").read()
    lines = data.split(b"\n")
    assert len(old) == len(new) and old in lines[idx]
    lines[idx] = lines[idx].replace(old, new)
    open(p, "wb").write(b"\n".join(lines))
    assert os.path.getsize(p) == len(data)
with open(f"{SESS}/{ID['b2']}.jsonl", "a") as f:     # add one record so the next run appends
    f.write(prompt("one more line") + "\n")
rewrite_same_size("b2", 0, b"roll out", b"ROLL OUT")
cli("--index-only")
check("first record rewritten, same size, plus an append -> rebuilt", b"ROLL OUT" in open(index_file("b2", "chat"), "rb").read() and index_matches_full("b2"))
with open(f"{SESS}/{ID['b2']}.jsonl", "a") as f:
    f.write(prompt("and another") + "\n")
n = len(open(f"{SESS}/{ID['b2']}.jsonl", "rb").read().split(b"\n"))
rewrite_same_size("b2", n - 3, b"one more line", b"ONE MORE LINE")
cli("--index-only")
check("record just before the new data rewritten, same size -> rebuilt", b"ONE MORE LINE" in open(index_file("b2", "chat"), "rb").read() and index_matches_full("b2"))

def rewrite_line(key, idx, text):
    p = f"{SESS}/{ID[key]}.jsonl"
    lines = open(p, "rb").read().split(b"\n")
    lines[idx] = prompt(text).encode()
    open(p, "wb").write(b"\n".join(lines))
rewrite_line("a1", 0, "REWRITTEN FIRST")
cli("--index-only")
check("start of the file rewritten -> rebuilt", b"REWRITTEN FIRST" in open(index_file("a1", "chat"), "rb").read() and index_matches_full("a1"))
rewrite_line("a1", -2, "REWRITTEN LAST")
cli("--index-only")
check("last record rewritten -> rebuilt", b"REWRITTEN LAST" in open(index_file("a1", "chat"), "rb").read() and index_matches_full("a1"))
open(f"{SESS}/{ID['a1']}.jsonl", "w").write(prompt("short replacement") + "\n")
cli("--index-only")
check("file shrank -> rebuilt", open(index_file("a1", "chat"), "rb").read() == b"<!-- you \xc2\xb7 1 -->\nshort replacement\n\n")
with open(index_file("b2", "chat"), "ab") as f:
    f.write(b"tampered\n")
with open(f"{SESS}/{ID['b2']}.jsonl", "a") as f:
    f.write(prompt("after tamper") + "\n")
cli("--index-only")
check("index file changed outside the tool -> rebuilt", index_matches_full("b2") and b"tampered" not in open(index_file("b2", "chat"), "rb").read())

os.makedirs(f"{CACHE}/tmp", exist_ok=True)
open(f"{CACHE}/tmp/junk", "w").write("x")
cli("--index-only")
check("leftovers from an interrupted run removed", not os.path.exists(f"{CACHE}/tmp"))

meta = json.load(open(f"{SESS}/{ID['g8']}.json"))
meta["cwd"] = f"{H}/moved here"
time.sleep(0.05)
open(f"{SESS}/{ID['g8']}.json", "w").write(json.dumps(meta))
cli("--index-only")
check("session moved to another directory: its index files follow", text_files() == expected_files(moved_g8=True) and index_matches_full("g8"),
      sorted(set(text_files()) ^ set(expected_files(moved_g8=True))))

st_before = open(f"{CACHE}/state/{ID['c3']}").read()
meta = json.load(open(f"{SESS}/{ID['c3']}.json"))
meta["title"] = "Live chat renamed"
time.sleep(0.05)
open(f"{SESS}/{ID['c3']}.json", "w").write(json.dumps(meta))
cli("--index-only")
byid = {l.split("\t")[0]: l.split("\t") for l in open(f"{CACHE}/sessions.tsv").read().splitlines()}
check("title change picked up without re-reading the text", byid[ID["c3"]][7] == "Live chat renamed" and open(f"{CACHE}/state/{ID['c3']}").read() == st_before)

good = open(f"{SESS}/{ID['f6']}.json").read()
time.sleep(0.05)
open(f"{SESS}/{ID['f6']}.json", "w").write("{ broken")
cli("--index-only")
check("metadata temporarily unreadable: previous row kept", ID["f6"] in open(f"{CACHE}/sessions.tsv").read())
time.sleep(0.05)
open(f"{SESS}/{ID['f6']}.json", "w").write(good)
cli("--index-only")

rc, _, err = cli("--index-only", "--reindex")
check("--reindex rebuilds everything", rc == 0 and all(index_matches_full(k) for k in KEYS) and text_files() == expected_files(moved_g8=True), err)
open(f"{CACHE}/version", "w").write("1\n")
cli("--index-only")
check("index from an older version is rebuilt", open(f"{CACHE}/version").read() == "7\n" and all(index_matches_full(k) for k in KEYS))

shutil.rmtree(f"{CACHE}/text")
shutil.rmtree(f"{CACHE}/state")
ps = [subprocess.Popen(["bash", SCRIPT, "--index-only"], cwd=H, env=ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(3)]
codes = [p.wait(60) for p in ps]
check("three copies indexing at once all succeed", codes == [0, 0, 0], codes)
check("...and the index is exact", all(index_matches_full(k) for k in KEYS) and text_files() == expected_files(moved_g8=True))

os.remove(f"{SESS}/{ID['ab1']}.json")
os.remove(f"{SESS}/{ID['ab1']}.jsonl")
cli("--index-only")
check("deleted session: index files and empty folders removed",
      text_files() == expected_files(moved_g8=True, without=("ab1",)) and not os.path.exists(f"{CACHE}/text/var")
      and not os.path.exists(f"{CACHE}/meta/{ID['ab1']}") and not os.path.exists(f"{CACHE}/state/{ID['ab1']}"))
check("folder of the moved session's old directory removed", not os.path.exists(f"{CACHE}/text/~/moved here") or index_file("g8", "chat"))

print("--- picker")
s = Session()
q, m = s.state()
visible = ["h9", "c3", "b2", "f6", "a1", "d4", "g8", "ad3", "ac2"]   # newest update first; no subagent, no empty
check("startup lists sessions by last update, no subagents, no empty", ids(m) == [short[k] for k in visible], ids(m))
row = {sid8(x): x for x in m}
check("rows show directory, start date and short id",
      fields(row[short["b2"]])[0] == f"~/proj/a b/c/{local(CREATED['b2'], '%Y-%m-%d')} #{short['b2']}.chat", fields(row[short["b2"]])[0])
check("rows show when the session was last updated",
      fields(row[short["b2"]])[-1] == "updated " + local("2026-10-12T10:00:00Z", "%Y-%m-%d %H:%M"), fields(row[short["b2"]])[-1])
live = {k: "● live" in fields(row[short[k]])[-1] for k in visible}
check("running sessions tagged live; a lock with a dead pid is not", live["c3"] and live["h9"] and live["ac2"] and not live["d4"] and not live["a1"], live)
if CAN_SEE:
    check("a lock whose pid now belongs to another program is not live", not live["g8"])
else:
    print("SKIP reused-pid check: process commands can't be read here (counted as live by design)")
check("header shows the keys", all(k in s.screen() for k in (b"C-e:edit", b"M-enter:json", b"M-g:live")) and b"M-k" not in s.screen() and b"M-e:" not in s.screen() and b"M-t:" not in s.screen())
check("prompt Chat (regex)>", b"Chat (regex)>" in s.screen())

s.key(b"\x1bg")
want = ["h9", "c3", "ac2"] if CAN_SEE else ["h9", "c3", "g8", "ac2"]
check("Alt-G shows only running sessions", ids(s.state()[1]) == [short[k] for k in want], ids(s.state()[1]))
check("prompt shows [L]", b"Chat (regex) [L]>" in s.screen())
s.key(b"still")
check("Alt-G applies to chat search", ids(s.state()[1]) == [short["c3"]], s.state()[1])
s.key(CLR + b"canary")
check("...and excludes saved sessions from it", s.state()[1] == [], s.state()[1])
s.key(b"\x1bg")

q, m = s.state()
check("chat search finds prompts and replies, by session update", ids(m) == [short["b2"], short["d4"]], m)
check("result lines show who said it", any(fields(x)[-1] == "kiro│ Use a canary stage first, then promote." for x in m), m)
check("match highlighted", re.search(rb"31[;0-9]*mcanary", s.out) is not None)

s.key(CLR + b"magicToolWord")
check("tool output never searched", s.state()[1] == [])
s.key(b"\x1bt")
check("Alt-T does nothing (removed)", s.state()[1] == [] and b"[T]>" not in s.screen()[-3000:])
s.key(CLR + b"other\\.rs")
check("tool calls never searched", s.state()[1] == [])
s.key(CLR + b"short replacement")
check("search reflects the rebuilt session", ids(s.state()[1]) == [short["a1"]])
s.key(CLR + b"twin session")
check("sessions sharing a directory and day are kept apart", ids(s.state()[1]) == [short["ad3"]])

s.key(CLR + b"canary")
s.key(b"\x1bs")
check("Alt-S includes subagent sessions", ids(s.state()[1]) == [short["e5"], short["b2"], short["d4"]], s.state()[1])
check("prompt shows [S]", b"Chat (regex) [S]>" in s.screen())
s.key(b"\x1bs")

s.key(CLR + b"(?<=a )canary")
check("lookbehind gives nothing with the default engine", s.state()[1] == [])
s.key(b"\x1bp")
check("Alt-P: lookbehind works", ids(s.state()[1]) == [short["b2"]], s.state()[1])
check("prompt Chat (pcre2)>", b"Chat (pcre2)>" in s.screen())
s.key(b"\x1bp")
s.key(CLR + b"$(touch pwned)")
check("query never run as a command", not os.path.exists(f"{H}/pwned"))

s.key(CLR + b"roll out")
s.key(b"\x06")
check("Ctrl-F: Sessions (fuzzy)> prompt", b"Sessions (fuzzy)>" in s.screen())
s.key(b"proj")
check("filter by directory", ids(s.state()[1]) == [short["b2"]], s.state()[1])
s.key(CLR + b"#" + short["b2"][:4].encode())
check("filter by short id", ids(s.state()[1]) == [short["b2"]])
s.key(CLR + b"zzz")
check("a filter matching nothing shows nothing", s.state()[1] == [])
s.key(CLR + b"abc")
s.key(b"\x06")
q, m = s.state()
check("Ctrl-F back: query restored, still filtered", q == "roll out" and ids(m) == [short["b2"]], (q, m))
s.key(CLR + b"canary")
check("filter stays on for new searches", ids(s.state()[1]) == [short["b2"]], s.state()[1])
s.key(b"\x06")
s.key(CLR)
s.key(b"\x06")
check("filter cleared", ids(s.state()[1]) == [short["b2"], short["d4"]])

tmp = os.environ.get("TMPDIR", "/tmp")
helper = [os.path.join(tmp, d, "actions.sh") for d in os.listdir(tmp)]
helper = [p for p in helper if os.path.isfile(p) and SESS in open(p).read()]
def preview(key):
    out = subprocess.run([helper[-1], "preview", fields(row[short[key]])[0], "1"], capture_output=True, text=True).stdout
    return re.sub(r"\x1b\[[0-9;]*m", "", out).split("\n")
if helper:
    p = preview("b2")
    check("preview: title first, exactly as saved", p[0] == "title    Deploy plan: prod/us-east-1 \\ rollout", p[:2])
    check("preview: session id, full directory, dates, status",
          p[1] == f"session  {ID['b2']}  (v2)" and p[2] == f"dir      {DEEP}"
          and p[3] == f"started  {local('2026-10-02T10:00:00Z', '%Y-%m-%d %H:%M')}    updated  {local('2026-10-12T10:00:00Z', '%Y-%m-%d %H:%M')}"
          and p[4] == "status   saved", p[:6])
    body = [re.sub(r"^[ >] *[0-9]+ ", "", l) for l in p[6:]]
    check("preview: conversation below, with marker comments", body[:2] == ["<!-- you · 1 -->", "how do we ROLL OUT the deploy to prod safely?"], p[6:9])
    check("preview: live status with pid", preview("c3")[4] == f"status   ● live in a running kiro-cli (pid {LIVE})", preview("c3")[:6])
    check("preview: renamed title shown", preview("c3")[0] == "title    Live chat renamed")
    sub = subprocess.run([helper[-1], "preview", f"~/work dir/{local(CREATED['e5'], '%Y-%m-%d')} #{short['e5']}.chat", "1"],
                         capture_output=True, text=True).stdout
    check("preview: subagent session marked", f"session  {ID['e5']}  (subagent)" in re.sub(r"\x1b\[[0-9;]*m", "", sub), sub[:300])
    check("preview: unknown file says so", subprocess.run([helper[-1], "preview", "nope.chat", "1"], capture_output=True,
          text=True).stdout.strip() == "Session not found")
else:
    check("helper script found for preview tests", False)

# role labels are colored in the list, and a label that is part of a match is left alone
s.key(CLR + b"canary")
s.wait_for(lambda q, m: q == "canary" and len(m) == 2)
# fzf redraws colors in its own form, e.g. ESC[;1;32m, so match the color numbers loosely
check("list: 'kiro' label colored", re.search(rb"\x1b\[[0-9;]*1;32[0-9;]*mkiro\xe2\x94\x82", s.out) is not None, s.out[-600:])
check("list: 'you' label colored", re.search(rb"\x1b\[[0-9;]*1;36[0-9;]*myou\xe2\x94\x82", s.out) is not None)
s.key(CLR + b"kiro session")
s.wait_for(lambda q, m: q == "kiro session" and ids(m) == [short["h9"]])
s.key(CLR + b"kiro")
q, m = s.state()
check("marker comments are never results", q == "kiro" and m and not any(fields(x)[-1].endswith("-->") and "<!-- kiro" in fields(x)[-1][:30] and short["h9"] not in x for x in m), m)
s.key(CLR + "kiro · 9".encode())
q, m = s.state()
check("text that looks like a marker is still found, as the user's", ids(m) == [short["h9"]] and fields(m[0])[-1] == "you│  <!-- kiro · 9 -->", m)

# Ctrl-E: opens the conversation text at the line in $EDITOR, and stays in the picker
s.find(b"canary stage", "b2")
q, m = s.state()
os.path.exists(editor_log) and os.remove(editor_log)
s.key(b"\x05", 2)
log = open(editor_log).read().split("\n") if os.path.exists(editor_log) else []
check("Ctrl-E opens the conversation text in $EDITOR at the line",
      len(log) >= 2 and log[0] == f"{CACHE}/text/{fields(m[0])[0]}" and log[1] == "+" + fields(m[0])[1] and os.path.isfile(log[0]), log)
check("...and returns to the picker", s.state()[0] == "canary stage")

os.path.exists(editor_log) and os.remove(editor_log)
s.key(b"\x1be", 2)
check("Alt-E does nothing (removed)", not os.path.exists(editor_log) and s.state()[0] == "canary stage")

# preview colors and Markdown
s.find(b"canary stage", "b2")
helper2 = [p for p in helper if os.path.isfile(p)] if helper else []
if helper2:
    out = subprocess.run([helper2[-1], "preview", fields(s.state()[1][0])[0], "2"], capture_output=True,
                         env=dict(os.environ, FZF_PREVIEW_COLUMNS="100")).stdout
    check("preview: marker comments colored by who wrote them",
          b"\x1b[1;36m<!-- you \xc2\xb7 1 -->\x1b[0m" in out and b"\x1b[1;32m<!-- kiro \xc2\xb7 2 -->\x1b[0m" in out, out[-400:])
    check("preview: selected line marked", re.search(rb"\x1b\[1;33m>(\x1b\[0m)?\x1b\[90m *2\x1b\[0m", out) is not None, out[-400:])
    check("preview: text highlighted by bat (Markdown)", b"\x1b[38;" in out or b"\x1b[48;" in out, out[-300:])
else:
    check("helper script found for preview color tests", False)

s.finish(b"\x1b")

# Alt-Enter: JSON for one line
s = Session()
s.find(b"canary stage", "b2")
raw = s.finish(b"\x1b\r")
try:
    d = json.loads(raw.decode())
except ValueError:
    d = None
    check("Alt-Enter prints valid JSON", False, raw[:400])
if d:
    r = d["results"][0] if d["results"] else {}
    check("JSON has the query and one result", d.get("query") == "canary stage" and len(d["results"]) == 1 and "session_filter" not in d, d)
    check("JSON result: session details",
          (r.get("session_id"), r.get("title"), r.get("directory"), r.get("subagent"), r.get("live"), r.get("pid"))
          == (ID["b2"], "Deploy plan: prod/us-east-1 \\ rollout", DEEP, False, False, None), r)
    check("JSON result: V2 resume command", r.get("resume") == f"cd '{DEEP}' && kiro-cli chat --v2 --resume-id '{ID['b2']}'", r.get("resume"))
    check("JSON result: store", r.get("store") == "v2", r)
    rr = subprocess.run(["bash", "-c", r.get("resume", "").replace("kiro-cli chat --v2 --resume-id", "printf '%s|%s' \"$PWD\"")], capture_output=True, text=True).stdout
    check("...which runs in the right directory with the right id", rr == f"{DEEP}|{ID['b2']}", rr)
    check("JSON result: line, role and text",
          (r.get("line"), r.get("column"), r.get("role"), r.get("record"), r.get("text")) == (5, 7, "kiro", 2, "Use a canary stage first, then promote."), r)
    check("JSON result: copy path and original session file", r.get("copy") and os.path.isfile(r["copy"]) and r["copy"].endswith(f"#{short['b2']}.chat")
          and r.get("session_file") == f"{SESS}/{ID['b2']}.jsonl", (r.get("copy"), r.get("session_file")))
    orig_line = open(r["session_file"], "rb").read().split(b"\n")[r["record"] - 1]
    check("JSON record points at that message in the original file", b"Use a canary stage" in orig_line, orig_line[:200])
    check("JSON result: dates", r.get("started") == local(CREATED["b2"], "%Y-%m-%d %H:%M") and r.get("updated_at", "").startswith("2026-10-12T10:00:00"), r)

# Alt-Enter: several lines from several sessions, including a live one
s = Session()
s.key(b"\x1bs")
s.key(CLR + b"canary|still open")
s.wait_for(lambda q, m: len(m) == 4)
s.key(b"\x01")
raw = s.finish(b"\x1b\r")
try:
    d = json.loads(raw.decode())
except ValueError:
    d = None
    check("multi-select JSON is valid", False, raw[:400])
if d:
    got = sorted((r["session_id"][:8], r["role"]) for r in d["results"])
    check("multi-select: every selected line, each with its session",
          got == sorted([(short["b2"], "kiro"), (short["d4"], "you"), (short["e5"], "agent"), (short["c3"], "you")]), got)
    by = {r["session_id"][:8]: r for r in d["results"]}
    check("multi-select: live session has live and pid", by[short["c3"]]["live"] is True and by[short["c3"]]["pid"] == LIVE, by[short["c3"]])
    check("multi-select: subagent flagged", by[short["e5"]]["subagent"] is True and by[short["b2"]]["subagent"] is False)

# Alt-Enter on the session list (empty search): session details only
s = Session()
s.key(b"\t\t")
raw = s.finish(b"\x1b\r")
try:
    d = json.loads(raw.decode())
except ValueError:
    d = None
    check("session-list JSON is valid", False, raw[:400])
if d:
    check("session list: query empty, two sessions", d["query"] == "" and len(d["results"]) == 2, d)
    check("session list: no line or text fields", all("line" not in r and "text" not in r and "copy" not in r and "resume" in r and "session_file" in r for r in d["results"]), d["results"])

# Alt-Enter from the session filter: query is the search, filter reported separately
s = Session()
s.key(b"canary")
s.wait_for(lambda q, m: len(m) == 2)
s.key(b"\x06")
s.key(b"proj")
s.wait_for(lambda q, m: ids(m) == [short["b2"]])
raw = s.finish(b"\x1b\r")
try:
    d = json.loads(raw.decode())
    check("from the session filter: search and filter both reported",
          d["query"] == "canary" and d.get("session_filter") == "proj" and [r["session_id"] for r in d["results"]] == [ID["b2"]], d)
except ValueError:
    check("session-filter JSON is valid", False, raw[:400])

# Ctrl-O prints plain lines
s = Session()
s.find(b"canary stage", "b2")
raw = s.finish(b"\x0f")
check("Ctrl-O prints the line as shown", raw == f"~/proj/a b/c/{local(CREATED['b2'], '%Y-%m-%d')} #{short['b2']}.chat:5:7:kiro│ Use a canary stage first, then promote.".encode(), raw)

print("--- preview keys")
s = Session()
s.find(b"wrapme", "ad3")
before = len(s.out)
s.pump(1.5)
check("long line cut off without wrapping", b"ZZTAILWORD" not in s.screen(before) and b"ZZTAILWORD" not in s.screen(), s.screen()[-300:])
mark = len(s.out)
s.key(b"\x1bw")
check("Alt-W wraps preview lines", b"ZZTAILWORD" in s.until(mark, b"ZZTAILWORD"), s.screen(mark)[-300:])
mark = len(s.out)
s.key(b"\x1bn")
s.pump(1)
nums_off = s.screen(mark)
check("Alt-N hides preview line numbers", re.search(rb"\n *>? +[0-9]+ <!-- kiro", nums_off.replace(b"\r", b"\n")) is None
      and b"<!-- kiro" in nums_off, nums_off[-400:])
mark = len(s.out)
s.key(b"\x1bn")
check("Alt-N again shows them", re.search(rb"[0-9]+ <!-- (you|kiro)", s.until(mark, b"<!-- kiro")) is not None, s.screen(mark)[-400:])
def keys_file_opened(key):
    if os.path.exists(editor_log):
        os.remove(editor_log)
    s.key(key, 2)
    log = open(editor_log).read().split("\n") if os.path.exists(editor_log) else []
    path = log[0] if log else ""
    ok = path.endswith("/rg-fzf-kiro-keybindings.txt") and os.path.isfile(path)
    return ok, path, log
ok, path, log = keys_file_opened(b"\x1b/")
check("Alt-/ opens the keybinding list in $EDITOR", ok and len(log) == 2, log)
if ok:
    text = open(path).read()
    check("...as a read-only file", (os.stat(path).st_mode & 0o222) == 0, oct(os.stat(path).st_mode))
    check("...listing every key, nothing else", text.startswith("Keybindings:\n") and "Toggle line wrapping" in text
          and "Alt-/  F1" in text and "Environment" not in text and "Usage:" not in text, text[:300])
check("...and returns to the picker with the preview unchanged", s.state()[0] == "wrapme" and b"<!-- kiro" in s.screen()[-3000:])
ok, path2, log = keys_file_opened(b"\x1bOP")
check("F1 opens the same list", ok and path2 == path, log)
check("header lists M-/:keys", b"M-/:keys" in s.screen())
check("query untouched by these keys", s.state()[0] == "wrapme")
s.finish(b"\x1b")

print("--- one result per session (Alt-U), roles (Alt-R)")
# Two more sessions, newest of all: ae4 mentions uniqword in every role, af5 only in
# a Kiro reply, after a prompt that doesn't
for k in ("ae4", "af5"):
    ID[k] = f"{k}00000-1111-2222-3333-444444444444"
    short[k] = ID[k][:8]
session("ae4", "Uniq one", "2026-10-17T10:00:00Z", "2026-10-17T12:00:00Z", [
    prompt("uniqword first from you"),
    reply("uniqword reply from kiro", ("read", {"path": "/uniqword/file"})),
    results("uniqword tool output"),
    rec("Compaction", {"summary": "uniqword in a summary"}),
    prompt("uniqword again from you"),
])
session("af5", "Uniq two", "2026-10-17T09:00:00Z", "2026-10-17T11:00:00Z", [
    prompt("nothing to see"), reply("uniqword only kiro says it")])
label = lambda x: fields(x)[-1].split("\u2502")[0]
s = Session()
s.key(b"uniqword")
q, m = s.state()
check("uniqword: 4 rows from ae4, 1 from af5", ids(m) == [short["ae4"]] * 4 + [short["af5"]], m)
mark = len(s.out)
s.key(b"\x1bu")
q, m = s.state()
check("Alt-U: each session once", ids(m) == [short["ae4"], short["af5"]], m)
check("...at its first match", [fields(x)[-1] for x in m] == ["you\u2502 uniqword first from you", "kiro\u2502 uniqword only kiro says it"], m)
check("...prompt shows [U]", b"Chat (regex) [U]>" in s.until(mark, b"[U]>"))
s.key(CLR + b"kiro")
q, m = s.state()
check("Alt-U: a session whose first 'kiro' is a message label still shows, with a real row",
      short["ae4"] in ids(m) and short["af5"] in ids(m) and len(ids(m)) == len(set(ids(m)))
      and all("<!--" not in fields(x)[-1][:12] for x in m), m)
s.key(CLR + b"uniqword")
s.key(b"\x1bu")
check("Alt-U again: all rows back", len(s.state()[1]) == 5)

mark = len(s.out)
s.key(b"\x1br")
q, m = s.state()
check("Alt-R once: only your messages", [label(x) for x in m] == ["you", "you"] and ids(m) == [short["ae4"]] * 2, m)
check("...prompt shows [R:you]", b"Chat (regex) [R:you]>" in s.until(mark, b"[R:you]"))
mark = len(s.out)
s.key(b"\x1br")
q, m = s.state()
check("Alt-R twice: only Kiro's, summaries included", [label(x) for x in m] == ["kiro", "summary", "kiro"]
      and ids(m) == [short["ae4"], short["ae4"], short["af5"]], m)
check("...prompt shows [R:kiro]", b"Chat (regex) [R:kiro]>" in s.until(mark, b"[R:kiro]"))
s.key(b"\x1bu")
q, m = s.state()
check("Alt-R with Alt-U: Kiro's first message per session", [fields(x)[-1] for x in m]
      == ["kiro\u2502 uniqword reply from kiro", "kiro\u2502 uniqword only kiro says it"], m)
mark = len(s.out)
s.key(b"\x06")
check("session filter shows the same flags", b"Sessions (fuzzy) [U] [R:kiro]>" in s.until(mark, b"[R:kiro]"), s.screen(mark)[-300:])
s.key(b"Uniq")
check("...and the same rows", ids(s.state()[1]) == [], s.state())
s.key(CLR + b"#" + short["af5"][:4].encode())
check("...filtering them by id", ids(s.state()[1]) == [short["af5"]], s.state())
s.key(CLR)
s.key(b"\x06")
s.key(b"\x01")
out = s.finish(b"\x0f").decode().split("\n")
check("Ctrl-O with Alt-U and Alt-R: one Kiro line per session",
      [re.sub(r"^.*#([0-9a-z]{8})\.chat:([0-9]+):1:", r"\1 \2 ", x) for x in out]
      == [f"{short['ae4']} 5 kiro\u2502 uniqword reply from kiro", f"{short['af5']} 5 kiro\u2502 uniqword only kiro says it"], out)
s = Session()
s.key(b"uniqword"); s.key(b"\x1br"); s.key(b"\x1br")
mark = len(s.out)
s.key(b"\x1br")
check("Alt-R three times: everyone again", len(s.state()[1]) == 5 and b"[R:" not in s.until(mark, b"Chat (regex)>"), s.state())
s.finish(b"\x1b")

print("--- Enter prints the readable copies")
copy = lambda k: index_file(k, "chat")
s = Session()
s.key(b"uniqword")
s.wait_for(lambda q, m: len(m) == 5)
s.key(b"\x01")
out = s.finish(b"\r")
check("Enter: each selected session's copy once, full path, newest first", out == f"{copy('ae4')}\n{copy('af5')}".encode(), out)
check("...real files holding the matched text", b"uniqword only kiro says it" in open(copy("af5"), "rb").read())
s = Session()
s.key(b"uniqword")
s.wait_for(lambda q, m: len(m) == 5)
check("Enter with nothing selected: the current line's session", s.finish(b"\r") == copy("ae4").encode())
s = Session()
s.key(b"\t\t")
check("Enter from the session list", s.finish(b"\r") == f"{copy('ae4')}\n{copy('af5')}".encode())
s = Session()
s.key(b"uniqword"); s.wait_for(lambda q, m: len(m) == 5)
s.key(b"\x06"); s.key(b"#" + short["af5"][:4].encode())
s.wait_for(lambda q, m: ids(m) == [short["af5"]])
check("Enter from the session filter", s.finish(b"\r") == copy("af5").encode())
s = Session("-0")
s.key(b"uniqword")
s.wait_for(lambda q, m: len(m) == 5)
s.key(b"\x01")
check("-0: Enter separates the paths with NUL", s.finish(b"\r") == f"{copy('ae4')}\0{copy('af5')}\0".encode())

print("--- sessions piped in")
check("empty pipe is an error", cli_in(b"") == (1, "rg-fzf-kiro: no sessions given on stdin"), cli_in(b""))
check("blank lines only: same error", cli_in(b"\n \n") == (1, "rg-fzf-kiro: no sessions given on stdin"), cli_in(b"\n \n"))
check("only unknown sessions is an error", cli_in(b"nope\n/tmp/zzz.jsonl\n") == (1, "rg-fzf-kiro: none of the sessions given on stdin are known"),
      cli_in(b"nope\n"))
check("--index-only ignores stdin", cli_in(b"", "--index-only") == (0, ""), cli_in(b"", "--index-only"))
open(f"{H}/list.txt", "w").write(f"{copy('ae4')}\n  {SESS}/{ID['af5']}.jsonl\n{ID['e5']}\nbogus\n{ID['ae4']}\n\n")
s = Session(cmd=f"bash '{run}' < '{H}/list.txt'")
q, m = s.state()
check("piped list: only those sessions, in session-list order", ids(m) == [short["ae4"], short["af5"], short["e5"]], m)
check("...a subagent session named in the list is shown without Alt-S", short["e5"] in ids(m))
check("...unknown entries reported", b"rg-fzf-kiro: skipped 1 unknown session(s) from stdin" in s.out, s.out[:300])
s.key(b"canary")
check("piped list: search covers only them", ids(s.state()[1]) == [short["e5"]], s.state())
s.key(b"\x1bg")
check("...Alt-G still applies on top", s.state()[1] == [], s.state())
s.key(b"\x1bg")
s.key(CLR + b"uniqword")
check("piped list: other listed sessions searched", set(ids(s.state()[1])) == {short["ae4"], short["af5"]}, s.state())
s.finish(b"\x1b")
open(f"{H}/list0", "wb").write(f"{ID['af5']}\0{SESS}/{ID['ae4']}.json\0".encode())
s = Session(cmd=f"cat '{H}/list0' | bash '{run}'")
check("NUL-separated list, from a pipe", ids(s.state()[1]) == [short["ae4"], short["af5"]], s.state())
s.finish(b"\x1b")

print("--- chaining rg-fzf-kiro | rg-fzf-kiro")
s = Session(cmd=f"bash '{run}' --v2 | bash '{run2}'")
s.key(b"uniqword")
s.wait_for(lambda q, m: len(m) == 5)
try:
    urllib.request.urlopen(f"http://localhost:{PORT + 1}", timeout=1)
    waiting = False
except urllib.error.URLError:
    waiting = True
check("chain: second waits until the first is done", waiting)
s.key(b"\x01")
s.key(b"\r", 3)
s.port = PORT + 1
s.last_key = 0
q, m = s.state()
check("chain: second lists only the picked sessions", ids(m) == [short["ae4"], short["af5"]], m)
s.key(b"only kiro")
check("chain: and searches only them", ids(s.state()[1]) == [short["af5"]], s.state())
check("chain: final output", s.finish(b"\r") == copy("af5").encode())

print("--- V3 sessions")
s = Session(v2=False)
check("without --v2 and no V3 sessions: a note, and an empty list", b"no V3 sessions yet; --v2 shows your V2 sessions" in s.out
      and s.state()[1] == [], (s.out[:300], s.state()))
s.finish(b"\x1b")

def v3rec(i, typ, content=None, **kw):
    payload = {"type": typ, **kw}
    if content is not None:
        payload["content"] = content
    return json.dumps({"id": i, "timestamp": "2026-10-20T10:00:00.000Z", "payload": payload})
def v3session(ws, sid, title, created, updated, recs, cwd=WORK, lock=None, **extra):
    d = f"{ROOT}/{ws}/{sid}"
    os.makedirs(d, exist_ok=True)
    meta = {"schemaVersion": "1.0.0", "id": sid, "title": title, "workspacePaths": [cwd],
            "createdAt": created, "lastModifiedAt": updated, "status": "idle", **extra}
    open(f"{d}/session.json", "w").write(json.dumps(meta))
    open(f"{d}/messages.jsonl", "w").write("".join(r + "\n" for r in recs))
    if lock is not None:
        open(f"{d}/.lock", "w").write(json.dumps({"pid": lock, "started_at": "x"}))
    return d
V3A = "sess_3a000000-1111-2222-3333-444444444444"
V3S = "sess_5b000000-1111-2222-3333-444444444444"
ID["mg1"] = "mg100000-1111-2222-3333-444444444444"
V3M = f"cli_{ID['mg1']}_Ab12Cd34"
dir_a = v3session("ws1aaaa", V3A, "V3 native", "2026-10-20T10:00:00.123Z", "2026-10-21T10:00:00.456Z", [
    v3rec("n1", "agent_note", "<session_context>v3word injected</session_context>"),
    v3rec("u1", "user", "v3word from you in v3", source="chat", documents=[]),
    v3rec("t1", "turn_start", turnId="x"),
    v3rec("r1", "assistant", "v3secret reasoning about v3word", operationType="Reasoning", reasoningSignature="sig"),
    v3rec("a1", "assistant", "v3word reply from kiro", operationType="Say"),
    v3rec("c1", "tool_call", None, name="read"),
    v3rec("c1-result", "tool_result", "v3toolword output"),
    v3rec("s1", "user", "[LIVE STEERING - New message from user]\n\nv3word steering wrapper"),
    v3rec("s2", "user", "v3word steered message", source="steer"),
    v3rec("tb", "tombstone", None, kind="summarization"),
    v3rec("summary_1", "assistant", "v3word summary text", operationType="Summary"),
    v3rec("compact_1_u1", "user", "v3word from you in v3", source="chat"),
    "{ broken json",
], lock=LIVE)
v3session("ws1aaaa", V3S, "V3 helper", "2026-10-20T09:00:00Z", "2026-10-20T09:30:00Z",
          [v3rec("u1", "user", "v3word subagent instructions")], createdReason="subagent")
session("mg1", "Migrated", "2026-10-01T10:00:00Z", "2026-10-02T10:00:00Z", [prompt("migratedword in the v2 original")])
dir_m = v3session("ws2bbbb", V3M, "Migrated", "2026-10-01T10:00:00.000000+00:00", "2026-10-22T10:00:00Z", [
    v3rec("u1", "user", "migratedword in the v2 original", source="chat"),
    v3rec("a1", "assistant", "migratedword continued in v3", operationType="Say")])
os.makedirs(f"{ROOT}/ws1aaaa/.index")
open(f"{ROOT}/ws1aaaa/.index/.lock", "w").write("")
rc, _, err = cli("--index-only")
rows = {l.split("\t")[0]: l.split("\t") for l in open(f"{CACHE}/sessions.tsv").read().splitlines()}
check("V3 sessions indexed, as store v3 with their conversation file",
      rows.get(V3A, [""] * 10)[8:] == ["v3", f"{dir_a}/messages.jsonl"] and rows.get(V3M, [""] * 10)[8] == "v3", (rc, err, rows.get(V3A)))
check("a V2 session with a V3 copy is left out", ID["mg1"] not in rows and not os.path.exists(f"{CACHE}/meta/{ID['mg1']}"), sorted(rows))
check("V3 times: fractions and +00:00 read right", rows[V3A][4] == "2026-10-21T10:00:00Z"
      and rows[V3M][6] == local("2026-10-01T10:00:00Z", "%Y-%m-%d %H:%M"), (rows[V3A][4:7], rows[V3M][4:7]))
check("V3 subagent session marked", rows[V3S][1] == "sub")
names = text_files()
check("copies named by the id after sess_; a V2 session's copy keeps its suffix",
      f"~/work dir/{local('2026-10-20T10:00:00Z', '%Y-%m-%d')} #3a000000.chat" in names
      and f"~/work dir/{local('2026-10-01T10:00:00Z', '%Y-%m-%d')} #mg100000_Ab12Cd34.chat" in names, names)
short.update(v3a="3a000000", v3s="5b000000", v3m="mg100000")
ca = open(f"{CACHE}/text/~/work dir/{local('2026-10-20T10:00:00Z', '%Y-%m-%d')} #3a000000.chat", "rb").read()
check("V3 copy: prompts, replies, steering messages and summaries only, each once",
      ca == "<!-- you · 2 -->\nv3word from you in v3\n\n<!-- kiro · 5 -->\nv3word reply from kiro\n\n"
            "<!-- you · 9 -->\nv3word steered message\n\n<!-- summary · 11 -->\nv3word summary text\n\n".encode(), ca)
check("V3 copy equals reading it from scratch", ca == extract_full(V3A, f"{dir_a}/messages.jsonl"))
with open(f"{dir_a}/messages.jsonl", "a") as f:
    f.write(v3rec("u9", "user", "v3word added later", source="chat") + "\n")
cli("--index-only")
ca2 = open(f"{CACHE}/text/~/work dir/{local('2026-10-20T10:00:00Z', '%Y-%m-%d')} #3a000000.chat", "rb").read()
check("V3 session: only the added part read, result exact", ca2 == ca + "<!-- you · 14 -->\nv3word added later\n\n".encode()
      and ca2 == extract_full(V3A, f"{dir_a}/messages.jsonl")
      and int(open(f"{CACHE}/state/{V3A}").read().split("\t")[1]) == os.path.getsize(f"{dir_a}/messages.jsonl"), ca2[-120:])

s = Session(v2=False)
q, m = s.state()
check("without --v2: only V3 sessions, newest first, no subagent", ids(m) == [short["v3m"], short["v3a"]], ids(m))
check("...no note", b"no V3 sessions yet" not in s.out)
check("...a running V3 session is tagged live", "● live" in fields(m[1])[-1], m)
s.key(b"v3word")
q, m = s.state()
check("V3 search: prompts, reply, steering message, summary", [fields(x)[-1] for x in m] == [
      "you│ v3word from you in v3", "kiro│ v3word reply from kiro", "you│ v3word steered message",
      "summary│ v3word summary text", "you│ v3word added later"], m)
s.key(CLR + b"v3secret|v3toolword|injected|steering wrapper")
check("...never reasoning, tool output, Kiro's notes or steering wrappers", s.state()[1] == [], s.state())
s.key(CLR + b"canary")
check("...V2 sessions not searched", s.state()[1] == [])
s.key(b"\x1bs")
s.key(CLR + b"v3word subagent")
check("Alt-S: V3 subagent session, its prompts by agent", [fields(x)[-1] for x in s.state()[1]] == ["agent│ v3word subagent instructions"], s.state())
s.key(b"\x1bs")
s.key(CLR + b"v3word reply")
s.wait_for(lambda q, m: len(m) == 1)
raw = s.finish(b"\x1b\r")
try:
    r = json.loads(raw.decode())["results"][0]
except (ValueError, IndexError, KeyError):
    r = {}
check("V3 JSON: store, resume with --v3, its file, live with pid",
      (r.get("store"), r.get("resume"), r.get("session_file"), r.get("live"), r.get("pid"), r.get("session_id"))
      == ("v3", f"cd '{WORK}' && kiro-cli chat --v3 --resume-id '{V3A}'", f"{dir_a}/messages.jsonl", True, LIVE, V3A), (raw[:300], r))
check("...and the record points at that message", r.get("record") == 5 and b"v3word reply from kiro" in
      open(f"{dir_a}/messages.jsonl", "rb").read().split(b"\n")[4], r)

s = Session()
s.key(b"migratedword")
q, m = s.state()
check("--v2: a migrated session shows once, as its V3 copy", ids(m) == [short["v3m"], short["v3m"]]
      and all("#mg100000_Ab12Cd34.chat" in fields(x)[0] for x in m), m)
s.key(CLR + b"canary")
check("--v2: V2 sessions searched too", ids(s.state()[1]) == [short["b2"], short["d4"]], s.state())
s.finish(b"\x1b")

open(f"{H}/list3", "w").write(f"{ID['mg1']}\n{dir_a}/\n")
s = Session(cmd=f"bash '{run}' < '{H}/list3'")
check("piped: a migrated session's V2 id and a V3 folder", ids(s.state()[1]) == [short["v3m"], short["v3a"]], s.state())
s.finish(b"\x1b")
open(f"{H}/list4", "w").write(f"{dir_m}/messages.jsonl\n{dir_a}/session.json\n")
s = Session(cmd=f"bash '{run}' < '{H}/list4'")
check("piped: V3 session files", ids(s.state()[1]) == [short["v3m"], short["v3a"]], s.state())
s.finish(b"\x1b")

print("--- index updates seen by the picker")
with open(f"{SESS}/{ID['c3']}.jsonl", "a") as f:
    f.write(prompt("newly added platypus") + "\n")
s = Session()
s.key(b"platypus")
check("new messages searchable on the next start", ids(s.state()[1]) == [short["c3"]])
check("Esc prints nothing", s.finish(b"\x1b") == b"")

left = [d for d in os.listdir(tmp) if os.path.isfile(os.path.join(tmp, d, "actions.sh")) and SESS in open(os.path.join(tmp, d, "actions.sh")).read()]
check("temporary state removed on exit", not left, left)
check("no temporary files left in the cache", sorted(os.listdir(CACHE)) == CACHE_PARTS, os.listdir(CACHE))

for p in (LIVE, LIVE2, STUBBORN, OTHER):
    try:
        os.kill(p, signal.SIGKILL)
    except OSError:
        pass
shutil.rmtree(H, ignore_errors=True)
print(f"\n{fails} failure(s)")
sys.exit(1 if fails else 0)
