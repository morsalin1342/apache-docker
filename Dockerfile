# Apache: a static web server by default, a PHP application server on request.
#
# **This image contains no PHP.** PHP runs in its own container — the sibling
# `morsalin1342/php` image, php-fpm listening on :9000 — and Apache reaches it
# over FastCGI when you switch that on. That separation is the whole point: one
# image is a web server, the other is a PHP runtime with 57 extensions and a
# toolchain, and neither has to be rebuilt when the other moves.
#
# It follows that PHP cannot be the default. A stock `docker run` of this image
# serves static files; proxying .php to a container called `php` that nobody
# started would fail on the first dynamic request, naming something the user
# never configured. `conf/extra/php-fpm.conf` is shipped and loaded by nothing —
# one Include line away.
#
# # Why this image exists when the official one is right there
#
# It is not modules. The official `httpd` image ships **130 modules as .so
# files** — verified, not assumed — including rewrite, proxy, proxy_fcgi,
# remoteip, deflate, brotli and http2. What it does not do is *load* them: a
# stock container starts with twenty-odd modules enabled and is, in effect, a
# static file server. `httpd -M` on the official image lists no rewrite and no
# proxy_fcgi.
#
# So the work here is configuration, and saying so plainly is better than
# inventing a compilation story. This image is the official Apache with the
# modules a PHP application server needs turned on, a base configuration that
# expects php-fpm in another container, and a startup check that proves both.
#
# # What is deliberately absent, and why
#
# **ModSecurity, or any WAF.** Deliberately absent. This image is built to sit
# behind a gateway that holds :80 and :443, terminates TLS and reverse-proxies
# to this container. A WAF belongs where requests enter, and a second one behind
# it inspects the same bytes a second time for the same verdict. If you run this
# image as your edge, put a WAF in front of it.
#
# **TLS, HTTP/2, HTTP/3, compression, rate limiting.** Same reason. mod_ssl,
# mod_http2, mod_brotli and mod_deflate are all present in the image and all
# left off; the gateway negotiates the protocol and the encoding with the
# client, and re-compressing between two containers on the same host costs CPU
# to save nothing. Turn them on if this is your edge.
#
# **PHP.** See above. `docker-php-ext-install`, Composer, WP-CLI and Node live
# in the php image, and a deploy hook that runs `composer install` runs there.
#
# # What is turned on
#
#   rewrite      the reason Apache is chosen at all — applications whose URL
#                scheme ships as .htaccess (PrestaShop, Mautic, QloApps)
#   proxy        \ together, how a request for a .php file reaches php-fpm
#   proxy_fcgi   /
#   proxy_http   the other half of mod_proxy: ProxyPass to an HTTP backend. Not
#                needed for php-fpm, and that is exactly why it is easy to miss
#                — without it ProxyPass parses, Apache starts, and nothing is
#                proxied. Loaded so that reaching a Node or Python container is
#                configuration rather than a rebuild
#   remoteip     without it every access log line and every application that
#                reads REMOTE_ADDR sees the gateway's address, not the client's
#   headers      response header manipulation, which several applications need
#   expires      cache headers for static assets served directly
#   mime_magic   content type by content when the extension does not say
#   filter       required by deflate/brotli if you enable them later
#   unique_id    a per-request token in UNIQUE_ID, so one request can be
#                followed across the gateway's log, this one, and the
#                application's. Free, and the thing you wish you had enabled
#                the first time you try to trace a 502
#   allowmethods loaded, unset — one line (`AllowMethods GET POST HEAD`) is then
#                the whole of method hardening, and leaving it out would mean a
#                rebuild to get it
#   deflate      gzip, configured for text types in app-server.conf. A web
#                server that does not compress HTML is not a sensible default
#   logio        real bytes in/out per request, so the access log can answer
#                "how much did this cost" without guessing from Content-Length
#   socache_shmcb the TLS session cache. Loaded rather than left for a2enmod
#                because it is free, and because mod_ssl without it warns at
#                every start and does a full handshake on every connection
#
# # Two tags, because the two roles want different modules
#
#   apache:2.4.68           Apache is the main server, facing clients.
#   apache:latest           TLS, HTTP/2, brotli, rate limiting, ACME, and the
#                           proxy backends a front server reaches for.
#                           46 modules. ~16 MiB idle.
#
#   apache:2.4.68-origin    Apache is behind a reverse proxy — the "origin" in
#                           edge/origin terms. No TLS stack at all: the proxy
#                           terminates it. 33 modules. ~7 MiB idle.
#
# Same layers, same download; the only difference is which LoadModule lines are
# uncommented. The split exists because the measurement is not marginal — 16.2
# MiB against 7.1 MiB is 2.3x, paid by every container, and an origin server
# will never negotiate TLS or HTTP/2 no matter how long it runs.
#
# Neither list is "everything that would load". Both are hand-picked, and the
# origin list is the shared base the server list adds to, so a module is never
# in one and deliberately absent from the other by accident.
#
# What is excluded from *both*, and why, is in MODULES.md — which documents all
# 130 modules the image ships, with a recommendation for each.

ARG HTTPD_VERSION=2.4.68
ARG DEBIAN_RELEASE=trixie

# The Debian-tagged image, not the bare version tag.
#
# `httpd:2.4.68` and `httpd:2.4.68-trixie` are the same image today, and that is
# exactly why the suffix is written down: the unsuffixed tag follows whatever
# Debian release upstream considers current, so it moves to the next one without
# this file changing. An image whose base distribution changed underneath a
# published tag is a support question nobody can answer from the Dockerfile.
#
# Alpine variants exist and are not used here: the modules this image loads link
# against glibc through Apache's own build, and staying on one libc across the
# stack avoids a class of problem that only appears under load.
FROM httpd:${HTTPD_VERSION}-${DEBIAN_RELEASE} AS origin

ARG HTTPD_VERSION

LABEL org.opencontainers.image.title="apache" \
      org.opencontainers.image.description="Apache behind a reverse proxy: php-fpm application server, no PHP and no TLS stack inside" \
      org.opencontainers.image.source="https://github.com/morsalin1342/apache-docker" \
      org.opencontainers.image.licenses="MIT"

# curl for the startup check below, and for anything that health-checks this
# container. The official image has no HTTP client at all.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl; \
    rm -rf /var/lib/apt/lists/*

# a2enmod, a2dismod, a2enconf, a2disconf.
#
# These are **Debian's** commands, not Apache's, and the official httpd image is
# Apache built from source — so it has no /etc/apache2, no mods-available, and
# none of these scripts. Verified rather than assumed: `command -v a2enmod` in
# the stock image finds nothing, while Debian's own php:apache image has it at
# /usr/sbin/a2enmod.
#
# They are reimplemented here against this image's layout — uncommenting the
# LoadModule lines httpd.conf already carries, and appending Include lines for
# conf/extra fragments — because "sed the config file" is the alternative and
# nobody remembers the path.
#
# Each one runs `httpd -t` after the change and **restores the previous
# httpd.conf if it fails**, which Debian's do not. Disabling mod_proxy while
# mod_proxy_fcgi is still enabled is a container that cannot start; here it is a
# non-zero exit and an unchanged config.
# moddeps.sh is a shared table, not a copy in each script: 16 of the modules in
# this image fail or come up silently broken when enabled alone, and a2enmod
# needing to know that while a2dismod does not is how you get a container that
# starts today and refuses to start after an unrelated change.
COPY scripts/a2enmod scripts/a2dismod scripts/a2enconf scripts/a2disconf /usr/local/bin/
COPY scripts/moddeps.sh /usr/local/lib/apache-moddeps.sh
RUN chmod +x /usr/local/bin/a2enmod /usr/local/bin/a2dismod \
             /usr/local/bin/a2enconf /usr/local/bin/a2disconf

# The modules this role needs, through the command the image now ships.
#
# a2enmod rather than a sed loop: it is the same edit, it fails loudly when a
# module is not in the image, and it means the build exercises the script that
# users will run. A shim nobody's own build uses is a shim that breaks quietly.
RUN a2enmod rewrite proxy proxy_http proxy_fcgi remoteip expires mime_magic \
            filter deflate logio socache_shmcb unique_id allowmethods

# And one the stock image loads that this one should not.
#
# mod_autoindex generates a directory listing when DirectoryIndex finds no index
# file. `Options -Indexes` in app-server.conf already refuses that, so the module
# is dead weight — but it is dead weight whose whole purpose is to enumerate a
# directory to a stranger, and it is one `Options +Indexes` in somebody's vhost
# away from doing it. With the module gone that line is inert.
#
# No behaviour changes: a directory with no index file is 403 either way.
RUN a2dismod autoindex

# The document root, created before the configuration that names it.
#
# The official image serves /usr/local/apache2/htdocs; this one serves
# /var/www/html to match the php image's convention — see the note at the end of
# this file about why the two must agree. Apache refuses to start when
# DocumentRoot is not a directory, so it is made here rather than left for a
# bind mount to create: a container started without one would not come up at
# all, and "no volume mounted" should be an empty site, not a crash loop.
RUN mkdir -p /var/www/html

# The base configuration, included from httpd.conf — and the PHP one, which is
# not.
#
# One include rather than editing httpd.conf further: somebody will mount their
# own configuration over part of this image, and a single include line is one
# thing to restore rather than a diff to reconstruct.
#
# php-fpm.conf is copied and left unreferenced. `httpd -t` below therefore does
# not parse it, which is why the build check that follows explicitly includes it
# once — a shipped configuration file nothing ever parses is one that can be
# broken for a release without anybody noticing.
COPY conf/app-server.conf /usr/local/apache2/conf/extra/app-server.conf
COPY conf/module-defaults.conf /usr/local/apache2/conf/extra/module-defaults.conf
COPY conf/php-fpm.conf /usr/local/apache2/conf/extra/php-fpm.conf
RUN printf '\nInclude conf/extra/module-defaults.conf\nInclude conf/extra/app-server.conf\n' \
        >> /usr/local/apache2/conf/httpd.conf \
    && httpd -t

# Start Apache for real, and serve one request, before the image is published.
#
# `httpd -t` parses the configuration and does not run a module's own
# initialisation. That gap is real and not theoretical: a module can pass the
# config test and then abort every worker the moment the server starts.
#
# The request is for a static file rather than a .php one on purpose: there is no
# php-fpm to reach at build time, and a request that must fail proves nothing.
# What this checks is that Apache starts with these modules loaded and serves.
#
# The opt-in PHP configuration is syntax-checked separately, in a copy of
# httpd.conf that is thrown away. It is shipped and included by nothing, so
# without this it is the one file in the image that could be broken for an
# entire release with every build still green.
RUN set -eux; \
    cp /usr/local/apache2/conf/httpd.conf /tmp/with-php.conf; \
    printf '\nInclude conf/extra/php-fpm.conf\n' >> /tmp/with-php.conf; \
    httpd -t -f /tmp/with-php.conf; \
    rm -f /tmp/with-php.conf

RUN set -eux; \
    echo 'STARTUP-OK' > /var/www/html/.build-check; \
    httpd -k start; \
    for i in $(seq 1 20); do \
        curl -fsS -o /dev/null http://127.0.0.1/.build-check && break; \
        sleep 0.5; \
    done; \
    body="$(curl -fsS http://127.0.0.1/.build-check)"; \
    httpd -k stop; \
    sleep 1; \
    test "$body" = 'STARTUP-OK' || { echo "apache served '$body'"; exit 1; }; \
    rm -f /var/www/html/.build-check

# /var/www/html, matching the php image's own convention.
#
# The two containers mount the same application directory, and they must agree
# about where it is: Apache maps a URL to a file path and hands that *path* to
# php-fpm over FastCGI, which then opens it itself. A mismatch produces
# "Primary script unknown" — php-fpm looking for a file at a path that exists
# only in the other container.
WORKDIR /var/www/html


# ═════════════════════════════════════════════════════════════════════════════
# The main-server image — the default target, and the one `docker build .` makes
# ═════════════════════════════════════════════════════════════════════════════
#
# Everything above is the origin image: Apache behind something that already
# terminates TLS. This stage adds what Apache needs when it *is* the thing
# clients connect to.
#
# Hand-picked, one line at a time, not "enable everything that loads". 105 of
# the 130 modules will happily load together and start clean — measured — and
# the result is 16 MiB of modules nobody asked for, including WebDAV write
# surface, SSI, CGI and Apache's own demo filters. A default set is a set of
# decisions, so each of these is one:
#
#   ssl                  the reason this tag exists
#   http2                HTTP/2 to real clients. +3.4 MiB idle, which is not
#                        worth paying on an origin and plainly is here
#   brotli               better than gzip, and browsers only offer `br` over
#                        HTTPS — so it is useful in exactly this tag and dead
#                        weight in the other one
#   ratelimit            bandwidth control belongs where requests arrive
#   md                   ACME, so certificates can renew themselves without a
#                        second container. Pulls in watchdog
#   proxy_wstunnel       WebSockets. The most common thing to reach for after
#                        proxy_http, and its absence is a confusing failure
#   proxy_uwsgi          Python backends that speak uWSGI rather than HTTP
#   proxy_balancer       more than one backend. Pulls in slotmem_shm
#   lbmethod_byrequests  a balancer with no algorithm balances nothing; this is
#                        the sane default one
#   vhost_alias          several sites from one container, which a front server
#                        does far more often than an origin does
#   macro                <Macro> in configuration — worth it once you are
#                        hand-writing more than one vhost
#
# Deliberately still absent, in both tags: cgi/cgid and lua (this image runs no
# code), mod_info (renders your whole configuration at a URL), proxy_connect
# (an open forward proxy), dav (a write surface), autoindex, and Apache's demo
# and debugging filters. MODULES.md gives the reason for each.
FROM origin AS server

LABEL org.opencontainers.image.description="Apache as a main server: TLS, HTTP/2, brotli and ACME, with no PHP inside"

RUN a2enmod ssl http2 brotli ratelimit md \
            proxy_wstunnel proxy_uwsgi proxy_balancer lbmethod_byrequests \
            vhost_alias macro

# Start it for real, exactly as the origin stage does.
#
# The config test does not run a module's initialisation, and this stage loads
# thirteen more modules than the one that was already proven — including mod_md,
# which starts a watchdog thread, and mod_ssl, which initialises OpenSSL. Those
# are precisely the things `httpd -t` cannot tell you about.
RUN set -eux; \
    echo 'STARTUP-OK' > /var/www/html/.build-check; \
    httpd -k start; \
    for i in $(seq 1 20); do \
        curl -fsS -o /dev/null http://127.0.0.1/.build-check && break; \
        sleep 0.5; \
    done; \
    body="$(curl -fsS http://127.0.0.1/.build-check)"; \
    httpd -k stop; \
    sleep 1; \
    test "$body" = 'STARTUP-OK' || { echo "apache served '$body'"; exit 1; }; \
    rm -f /var/www/html/.build-check

WORKDIR /var/www/html
