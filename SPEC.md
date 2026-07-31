# OpenHost App Spec: JupyterLab Multi-Language Notebook Environment

Repo (planned): github.com/imbue-openhost/openhost-jupyter (private)

## 1. Goal

Ship a single OpenHost app that presents a JupyterLab web IDE to the
OpenHost owner, with multiple language kernels available (Python and
OCaml at minimum) and the ability to add more kernels at runtime that
persist across restarts. The owner is auto-logged-in via OpenHost SSO;
no anonymous access to the compute environment.

## 2. What the user gets

- A browser-based JupyterLab (notebook editor, file browser, terminals,
  text editors, extensions) at `https://jupyter.<zone-domain>/`.
- Baked-in kernels: **Python 3** (ipykernel) and **OCaml** (ocaml-jupyter).
- Ability to install additional kernels at runtime (Deno/JS, R, Bash,
  etc.) into the persistent data dir so they survive restarts.
- Notebooks and files persisted under the OpenHost app data dir.

## 3. Architecture

```
OpenHost router  (verifies zone_auth, stamps X-OpenHost-Is-Owner: true)
      |
      v  (port 8080)
auth_proxy.py  (SSO sidecar — Pattern A/E hybrid)
      |  injects Jupyter token for owner, serves /_healthz, rewrites Host
      v  (loopback :8888)
JupyterLab  (token auth, base process)
      |
      +-- Python kernel (ipykernel)
      +-- OCaml kernel (ocaml-jupyter)
      +-- (runtime-added kernels from persistent dir)
```

Single container. `start.sh` supervises JupyterLab + auth_proxy with
`wait -n`. No s6.

## 4. SSO design (the important part)

JupyterLab has **no user/session database** — it authenticates with a
single shared token (or password) passed as `?token=` or the
`_xsrf` + token cookie. So Pattern B2 (DB INSERT) does not apply.
The correct fit is a **Pattern A / E hybrid**:

- On startup, `start.sh` generates a random Jupyter token
  (`JUPYTER_TOKEN`, in-memory / env only — NOT written to app_data).
- JupyterLab runs with that token and with
  `--ServerApp.token=$JUPYTER_TOKEN`, base_url `/`, and
  `allow_origin` / `trusted hosts` set for the zone domain.
- `auth_proxy.py` listens on 8080 and reverse-proxies to 127.0.0.1:8888.
- Owner-bounce logic:

  ```python
  is_owner = headers.get("X-OpenHost-Is-Owner","").lower() == "true"
  has_jupyter_cookie = <jupyter session cookie present>
  is_html_navigation = GET and "text/html" in Accept
  if is_owner and not has_jupyter_cookie and is_html_navigation:
      # 302 the owner to /?token=<JUPYTER_TOKEN> so Jupyter mints
      # its own cookie, then subsequent requests carry it.
      redirect_with_token()
  else:
      proxy_through()
  ```

- Non-owner / anonymous requests are proxied WITHOUT the token, so
  Jupyter's own auth rejects them (login page / 403). No public paths.
- WebSocket upgrade (kernel comms) must be proxied: the sidecar must
  handle `Upgrade: websocket` and pass it through to 8888. This is the
  one real complexity — a plain HTTP proxy is not enough for Jupyter.
  Options:
    a. Use a small async proxy that supports WS (e.g. based on
       `websockets`/`aiohttp` or `httpx` + raw socket bridge), OR
    b. Front with nginx (proxy_pass + `Upgrade`/`Connection` headers)
       and use a tiny auth subrequest that reads X-OpenHost-Is-Owner.
  **Recommendation: nginx for the proxy + WS handling, plus a tiny
  Python `auth` endpoint / Lua-less njs, OR just do the token-inject
  redirect at nginx level with a `map`/`auth_request`.** nginx is the
  robust choice for Jupyter's websockets.

### Chosen approach

nginx as the front proxy on :8080:
- `location = /_healthz` → static 200 (health check).
- `location /` → `proxy_pass http://127.0.0.1:8888;` with full
  WebSocket upgrade headers, `proxy_set_header Host $http_x_forwarded_host`,
  `X-Forwarded-Proto https`.
- An `auth_request` (or `map` on `$http_x_openhost_is_owner`) drives a
  tiny loopback Python endpoint that, for owner HTML navigations with no
  Jupyter cookie, returns a redirect to `/?token=<token>`. Simpler
  alternative: an njs/Lua-free approach where nginx `map`s the owner
  header to add `?token=` on the root navigation only.

Keep it as simple as possible while correctly handling websockets.

## 5. Kernels

### Baked in
- **Python 3**: `pip install jupyterlab ipykernel`. Default kernel.
- **OCaml**: install system OCaml + opam, `opam init`, `opam install
  jupyter`, then `ocaml-jupyter-opam-genspec` / `jupyter kernelspec
  install`. Heaviest part of the build.

### Runtime-extensible
- Set `JUPYTER_DATA_DIR` (and kernelspec search path) to include a dir
  under `$OPENHOST_APP_DATA_DIR/jupyter` so kernels the owner installs
  at runtime persist across container restarts.
- Document in README how to add e.g. Deno (`deno jupyter --install`),
  R (`IRkernel::installspec()`), Bash (`bash_kernel`).
- Caveat: runtime-installed toolchains that live outside the persistent
  dir (apt packages) will NOT persist. Only kernelspecs + things written
  under app_data persist. This is a documented limitation.

## 6. Persistence

- `$OPENHOST_APP_DATA_DIR/notebooks` → Jupyter root / working dir.
- `$OPENHOST_APP_DATA_DIR/jupyter` → JUPYTER_DATA_DIR (kernelspecs,
  runtime state).
- `chown` these to the Jupyter run-user in start.sh before launch
  (common OpenHost pitfall: unprivileged upstream user can't write to
  bind mount).

## 7. Credential-leak safety

- The Jupyter token is generated at each startup, kept in env only,
  never written to a file under app_data. file-browser (if installed
  with access_all_data) sees nothing usable.
- No password file, no admin-credentials file.
- `start.sh` should `rm` any stale token file from earlier iterations.

## 8. Manifest (openhost.toml)

```toml
[app]
name = "jupyter"
version = "0.1.0"
description = "JupyterLab multi-language notebook environment (Python + OCaml)"
authors = ["Andrew Laack <andrew@laack.co>"]

[runtime.container]
image = "Dockerfile"
port = 8080

[routing]
health_check = "/_healthz"
# No public_paths — compute env is owner-only.

[resources]
memory_mb = 2048        # OCaml + Python + kernels; bump if adding more
cpu_millicores = 1000

[data]
app_data = true
app_temp_data = true
```

Resource note: OCaml toolchain + JupyterLab is memory-hungry at build
and run; 2 GB is a safe starting point. Tune after measuring.

## 9. Repo layout

```
openhost-jupyter/
  Dockerfile          # base python image + JupyterLab + OCaml/opam + kernel
  openhost.toml
  start.sh            # supervise nginx + jupyter; chown; gen token
  nginx.conf          # front proxy w/ WS upgrade + owner token-inject
  (optional) auth_endpoint.py  # only if map/auth_request needs it
  README.md           # auth model, adding kernels, persistence caveats
  .gitignore
```

## 10. Build outline (Dockerfile)

1. FROM a Debian/Ubuntu python base (or `jupyter/base-notebook`).
2. Install JupyterLab + ipykernel (pip).
3. Install OCaml + opam + system deps (m4, pkg-config, libzmq3-dev,
   libgmp-dev). `opam init --disable-sandboxing -y`,
   `opam install -y jupyter`, register the kernelspec.
4. Install nginx.
5. Install python3 for the tiny auth endpoint if used.
6. Copy start.sh, nginx.conf, scripts; chmod +x.
7. ENTRYPOINT start.sh.

Multi-stage not strictly required but could trim the opam build cache.

## 11. Known risks / open questions

- **WebSocket proxying** is the main technical risk; must be verified
  end-to-end (open a notebook, run a cell, confirm kernel round-trips).
- **Image size / build time**: OCaml/opam is slow to build. Expect a
  large image (~1 GB) and multi-minute builds. Consider pinning
  versions and caching the opam step.
- **Owner-only trade-off**: no anonymous / public notebook sharing.
  If sharing is later wanted, would need nbviewer-style read-only
  export, not live kernels.
- **Runtime kernel persistence** is partial (kernelspecs persist,
  apt-level toolchains do not). Documented, not solved.
- **XSRF / Host validation**: Jupyter checks Host + _xsrf; nginx must
  forward X-Forwarded-Host as Host and set X-Forwarded-Proto https.

## 12. Verification plan (on a provisioned Hetzner instance)

1. Deploy; wait for running.
2. Owner SSO: curl with Bearer + Accept: text/html → should land in
   JupyterLab, no token prompt.
3. Anonymous: curl without token → Jupyter login/403, NOT the IDE.
4. WebSocket: automated headless check (or manual) — open a Python
   notebook, run `1+1`, confirm output; same for OCaml.
5. Persistence: create a notebook, restart app, confirm it's still
   there.
6. Credential leak: ssh in, list app_data dir, confirm no token/password
   file.
7. Vet barrage (Codex + Claude Code + OpenCode agentic + LLM APIs),
   fix relevant issues, re-run until clean.
8. Teardown the test instance.

## 13. Deliverable

Draft PR against github.com/imbue-openhost/openhost-jupyter (private),
concise title/description, no markdown in PR body, branch off main.
