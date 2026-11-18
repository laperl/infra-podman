#!/usr/bin/env python3
"""Log in to pgAdmin 4 as a person does in the browser, end to end (check-pgadmin.sh login).

Usage: pgadmin-login.py <base url> <e-mail> <password file>
Exit 0 when the session opens (the browser page answers instead of the login page), 1 when
it does not. The password is read from a file, never from the command line, and is never
printed.

pgAdmin's login page carries a CSRF token that the form sends back with the e-mail and the
password to /authenticate/login (pgAdmin 4, web/pgadmin/authenticate). Not documented as an
interface: if a new version moves it, this script says what it did not find.
"""

import http.cookiejar
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

TOKEN_PATTERNS = (
    r'name="csrf_token"[^>]*value="([^"]+)"',
    r'value="([^"]+)"[^>]*name="csrf_token"',
    r'["\']?csrf_?[tT]oken["\']?\s*[:=]\s*["\']([^"\']{20,})["\']',
)


def main() -> int:
    base, email, password_file = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3]
    with open(password_file, encoding="utf-8") as handle:
        password = handle.read().strip()
    opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
    )

    page = opener.open(f"{base}/login", timeout=30).read().decode("utf-8", "replace")
    token = next(
        (m.group(1) for p in TOKEN_PATTERNS if (m := re.search(p, page))), None
    )
    if not token:
        print("no CSRF token in the login page", file=sys.stderr)
        return 1

    form = urllib.parse.urlencode(
        {
            "csrf_token": token,
            "email": email,
            "password": password,
            "language": "en",
            "internal_button": "Login",
        }
    ).encode()
    request = urllib.request.Request(
        f"{base}/authenticate/login",
        data=form,
        headers={
            "X-pgA-CSRFToken": token,
            "Referer": f"{base}/login",
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    try:
        opener.open(request, timeout=30).read()
    except urllib.error.HTTPError as error:
        print(f"the login form answered {error.code}", file=sys.stderr)
        return 1

    answer = opener.open(f"{base}/browser/", timeout=30)
    path = urllib.parse.urlparse(answer.geturl()).path
    if answer.status == 200 and path.startswith("/browser"):
        return 0
    print(f"after logging in, /browser/ leads to {path}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
