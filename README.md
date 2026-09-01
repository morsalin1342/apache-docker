# Apache Docker Image — static server, or php-fpm application server

[![Docker Pulls](https://img.shields.io/docker/pulls/morsalin1342/apache.svg?style=for-the-badge&logo=docker)](https://hub.docker.com/r/morsalin1342/apache)
[![GitHub Stars](https://img.shields.io/github/stars/morsalin1342/apache-docker?style=for-the-badge&logo=github)](https://github.com/morsalin1342/apache-docker)
[![License](https://img.shields.io/github/license/morsalin1342/apache-docker?style=for-the-badge)](https://github.com/morsalin1342/apache-docker/blob/master/LICENSE)

Official Apache, configured. **Static files by default; PHP over FastCGI with one line.**
There is no PHP in this image — it talks to [`morsalin1342/php`](https://hub.docker.com/r/morsalin1342/php)
running php-fpm in its own container.

```bash
docker pull morsalin1342/apache:latest
```

## Which tag

Two images, one Dockerfile, same 176 MB download. Pick by **where Apache sits**:

```yaml
image: morsalin1342/apache:2.4.68           # Apache faces clients
image: morsalin1342/apache:2.4.68-origin    # a reverse proxy / CDN / load balancer faces clients
```

| | main server | `-origin` |
|---|---|---|
| TLS, HTTP/2, brotli, rate limiting, ACME | ✅ | ❌ — whatever is in front already does it |
| Static, PHP over FastCGI, `ProxyPass`, rewrite, gzip | ✅ | ✅ |
| Modules loaded | 46 | 33 |
| Idle memory | 13.9 MiB | **7.3 MiB** |

The names come from edge/origin terminology: the *origin* is the server behind the thing facing
the internet. The split exists because 2.3× idle memory, paid by every container, is not a
rounding error — and an origin will never negotiate TLS or HTTP/2 however long it runs.

Switching later needs no new image: `a2enmod ssl http2 brotli ratelimit` on `-origin` is
exactly the difference.

## Why this image

Not modules. The official `httpd` image already **ships 130 of them** — rewrite, proxy_fcgi,
remoteip, brotli, http2 — it just does not *load* them. `httpd -M` on the stock image lists
no rewrite and no proxy_fcgi, which makes it, in effect, a static file server you have to
finish assembling.

So this image is the official Apache with the modules an application server needs turned on,
a base configuration that expects php-fpm next door, and a build that starts the server and
serves a request before publishing. Saying that plainly is better than inventing a
compilation story: **nothing here is compiled, and Apache is never rebuilt.**

| | Official `httpd` | This image |
|---|---|---|
| Modules loaded | 25 | **33** — see [MODULES.md](MODULES.md) |
| `mod_rewrite` | ❌ not loaded | ✅ |
| PHP over FastCGI | ❌ | ✅ one `Include` line |
| Real client IP behind a proxy | ❌ | ✅ `remoteip`, with trusted ranges |
| `.php` when PHP is off | served **as source** | ✅ refused |
| Document root | `/usr/local/apache2/htdocs` | `/var/www/html`, matching the php image |
| Startup proven at build | ❌ | ✅ starts and serves before publish |
| gzip compression | ❌ module present, unloaded | ✅ loaded **and** configured by type |
| `a2enmod` / `a2enconf` | ❌ Debian-only tools | ✅ shipped, with rollback on `httpd -t` failure |

## Static, by default

```bash
docker run -d -p 8080:80 -v "$PWD/site:/var/www/html" morsalin1342/apache
```

`.php` files are **refused with 403**, not served. That is the point: an image with no PHP
that hands back `config.php` as text is a credential-disclosure bug, and it is the default
behaviour of every Apache that has no PHP handler. Measured before the rule existed — a stock
container returned the file contents with a 200.

## PHP, with one line

```yaml
services:
  php:
    image: morsalin1342/php:8.4-fpm
    volumes: ["./src:/var/www/html"]

  apache:
    image: morsalin1342/apache
    depends_on: [php]
    volumes: ["./src:/var/www/html"]
    command: sh -c "a2enconf php-fpm && httpd-foreground"
    ports: ["8080:80"]
```

…and the container command turns PHP on:

```yaml
    command: sh -c "a2enconf php-fpm && httpd-foreground"
```

**Both containers must mount the application at the same path.** Apache maps a URL to a file
path and hands that path to php-fpm, which opens it itself — a mismatch produces
`Primary script unknown`, php-fpm looking for a file that exists only in the other container.

## What is deliberately absent

**PHP.** See above. `docker-php-ext-install`, Composer, WP-CLI and Node live in the php image,
and a deploy hook that runs `composer install` runs there.

**ModSecurity, or any WAF.** A WAF belongs where requests enter. This image is built to sit
behind a reverse proxy, and a second WAF behind the first inspects the same bytes for the same
verdict. If Apache is your outermost server, put one in front of it.

**TLS, HTTP/2, compression, rate limiting, caching.** All shipped, all off. The gateway
negotiates protocol and encoding with the client; re-compressing between two containers on one
host spends CPU to save nothing. Caching is [Souin](https://github.com/darkweak/souin)
standalone in front, so there is one cache with one TTL and one purge mechanism rather than
two.

Every one of these is one uncommented `LoadModule` away if this image is your edge —
[MODULES.md](MODULES.md) says which and why.

## a2enmod, a2dismod, a2enconf, a2disconf

These are **Debian's** commands and the official `httpd` image is Apache built from source, so
it has none of them — verified: `command -v a2enmod` finds nothing in the base, while
Debian's `php:apache` image has it at `/usr/sbin/a2enmod`. This image ships all four,
reimplemented against the upstream layout.

```bash
a2enmod --list             # every module in the image and whether it is enabled
a2enmod deflate http2      # uncomment the LoadModule lines httpd.conf already carries
a2dismod autoindex         # this image already does this one
a2dismod autoindex         # comment one back out
a2enconf php-fpm           # append an Include for conf/extra/php-fpm.conf
a2disconf php-fpm          # and remove it
```

**They do two things Debian's do not.**

*They test the configuration and roll back.* `a2dismod proxy` while `mod_proxy_fcgi` is enabled
exits 1 and leaves `httpd.conf` untouched, where the Debian original would write the change and
let Apache fail to start on the next reload.

*They resolve prerequisites both ways.* 16 of the 130 modules fail or come up silently broken
when enabled alone — and for several of them the config test passes and the breakage only shows
at runtime, so `httpd -t` cannot save you. `a2enmod ssl` pulls in `socache_shmcb`; `a2dismod
slotmem_shm` refuses while `proxy_balancer` is loaded. See MODULES.md.

## Configuration

| Path | What |
|---|---|
| `conf/extra/app-server.conf` | The base: document root, `.php` refusal, `remoteip`, hardening. Included. |
| `conf/extra/php-fpm.conf` | The FastCGI handler. Shipped, **included by nothing**. |

Both are plain files — mount over either. `php-fpm.conf` is syntax-checked at build in a
throwaway copy of `httpd.conf`, because a shipped file that nothing parses is one that can be
broken for a whole release with every build still green.

## Tags

| Tag | Role |
|---|---|
| `morsalin1342/apache:2.4.68` | Apache is the main server |
| `morsalin1342/apache:latest` | same, floating |
| `morsalin1342/apache:2.4.68-origin` | Apache is behind a reverse proxy |
| `morsalin1342/apache:origin` | same, floating |

The version tracks upstream httpd; a new patch release is a one-line bump. The unsuffixed tags
are deliberately the main-server image — someone typing `apache:latest` without reading this
should get the one that works when Apache is what clients reach.

## Licence

MIT — see [LICENSE](LICENSE).
