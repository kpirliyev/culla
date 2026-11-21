"""Static checks of the nginx configuration that need no nginx.

The regexes of the two maps are taken from cullaapp.com.conf and run with
Python's re module, which behaves like nginx's PCRE for these patterns. The
real nginx behaviour is tested by run-nginx-tests.sh (needs podman).
"""

import itertools
import os
import re
import subprocess
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DEPLOY = os.path.dirname(HERE)
CSP = ("default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; "
       "form-action 'self'; base-uri 'self'; frame-ancestors 'none'")


def read(name):
    with open(os.path.join(DEPLOY, name), encoding="utf-8") as f:
        return f.read()


def rendered(name, www, ipv6):
    """The file as remote-install.sh installs it with these variants."""
    env = dict(os.environ, CULLA_ROOT=os.path.join(HERE, "no-such-root"),
               CULLA_WITH_WWW=www, CULLA_WITH_IPV6=ipv6)
    return subprocess.run(["bash", os.path.join(DEPLOY, "remote-install.sh"), "render",
                           os.path.join(DEPLOY, name)],
                          env=env, check=True, capture_output=True, text=True).stdout


VARIANTS = list(itertools.product(("no", "yes"), ("no", "yes")))   # (www, ipv6)


def top_level_directives(text):
    """Names of the directives outside every block (the http level)."""
    names, depth, statement, quote = [], 0, "", None
    for ch in strip_comments(text):
        if quote:
            if ch == quote:
                quote = None
            continue
        if ch in "\"'":
            quote = ch
            statement += "q"
        elif ch in ";{":
            if depth == 0 and statement.strip():
                names.append(statement.split()[0])
            if ch == "{":
                depth += 1
            statement = ""
        elif ch == "}":
            depth -= 1
            statement = ""
        else:
            statement += ch
    return names


def strip_comments(text):
    return "\n".join(line.split("#", 1)[0] if not line.lstrip().startswith("#") else ""
                     for line in text.splitlines())


def map_block(conf, source, variable):
    match = re.search(r"map\s+\%s\s+\%s\s*\{(.*?)\n\}" % (source, variable), conf, re.S)
    assert match, (source, variable)
    rules, default = [], None
    for line in strip_comments(match.group(1)).splitlines():
        line = line.strip()
        if not line:
            continue
        m = re.match(r'^(?:"([^"]*)"|(\S+))\s+(?:"([^"]*)"|(\S+));$', line)
        assert m, line
        key = m.group(1) if m.group(1) is not None else m.group(2)
        value = m.group(3) if m.group(3) is not None else m.group(4)
        if key == "default":
            default = value
        elif key.startswith("~*"):
            rules.append((re.compile(key[2:], re.I), value))
        elif key.startswith("~"):
            rules.append((re.compile(key[1:]), value))
        else:
            rules.append((re.compile("^%s$" % re.escape(key)), value))
    return rules, default


def apply_map(block, value):
    rules, default = block
    for regex, result in rules:
        m = regex.search(value)
        if m:
            return re.sub(r"\$(\d)", lambda g: m.group(int(g.group(1))) or "", result)
    return default


class MapTests(unittest.TestCase):
    conf = read("cullaapp.com.conf")

    def test_ip_short(self):
        block = map_block(self.conf, "$remote_addr", "$ip_short")
        cases = {
            "203.0.113.57": "203.0.113.0",
            "192.0.2.255": "192.0.2.0",
            "::ffff:198.51.100.7": "198.51.100.0",
            "2001:db8:5:6:7:8:9:a": "2001:db8:5::",
            "2001:db8:5::1": "2001:db8:5::",
            "2001:db8::1": "2001:db8::",
            "2001::1": "2001::",
            "2a02:aa1:1005:9c6:1d3c:6f1:fe2b:1": "2a02:aa1:1005::",
            "::1": "::",
            "unix:": "-",
        }
        for address, expected in cases.items():
            self.assertEqual(apply_map(block, address), expected, address)
            # The full address never survives, except where it has no host part.
            if address not in ("::1", "unix:"):
                self.assertNotEqual(apply_map(block, address), address)

    def test_bootstrap_uses_the_same_ip_map(self):
        full = map_block(self.conf, "$remote_addr", "$ip_short")
        boot = map_block(read("cullaapp.com.bootstrap.conf"), "$remote_addr", "$ip_short")
        self.assertEqual([(r.pattern, v) for r, v in full[0]], [(r.pattern, v) for r, v in boot[0]])
        self.assertEqual(full[1], boot[1])

    def test_language(self):
        found = map_block(self.conf, "$http_accept_language", "$cullaapp_lang_found")
        lower = map_block(self.conf, "$cullaapp_lang_found", "$cullaapp_lang")
        cases = {
            "ru-RU,ru;q=0.9,en;q=0.8": "ru",
            "tk": "tk",
            "de,fr": "en",
            "de,ru": "ru",
            "": "en",
            "en-GB,en;q=0.9,ru;q=0.8": "en",
            "de-DE, RU;q=0.5": "ru",
            "tk-TM": "tk",
            "ptk,entk": "en",
            "*": "en",
            "fr-CH, fr;q=0.9, tk;q=0.7, ru;q=0.5": "tk",
        }
        for header, expected in cases.items():
            self.assertEqual(apply_map(lower, apply_map(found, header) or ""), expected, header)


class StructureTests(unittest.TestCase):
    def test_csp_is_exact(self):
        snippet = read("snippets/security-headers.conf")
        self.assertIn('add_header Content-Security-Policy "%s" always;' % CSP, snippet)
        for header in ("Strict-Transport-Security", "X-Content-Type-Options",
                       "Referrer-Policy", "Content-Security-Policy"):
            self.assertRegex(snippet, r"(?m)^add_header %s .* always;$" % header)

    def test_every_block_with_add_header_includes_security_headers(self):
        text = strip_comments(rendered("cullaapp.com.conf", "yes", "yes"))
        # Walk all blocks; a block with its own add_header must include the snippet.
        stack, blocks = [], []
        for i, ch in enumerate(text):
            if ch == "{":
                stack.append(i)
            elif ch == "}":
                start = stack.pop()
                header = text[text.rfind("\n", 0, start) + 1:start].strip()
                blocks.append((header, start, i))
        for header, start, end in blocks:
            body = text[start + 1:end]
            # Remove nested blocks from the body.
            depth, own = 0, []
            for ch in body:
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                elif depth == 0:
                    own.append(ch)
            own = "".join(own)
            if "add_header" in own:
                self.assertIn("security-headers.conf", own, header)

    def test_no_full_address_in_any_log_format(self):
        for name in ("cullaapp.com.conf", "cullaapp.com.bootstrap.conf"):
            text = strip_comments(rendered(name, "yes", "yes"))
            for fmt in re.findall(r"log_format\s+\S+\s+escape=json(.*?);\n", text, re.S):
                self.assertNotIn("$remote_addr", fmt)
                self.assertNotIn("$binary_remote_addr", fmt)
                self.assertNotIn("$http_x_forwarded_for", fmt)
                self.assertIn("$ip_short", fmt)
            # Every server block writes its access log in one of our formats or not at all.
            for server in re.split(r"\nserver\s*\{", text)[1:]:
                logs = re.findall(r"access_log\s+([^;]+);", server)
                self.assertTrue(logs, "a server without its own access_log uses the distribution's")
                for log in logs:
                    self.assertTrue(log.strip() == "off" or " cullaapp_" in log, log)

    def test_locations_and_logs(self):
        text = strip_comments(rendered("cullaapp.com.conf", "no", "yes"))
        locations = re.findall(r"^\s*location\s+([^{]+?)\s*\{", text, re.M)
        self.assertEqual(locations, [
            "/",                                     # port 80: redirect to HTTPS
            "= /404.html", "^~ /_errors/", "= /", "/", "^~ /_nuxt/", "^~ /_nuxt/builds/",
            "~* \\.(?:png|jpe?g|webp|avif|gif|svg|ico|woff2?)$", "= /download",
        ])
        logs = set(re.findall(r"(?:access|error)_log\s+(\S+)", text))
        self.assertEqual(logs, {"/data/cullaapp.com/log/access.log", "/data/cullaapp.com/log/error.log"})
        self.assertEqual(re.findall(r"log_format\s+(\S+)", text), ["cullaapp_access"])
        # Nothing is accepted from visitors or passed on to another server.
        for directive in ("proxy_pass", "fastcgi_pass", "limit_req", "client_max_body_size",
                          "client_body", "listen unix:", "$request_body"):
            self.assertNotIn(directive, text)

    def test_variants(self):
        for name in ("cullaapp.com.conf", "cullaapp.com.bootstrap.conf"):
            for www, ipv6 in VARIANTS:
                with self.subTest(name=name, www=www, ipv6=ipv6):
                    raw = rendered(name, www, ipv6)
                    self.assertNotRegex(raw, r"(?m)#@!?(www|ipv6)\s*$|^\s*#@(begin|end) ")
                    text = strip_comments(raw)
                    https = name == "cullaapp.com.conf"
                    listens = sorted(re.findall(r"listen\s+([^;]+);", text))
                    expected = ["80"] + ["443 ssl"] * (https * (2 if www == "yes" else 1))
                    if ipv6 == "yes":
                        expected += ["[::]:" + l for l in expected]
                    self.assertEqual(listens, sorted(expected))
                    self.assertNotIn("default_server", text)
                    self.assertNotIn("http2;", text.replace("http2 on;", ""))  # no "listen ... http2"
                    self.assertEqual(text.count("http2 on;"), listens.count("443 ssl"))
                    names = re.findall(r"server_name\s+([^;]+);", text)
                    if www == "yes":
                        self.assertEqual(names[0], "cullaapp.com www.cullaapp.com")
                        if https:
                            self.assertEqual(names[1:], ["www.cullaapp.com", "cullaapp.com"])
                    else:
                        self.assertNotIn("www.cullaapp.com", text)
                        self.assertEqual(names, ["cullaapp.com"] * (2 if https else 1))
                    # The port-80 server answers certificate challenges from the host's snippet.
                    port80 = text[text.index("listen 80;"):]
                    port80 = port80[:port80.index("\n}")]
                    self.assertIn("include /etc/nginx/snippets/acme-challenge.conf;", port80)

    def test_render_refuses_bad_settings(self):
        env = dict(os.environ, CULLA_WITH_WWW="maybe")
        result = subprocess.run(["bash", os.path.join(DEPLOY, "remote-install.sh"), "render",
                                 os.path.join(DEPLOY, "cullaapp.com.conf")],
                                env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)

    def test_nothing_the_host_sets_at_http_level(self):
        # The host's nginx.conf and conf.d/00-default.conf set TLS protocols,
        # ciphers, session cache and tickets, server_tokens, gzip and the
        # timeouts at http level; a second one there is an error. Culla adds
        # only its maps, its log format and its servers.
        for name in ("cullaapp.com.conf", "cullaapp.com.bootstrap.conf"):
            for www, ipv6 in VARIANTS:
                self.assertEqual(set(top_level_directives(rendered(name, www, ipv6))),
                                 {"map", "log_format", "server"}, (name, www, ipv6))
        tls = [line for line in strip_comments(read("snippets/tls.conf")).splitlines() if line.strip()]
        self.assertEqual([line.split()[0] for line in tls], ["ssl_certificate", "ssl_certificate_key"])

    def test_download_location(self):
        text = strip_comments(read("cullaapp.com.conf"))
        block = re.search(r"location = /download \{(.*?)\}", text, re.S).group(1)
        steps = [line.strip() for line in block.splitlines() if line.strip()]
        self.assertEqual(steps, [
            "include /etc/nginx/cullaapp/snippets/security-headers.conf;",
            'add_header Cache-Control "no-store" always;',
            "error_page 503 /_errors/download-503.html;",
            "include /etc/nginx/cullaapp/download-target.con[f];",
            "include /etc/nginx/cullaapp/snippets/download-default.conf;",
        ])
        self.assertEqual(strip_comments(read("snippets/download-default.conf")).strip(), "return 503;")
        self.assertEqual(sorted(os.listdir(os.path.join(DEPLOY, "errors"))),
                         ["50x.html", "download-503.html", "errors.css"])

    def test_no_private_details(self):
        for root, _, files in os.walk(DEPLOY):
            if "/test" in root:
                continue
            for name in files:
                with open(os.path.join(root, name), encoding="utf-8", errors="replace") as f:
                    text = f.read()
                for address in re.findall(r"[\w.+-]+@[\w-]+\.[\w.-]+", text):
                    self.assertRegex(address, r"@example\.(org|invalid|com)$|@\$|@host",
                                     "%s: %s" % (name, address))


if __name__ == "__main__":
    unittest.main()
