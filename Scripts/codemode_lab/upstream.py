"""Checked stdio JSON-RPC client for the CE debug MCP helper, shared by rp_proxy.py and the runner's startup probe.

Every request has a deadline; JSON-RPC errors, a dead helper, and timeouts raise UpstreamError instead of turning
into empty results.
"""
import itertools, json, queue, subprocess, threading


class UpstreamError(Exception):
    pass


_EOF = object()


class Upstream:
    def __init__(self, cli, stderr_path=None):
        err = open(stderr_path, "a") if stderr_path else subprocess.DEVNULL
        try:
            self.p = subprocess.Popen([str(cli)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err,
                                      text=True, bufsize=1, encoding="utf-8", errors="replace")
        except OSError as e:
            raise UpstreamError(f"cannot start CE debug MCP helper {cli}: {e}") from e
        finally:
            if stderr_path: err.close()
        self.ids = itertools.count(1); self.waiters = {}; self.lock = threading.Lock(); self.dead = None
        self.wlock = threading.Lock()   # one JSON-RPC line at a time: handler and code_mode child threads write concurrently
        self.reader = threading.Thread(target=self._rd, daemon=True); self.reader.start()

    def _rd(self):
        for line in self.p.stdout:
            try: m = json.loads(line)
            except Exception: continue
            with self.lock: q = self.waiters.pop(m.get("id"), None)
            if q: q.put(m)
        with self.lock:
            self.dead = f"CE debug MCP helper exited (rc={self.p.poll()})"
            waiters, self.waiters = list(self.waiters.values()), {}
        for q in waiters: q.put(_EOF)

    def _write(self, msg):
        try:
            with self.wlock: self.p.stdin.write(json.dumps(msg) + "\n"); self.p.stdin.flush()
        except (BrokenPipeError, OSError, ValueError) as e:
            raise UpstreamError(f"CE debug MCP helper is not accepting input ({type(e).__name__})") from e

    def req(self, method, params, timeout=120):
        """Result object of a JSON-RPC request; raises UpstreamError on error response, exit or timeout."""
        q = queue.Queue()
        with self.lock:
            if self.dead: raise UpstreamError(self.dead)
            mid = next(self.ids); self.waiters[mid] = q
        self._write({"jsonrpc": "2.0", "id": mid, "method": method, "params": params})
        try:
            m = q.get(timeout=timeout)
        except queue.Empty:
            with self.lock: self.waiters.pop(mid, None)
            raise UpstreamError(f"{method} timed out after {timeout:g} s")
        if m is _EOF: raise UpstreamError(self.dead or "CE debug MCP helper exited")
        if "error" in m: raise UpstreamError(f"{method} failed: {json.dumps(m['error'])[:300]}")
        if not isinstance(m.get("result"), dict): raise UpstreamError(f"{method} returned no result object")
        return m["result"]

    def note(self, method, params):
        self._write({"jsonrpc": "2.0", "method": method, "params": params})

    def close(self):
        try: self.p.stdin.close()
        except Exception: pass
        try: self.p.kill(); self.p.wait(timeout=5)
        except Exception: pass
        self.reader.join(timeout=5)
        if not self.reader.is_alive(): self.p.stdout.close()


def text_of(res): return "".join(b.get("text", "") for b in res.get("content", []) if b.get("type") == "text")


def connect_and_bind(up, root, client="cm-experiment-proxy", timeout=60):
    """initialize + bind_context(working_dirs=[root]); returns the initialize result. Raises UpstreamError with a recovery hint."""
    hint = ("Is the CE debug app running with the pinned checkout open as a workspace? "
            "See Scripts/codemode_lab/README.md, Recovery.")
    try:
        init = up.req("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": client, "version": "0.1"}}, timeout)
        up.note("notifications/initialized", {})
        bound = up.req("tools/call", {"name": "bind_context", "arguments": {"op": "bind", "working_dirs": [root]}}, timeout)
    except UpstreamError as e:
        raise UpstreamError(f"{e}. {hint}") from e
    if bound.get("isError"):
        raise UpstreamError(f"bind_context to {root} failed: {text_of(bound)[:300]}. {hint}")
    return init
