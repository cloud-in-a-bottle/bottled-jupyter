#!/usr/bin/env python3
"""Stand-in for jupyter_server, just faithful enough to test the nginx auth flow.

Mimics the parts of jupyter_server's behaviour the front proxy depends on:

  * an unauthenticated navigation is 302'd to /login?next=<original>;
  * /login renders a login form (and hands even anonymous visitors an
    _xsrf cookie — the behaviour that used to wedge the auto-login);
  * ?token=<token> authenticates any request and mints the
    "username-<host>" identity cookie;
  * /login?token=<token> signs the caller in and forwards to ?next=.

Every request is appended to $STUB_LOG as "<method> <target>" so tests can
assert on what the proxy actually forwarded.
"""

from __future__ import annotations

import os
import sys
from http.server import BaseHTTPRequestHandler
from http.server import ThreadingHTTPServer
from urllib.parse import parse_qs
from urllib.parse import quote
from urllib.parse import urlsplit

TOKEN = os.environ["STUB_TOKEN"]
LOG_PATH = os.environ["STUB_LOG"]

# Jupyter derives this from the request host; the proxy only cares about
# the "username-" prefix.
SESSION_COOKIE = "username-stub"
SESSION_VALUE = "valid"

LOGIN_BODY = b"LOGIN_PAGE"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: object) -> None:  # noqa: A002 - stdlib signature
        pass

    def _record(self) -> None:
        with open(LOG_PATH, "a", encoding="utf-8") as fh:
            fh.write(f"{self.command} {self.path}\n")

    def _cookies(self) -> dict[str, str]:
        jar: dict[str, str] = {}
        for chunk in self.headers.get("Cookie", "").split(";"):
            name, _, value = chunk.strip().partition("=")
            if name:
                jar[name] = value
        return jar

    def _reply(self, status: int, body: bytes = b"", headers: list[tuple[str, str]] = []) -> None:
        self.send_response(status)
        for key, value in headers:
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _handle(self) -> None:
        self._record()
        split = urlsplit(self.path)
        args = parse_qs(split.query)
        # Jupyter reads the first ?token= it is given.
        token = args.get("token", [""])[0]
        token_ok = token == TOKEN
        session_ok = self._cookies().get(SESSION_COOKIE) == SESSION_VALUE
        set_session = [("Set-Cookie", f"{SESSION_COOKIE}={SESSION_VALUE}; Path=/")]

        if split.path == "/login":
            if token_ok:
                nxt = args.get("next", ["/lab"])[0]
                self._reply(302, b"", [("Location", nxt), *set_session])
            else:
                # Note the _xsrf cookie handed to an anonymous visitor.
                self._reply(
                    200,
                    LOGIN_BODY,
                    [("Set-Cookie", "_xsrf=stub-xsrf; Path=/"), ("Content-Type", "text/html")],
                )
            return

        if token_ok:
            self._reply(200, f"LAB:{split.path}".encode(), [*set_session, ("Content-Type", "text/html")])
            return
        if session_ok:
            self._reply(200, f"LAB:{split.path}".encode(), [("Content-Type", "text/html")])
            return
        self._reply(302, b"", [("Location", f"/login?next={quote(self.path, safe='')}")])

    do_GET = _handle
    do_POST = _handle
    do_HEAD = _handle


def main() -> int:
    port = int(sys.argv[1])
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
