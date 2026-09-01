# Contributing

Thanks for your interest in improving this Apache Docker image.

## What this image is

The official `httpd` image with configuration on top. **It compiles nothing.** Apache already
ships all 130 modules as `.so` files; this image decides which ones to load, supplies a base
configuration, and adds the `a2enmod` family that the source-built official image lacks.

So "add a module" here means *enable a module Apache already has*, which is a one-line change —
and usually you do not need a change at all, because `a2enmod <name>` works at runtime with no
rebuild.

## How to contribute

### Ask for a module in the default set

Check first whether you need the change at all:

```bash
docker run --rm morsalin1342/apache a2enmod --list      # is it already enabled?
docker run --rm morsalin1342/apache a2enmod <name>      # does enabling it at runtime do the job?
```

If it should be on by default, open an issue with the title `Module: <name>` and say:

1. **Which tag** — `latest` (Apache is the main server) or `-origin` (behind a reverse proxy),
   and why it belongs in that one
2. **What breaks without it**, concretely. "ProxyPass silently does nothing without
   `proxy_http`" is a reason; "it might be useful" is not
3. **What it costs.** Measure it — the numbers in MODULES.md were produced this way:

   ```bash
   docker run -d --name m morsalin1342/apache sh -c 'a2enmod <name> && httpd-foreground'
   sleep 3 && docker stats --no-stream m && docker logs m | grep warn
   ```

   A module that is free is an easy yes. `mod_http2` costs +3.4 MiB idle, which is why it is in
   one tag and not the other.

MODULES.md documents every one of the 130 modules and why it is on or off. If you disagree with
a call, that file is the argument to engage with.

### Report a bug

Open an issue with the image tag, what you expected, and what happened. Useful output:

```bash
docker run --rm morsalin1342/apache httpd -V     # build details
docker run --rm morsalin1342/apache httpd -M     # what is loaded
docker run --rm morsalin1342/apache a2enmod --list
```

If Apache will not start, `docker logs` on the container is the thing to paste — the config
test and the startup log say different things, and the startup log is usually the one with the
answer.

### Open a pull request

1. Fork, and branch from `master`
2. Build **both** targets — they are not the same image:

   ```bash
   docker build --target origin -t test-apache:origin .
   docker build -t test-apache:latest .
   ```
3. Both must start clean, with no warnings:

   ```bash
   docker run --rm test-apache:latest sh -c 'timeout 3 httpd -DFOREGROUND 2>&1 | grep warn'
   ```
4. If you touched `scripts/`, sweep every module — enable each one alone, config-test it, and
   start it. That sweep is how the dependency table in `scripts/moddeps.sh` was built, and it
   is the only thing that catches a module which passes `httpd -t` and is broken at runtime.
5. Open the PR against `master`

## Project structure

```
.
├── Dockerfile                  # two targets: `origin`, then `server` FROM it
├── conf/
│   ├── app-server.conf         # the base configuration, always included
│   ├── module-defaults.conf    # IfModule-guarded settings, inert until you a2enmod
│   └── php-fpm.conf            # the PHP opt-in, included by nothing
├── scripts/
│   ├── a2enmod, a2dismod, a2enconf, a2disconf
│   └── moddeps.sh              # shared prerequisite table, sourced by both
├── .github/workflows/          # builds and pushes both tags
├── MODULES.md                  # all 130 modules, with a verdict for each
├── README.md                   # GitHub README
├── README.dockerhub.md         # Docker Hub description (personal)
└── README.dockerhub-org.md     # Docker Hub description (org)
```

`README.dockerhub*.md` are generated from `README.md` — regenerate rather than hand-edit:

```bash
sed -e 's|\[MODULES.md\](MODULES.md)|MODULES.md in the GitHub repo|g' \
    -e 's|\[LICENSE\](LICENSE)|the LICENSE file|' README.md > README.dockerhub.md
cp README.dockerhub.md README.dockerhub-org.md
```

## Version upgrades

1. Bump `ARG HTTPD_VERSION` and, if the base moved, `ARG DEBIAN_RELEASE` in the `Dockerfile`.
   The Debian suffix is pinned on purpose: `httpd:2.4.68` follows whatever release upstream
   considers current, so an unsuffixed tag can change distribution underneath you
2. Rebuild both targets and confirm the module counts are unchanged — a renamed or dropped
   module in a new httpd release is exactly what this catches
3. CI detects the version from the `Dockerfile` for tagging

## Style

- Record **why**, not just what. The Dockerfile and `conf/` comments are the standard: every
  non-obvious decision says what it costs and what breaks without it
- Prefer a measurement to an assertion. Claims in this repo about memory, warnings and
  behaviour came from running the container, and a PR that changes one should re-measure
- Keep `moddeps.sh` the single place prerequisites are written down
