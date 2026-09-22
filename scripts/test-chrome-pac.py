#!/usr/bin/env python3
"""Offline Chrome PAC integration. All fixture endpoints bind to loopback.
Use fresh, retained profiles; never control the user's existing Chrome session.
Run after exporting PACs with PROXY_APPS_PAC_FIXTURES (see docs/testing.md).
"""
import argparse
import hashlib
import http.server
import json
import os
import signal
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import urllib.parse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixtures", type=Path)
    parser.add_argument("--chrome", default="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    args = parser.parse_args()
    output = Path(tempfile.mkdtemp(prefix="proxy-chrome-pac-"))
    events = []
    scripts = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            role = self.server.role
            events.append({"role": role, "path": self.path})
            if role == "pac":
                body = scripts.get(self.path)
                if body is None:
                    self.send_error(404)
                    return
                mime = "application/x-ns-proxy-autoconfig"
            else:
                body = ("<!doctype html><title>PAC fixture</title><p>ROUTE_" + role.upper() + "</p>").encode()
                mime = "text/html"
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    servers = {}
    try:
        for role in ("pac", "proxy", "direct"):
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            server.role = role
            servers[role] = server
            threading.Thread(target=server.serve_forever, daemon=True).start()
        for name in ("smart", "override", "manual"):
            # Only the test proxy port differs; production routing logic stays intact.
            scripts["/proxy.pac?v=" + name] = (args.fixtures / (name + ".pac")).read_bytes().replace(
                b"PROXY 127.0.0.1:21081", f"PROXY 127.0.0.1:{servers['proxy'].server_port}".encode())
        scripts["/proxy.pac?v=oversize"] = scripts["/proxy.pac?v=smart"] + b"\n/*" + b" " * 1048576 + b"*/"
        cases = [("smart", "google.com", "proxy"), ("smart", "baidu.com", "direct"),
                 ("smart", "unknown-pac-fixture.invalid", "direct"),
                 ("override", "google.com", "direct"), ("override", "baidu.com", "proxy"),
                 ("manual", "google.com", "direct"), ("manual", "baidu.com", "proxy"),
                 # Control: Chrome rejects an oversized PAC and falls back to direct here.
                 ("oversize", "google.com", "direct")]
        results = []
        version = subprocess.run([args.chrome, "--version"], capture_output=True, text=True, timeout=10).stdout.strip()
        for index, (revision, domain, expected) in enumerate(cases):
            profile = output / f"profile-{index}"
            target_path = f"/case-{index}"
            target = f"http://{domain}:{servers['direct'].server_port}{target_path}"
            pac_path = "/proxy.pac?v=" + revision
            start_event = len(events)
            command = [args.chrome, "--headless=new", "--dump-dom", "--no-first-run", "--no-default-browser-check",
                       "--disable-background-networking", "--disable-component-update", "--disable-sync",
                       "--disable-features=HttpsUpgrades,HttpsFirstBalancedModeAutoEnable,HttpsFirstModeV2", "--disable-extensions", "--disable-default-apps", "--disable-breakpad", "--disable-quic",
                       "--metrics-recording-only", "--password-store=basic", "--timeout=10000",
                       "--user-data-dir=" + str(profile),
                       # Test domains never resolve to the real internet. No system DNS changes.
                       "--host-resolver-rules=MAP * 127.0.0.1, EXCLUDE localhost",
                       f"--proxy-pac-url=http://127.0.0.1:{servers['pac'].server_port}" + pac_path, target]
            started = time.monotonic()
            # File outputs avoid waiting on pipes inherited by Chrome helper processes.
            with (output / f"case-{index}.html").open("w") as html, (output / f"case-{index}.stderr").open("w") as errors:
                process = subprocess.Popen(command, stdout=html, stderr=errors, text=True, start_new_session=True,
                                           env={**os.environ, "HTTP_PROXY": "", "HTTPS_PROXY": "", "ALL_PROXY": ""})
                timed_out = True
                try:
                    deadline = time.monotonic() + 20
                    while time.monotonic() < deadline:
                        dom = (output / f"case-{index}.html").read_text()
                        if "</html>" in dom:
                            timed_out = False
                            break
                        if process.poll() is not None:
                            break
                        time.sleep(0.05)
                finally:
                    # Terminate only this fixture's isolated process group, never existing Chrome.
                    try:
                        os.killpg(process.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=3)
            stdout = (output / f"case-{index}.html").read_text()
            (output / f"case-{index}.events.json").write_text(json.dumps(events[start_event:], indent=2))
            case_events = events[start_event:]
            loaded = any(e["role"] == "pac" and e["path"] == pac_path for e in case_events)
            routed = any(e["role"] == expected and urllib.parse.urlsplit(e["path"]).path == target_path for e in case_events)
            passed = not timed_out and loaded and routed and "ROUTE_" + expected.upper() in stdout
            row = {"revision": revision, "domain": domain, "expected": expected, "passed": passed,
                   "pacFetched": loaded, "serverObserved": routed, "domCompleted": not timed_out, "seconds": round(time.monotonic() - started, 2)}
            results.append(row)
            print(json.dumps(row), flush=True)
            if timed_out:
                break
        report = {"chrome": version, "results": results,
                  "fixtures": {name: {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()} for name, data in scripts.items()},
                  "processLifecycle": "Wait for complete dump-dom, then terminate only the fresh fixture process group; Chrome normal exit is not the routing assertion.",
                  "scope": "Isolated Chrome --proxy-pac-url with local HTTP fixtures; no system PAC, Quickcat, HTTPS or real exit verification."}
        (output / "report.json").write_text(json.dumps(report, indent=2))
        print("REPORT " + str(output / "report.json"), flush=True)
        return 0 if all(row["passed"] for row in results) else 1
    finally:
        for server in servers.values():
            server.shutdown()
            server.server_close()
        print("Retained fixtures/profiles: " + str(output), flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
