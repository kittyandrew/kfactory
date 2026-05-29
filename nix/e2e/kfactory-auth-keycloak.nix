{
  pkgs,
  kfactory,
  opencodePackage,
}: let
  keycloakRealm = ./kfactory-test-realm.json;

  dbPassword = pkgs.writeText "keycloak-db-password" "keycloak-test-password";

  recordingProxy = pkgs.writeText "recording-proxy.py" ''
    import http.client
    import sys
    import urllib.parse
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    listen_port = int(sys.argv[1])
    upstream_port = int(sys.argv[2])
    log_path = sys.argv[3]

    hop_by_hop = {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailers",
        "transfer-encoding",
        "upgrade",
    }

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            return

        def do_GET(self):
            self.forward()

        def do_POST(self):
            self.forward()

        def do_DELETE(self):
            self.forward()

        def forward(self):
            parsed = urllib.parse.urlparse(self.path)
            query = urllib.parse.parse_qs(parsed.query)
            workspace = self.headers.get("x-opencode-workspace") or (query.get("workspace", [""])[0])
            authorization = self.headers.get("authorization", "")
            with open(log_path, "a", encoding="utf-8") as log:
                log.write(f"{self.command} {self.path} workspace={workspace} authorization={authorization}\n")
                log.flush()

            body = None
            if "content-length" in self.headers:
                body = self.rfile.read(int(self.headers["content-length"]))

            headers = {k: v for k, v in self.headers.items() if k.lower() not in hop_by_hop and k.lower() != "host"}
            conn = http.client.HTTPConnection("127.0.0.1", upstream_port, timeout=60)
            try:
                conn.request(self.command, self.path, body=body, headers=headers)
                resp = conn.getresponse()
                self.send_response(resp.status, resp.reason)
                for key, value in resp.getheaders():
                    if key.lower() not in hop_by_hop:
                        self.send_header(key, value)
                self.end_headers()
                while True:
                    chunk = resp.read(8192)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                conn.close()

    ThreadingHTTPServer(("127.0.0.1", listen_port), Handler).serve_forever()
  '';

  formPostData = pkgs.writeText "form-post-data.py" ''
    import html.parser
    import sys
    import urllib.parse

    class FormParser(html.parser.HTMLParser):
        def __init__(self):
            super().__init__()
            self.fields = []

        def handle_starttag(self, tag, attrs):
            if tag.lower() != "input":
                return
            attr = dict(attrs)
            name = attr.get("name")
            if not name:
                return
            typ = attr.get("type", "text").lower()
            if typ in {"button", "file", "image", "reset"}:
                return
            if typ in {"checkbox", "radio"} and "checked" not in attr:
                return
            self.fields.append((name, attr.get("value", "")))

    html_path, output_path, *overrides = sys.argv[1:]
    parser = FormParser()
    with open(html_path, encoding="utf-8") as f:
        parser.feed(f.read())

    fields = parser.fields
    for override in overrides:
        name, value = override.split("=", 1)
        fields = [(k, v) for k, v in fields if k != name]
        fields.append((name, value))

    with open(output_path, "w", encoding="utf-8") as f:
        f.write(urllib.parse.urlencode(fields))
  '';
in
  pkgs.testers.nixosTest {
    name = "kfactory-auth-keycloak-integration";

    nodes.machine = {pkgs, ...}: {
      virtualisation.memorySize = 4096;

      environment.systemPackages = [
        kfactory
        opencodePackage
        pkgs.curl
        pkgs.git
        pkgs.htmlq
        pkgs.jq
        pkgs.python3
        pkgs.util-linux
      ];

      services.keycloak = {
        enable = true;
        initialAdminPassword = "admin-password1234";
        realmFiles = [keycloakRealm];
        database.passwordFile = "${dbPassword}";
        settings = {
          hostname = "127.0.0.1";
          hostname-strict = false;
          http-enabled = true;
          http-host = "127.0.0.1";
          http-port = 8080;
        };
      };
    };

    testScript = ''
      import json
      import shlex
      import time
      import urllib.parse

      def q(value):
          return shlex.quote(value)

      def env(prefix):
          return (
              "HOME=/tmp/kfactory-home "
              "XDG_CONFIG_HOME=/tmp/kfactory-config "
              "XDG_DATA_HOME=/tmp/kfactory-data "
              "XDG_STATE_HOME=/tmp/kfactory-state "
              "XDG_CACHE_HOME=/tmp/kfactory-cache "
              "KFACTORY_OIDC_AUDIENCE_SCOPE_TEMPLATE= "
              + prefix
          )

      auth_file = "/tmp/kfactory-config/kfactory/auth.json"
      issuer = "http://127.0.0.1:8080/realms/kfactory-test"
      server = "http://127.0.0.1:18080"
      minimal_opencode_config = "/tmp/minimal-opencode.jsonc"

      def keycloak_action_url(value):
          return urllib.parse.urljoin(issuer + "/", value)

      machine.start()
      machine.wait_for_unit("keycloak.service", timeout=360)
      machine.wait_for_open_port(8080)
      machine.wait_until_succeeds("curl -fsS http://127.0.0.1:8080/realms/kfactory-test/.well-known/openid-configuration | jq -e '.device_authorization_endpoint and (.grant_types_supported | index(\"urn:ietf:params:oauth:grant-type:device_code\"))'", timeout=180)
      machine.succeed("cat > /tmp/minimal-opencode.jsonc <<'EOF'\n{\"share\":\"disabled\",\"autoupdate\":false,\"autocompact\":false}\nEOF")

      with subtest("real kfactory auth login through Keycloak device flow"):
          machine.succeed("rm -rf /tmp/kfactory-home /tmp/kfactory-config /tmp/kfactory-data /tmp/kfactory-state /tmp/kfactory-cache")
          machine.succeed("mkdir -p /tmp/kfactory-home /tmp/kfactory-config /tmp/kfactory-data /tmp/kfactory-state /tmp/kfactory-cache")
          machine.succeed(
              env(
                  "kfactory auth login "
                  f"--server {q(server)} "
                  f"--issuer {q(issuer)} "
                  "--client-id kfactory "
                  "--audience kfactory "
                  ">/tmp/kfactory-login.out 2>/tmp/kfactory-login.err & echo $! >/tmp/kfactory-login.pid"
              )
          )
          machine.wait_until_succeeds("grep -q '^kfactory: open ' /tmp/kfactory-login.err", timeout=60)
          verify_url = machine.succeed("sed -n 's/^kfactory: open //p' /tmp/kfactory-login.err").strip()
          assert "/realms/kfactory-test/device" in verify_url, verify_url

          machine.succeed(f"curl -fsSL -c /tmp/keycloak.cookie {q(verify_url)} >/tmp/keycloak-login.html")
          machine.succeed("htmlq '#kc-form-login' --attribute action --filename /tmp/keycloak-login.html --output /tmp/keycloak-login-action")
          login_action = keycloak_action_url(machine.succeed("sed -n '1p' /tmp/keycloak-login-action").strip())
          machine.succeed(
              f"curl -fsSL -b /tmp/keycloak.cookie -c /tmp/keycloak.cookie "
              "-d username=device-login -d password=password1234 -d credentialId= "
              f"{q(login_action)} >/tmp/keycloak-after-login.html"
          )

          grant_count = machine.succeed("grep -c 'name=\"accept\"' /tmp/keycloak-after-login.html || true").strip()
          if grant_count != "0":
              machine.succeed("htmlq 'form' --attribute action --filename /tmp/keycloak-after-login.html --output /tmp/keycloak-grant-action")
              grant_action = keycloak_action_url(machine.succeed("sed -n '1p' /tmp/keycloak-grant-action").strip())
              machine.succeed("python3 ${formPostData} /tmp/keycloak-after-login.html /tmp/keycloak-grant-body accept=Yes")
              machine.succeed(
                  f"curl -fsSL -b /tmp/keycloak.cookie -c /tmp/keycloak.cookie "
                  "-H 'Content-Type: application/x-www-form-urlencoded' "
                  f"--data-binary @/tmp/keycloak-grant-body {q(grant_action)} >/tmp/keycloak-approved.html"
              )

          machine.wait_until_succeeds("grep -q 'kfactory: logged in' /tmp/kfactory-login.err || ! kill -0 $(cat /tmp/kfactory-login.pid)", timeout=120)
          machine.succeed("grep -q 'kfactory: logged in' /tmp/kfactory-login.err || { cat /tmp/kfactory-login.err; cat /tmp/kfactory-login.out; exit 1; }")
          machine.succeed(f"test -s {auth_file}")
          tokens = json.loads(machine.succeed(f"cat {auth_file}"))
          assert tokens["issuer"] == issuer, tokens
          assert tokens["client_id"] == "kfactory", tokens
          assert tokens["access_token"], tokens
          assert tokens["refresh_token"], tokens

      with subtest("real kfactory auth refresh rotates expired cache"):
          machine.succeed(
              f"tmp=$(mktemp); jq '.access_token = \"expired-direct-token\" | .expires_at = \"2000-01-01T00:00:00Z\"' {auth_file} > $tmp && mv $tmp {auth_file} && chmod 600 {auth_file}"
          )
          machine.succeed(env("kfactory auth refresh >/tmp/kfactory-refresh.out 2>/tmp/kfactory-refresh.err"))
          refreshed = json.loads(machine.succeed(f"cat {auth_file}"))
          assert refreshed["access_token"] != "expired-direct-token", refreshed
          assert refreshed["refresh_token"], refreshed
          assert time.time() < time.mktime(time.strptime(refreshed["expires_at"].split(".")[0].replace("Z", ""), "%Y-%m-%dT%H:%M:%S")), refreshed

      with subtest("patched opencode TUI spawns real kfactory auth refresh"):
          machine.succeed("rm -rf /tmp/opencode-server-home /tmp/tui-home /tmp/repo /tmp/proxy.log")
          machine.succeed("mkdir -p /tmp/opencode-server-home /tmp/tui-home /tmp/repo")
          machine.succeed("git -C /tmp/repo init")
          machine.succeed("git -C /tmp/repo config user.email test@example.invalid")
          machine.succeed("git -C /tmp/repo config user.name 'Test User'")
          machine.succeed("printf '# test repo\\n' >/tmp/repo/README.md && git -C /tmp/repo add README.md && git -C /tmp/repo commit -m initial")
          opencode_env = (
              "HOME=/tmp/opencode-server-home "
              "XDG_CONFIG_HOME=/tmp/opencode-server-home/.config "
              "XDG_DATA_HOME=/tmp/opencode-server-home/.local/share "
              "XDG_STATE_HOME=/tmp/opencode-server-home/.local/state "
              "XDG_CACHE_HOME=/tmp/opencode-server-home/.cache "
              "OPENCODE_EXPERIMENTAL_WORKSPACES=true "
              f"OPENCODE_CONFIG={minimal_opencode_config} "
              "OPENCODE_DISABLE_PROJECT_CONFIG=1 "
              "OPENCODE_DISABLE_AUTOUPDATE=1 "
              "OPENCODE_DISABLE_AUTOCOMPACT=1 "
              "OPENCODE_DISABLE_MODELS_FETCH=1 "
          )
          machine.succeed(opencode_env + "opencode serve --hostname 127.0.0.1 --port 4097 >/tmp/opencode-serve.out 2>/tmp/opencode-serve.err & echo $! >/tmp/opencode-serve.pid")
          machine.wait_for_open_port(4097)
          machine.succeed("python3 ${recordingProxy} 18080 4097 /tmp/proxy.log >/tmp/proxy.out 2>/tmp/proxy.err & echo $! >/tmp/proxy.pid")
          machine.wait_for_open_port(18080)

          machine.succeed(
              f"tmp=$(mktemp); jq '.access_token = \"expired-tui-token\" | .expires_at = \"2000-01-01T00:00:00Z\"' {auth_file} > $tmp && mv $tmp {auth_file} && chmod 600 {auth_file}"
          )
          tui_env = (
              "HOME=/tmp/tui-home "
              "XDG_CONFIG_HOME=/tmp/kfactory-config "
              "XDG_DATA_HOME=/tmp/tui-home/.local/share "
              "XDG_STATE_HOME=/tmp/tui-home/.local/state "
              "XDG_CACHE_HOME=/tmp/tui-home/.cache "
              f"OPENCODE_SERVER_BEARER_CACHE_PATH={auth_file} "
              "OPENCODE_EXPERIMENTAL_WORKSPACES=true "
              f"OPENCODE_CONFIG={minimal_opencode_config} "
              "OPENCODE_DISABLE_PROJECT_CONFIG=1 "
              "OPENCODE_DISABLE_AUTOUPDATE=1 "
              "OPENCODE_DISABLE_AUTOCOMPACT=1 "
              "OPENCODE_DISABLE_MODELS_FETCH=1 "
              "TERM=xterm-256color "
          )
          machine.succeed(tui_env + "script -q -e -c 'opencode attach http://127.0.0.1:18080 --workspace wrk_keycloak --continue' /dev/null >/tmp/tui-attach.out 2>/tmp/tui-attach.err & echo $! >/tmp/tui-attach.pid")
          machine.wait_until_succeeds(f"jq -e '.access_token != \"expired-tui-token\"' {auth_file}", timeout=90)
          tui_refreshed = json.loads(machine.succeed(f"cat {auth_file}"))
          expected_header = "authorization=Bearer " + tui_refreshed["access_token"]
          machine.wait_until_succeeds(f"grep -F {q(expected_header)} /tmp/proxy.log", timeout=90)
          machine.succeed("! grep -F 'authorization=Bearer expired-tui-token' /tmp/proxy.log")

          machine.succeed("kill $(cat /tmp/tui-attach.pid) $(cat /tmp/proxy.pid) $(cat /tmp/opencode-serve.pid) || true")
    '';
  }
