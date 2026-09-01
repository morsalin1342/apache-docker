# Security Policy

## Supported versions

| Version | Supported |
|---------|-----------|
| 2.4.68  | :white_check_mark: |

The version tracks upstream `httpd`. Older tags stay on Docker Hub for reproducibility but do
not receive fixes — pull the current tag.

## Reporting a vulnerability

**Please report privately**, using GitHub's private vulnerability reporting:

- [Report a vulnerability](https://github.com/morsalin1342/apache-docker/security/advisories/new)

That keeps the details between us until there is a fix to ship. Please do not open a public
issue for a security problem.

Include:

- a clear description, and what an attacker gains
- steps to reproduce, ideally as a `docker run` a maintainer can paste
- the image tag affected, and whether it applies to `latest`, `-origin`, or both

Expect a first response within 48 hours.

## What is deliberately absent, and is not a vulnerability

**There is no WAF in this image.** No ModSecurity, no OWASP Core Rule Set. That is a decision,
not an omission: in the deployment these images are built for, a reverse proxy sits in front
and a WAF belongs where requests enter. If Apache is your outermost server, put one in front
of it. See the README.

**There is no PHP in this image.** PHP runs in a separate container and Apache reaches it over
FastCGI. A report that "PHP does not work out of the box" is a documentation question, not a
vulnerability — see the `a2enconf php-fpm` section of the README.

**`.php` returns 403 in the default configuration.** Deliberate. Apache here cannot execute
PHP, and a server that hands back the source of a file it cannot run discloses whatever is in
it. Refusing is the safe default; enabling `php-fpm.conf` grants it.

**Most modules ship unloaded.** The image carries 130 modules and loads 46 (`latest`) or 33
(`-origin`). An unloaded module is a file on disk that Apache never maps. If you enable one
with `a2enmod`, its configuration is yours.

## Upstream components

This image is the official `httpd` image plus configuration. It compiles nothing and vendors
no third-party modules.

- [httpd](https://hub.docker.com/_/httpd) — the official Apache HTTP Server image, pinned to a
  Debian-suffixed tag (`2.4.68-trixie`)

If a vulnerability is found in that base, the fix is a base-image bump and a rebuild.
