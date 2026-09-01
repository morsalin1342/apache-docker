# Every module in this image, and what to do with it

The image ships **130 modules** as `.so` files. How many are loaded depends on which of the two
tags you pull, because the two roles genuinely want different sets.

| Tag | Role | Modules | Idle RSS |
|---|---|---|---|
| `apache:2.4.68`, `apache:latest` | **Apache is the main server**, facing clients | 46 | 13.9 MiB |
| `apache:2.4.68-origin`, `apache:origin` | **Apache is behind a reverse proxy** that terminates TLS | 33 | 7.3 MiB |

Stock `httpd` loads 22 for comparison. (`httpd -M` reports 49, 36 and 25 — it counts `core`,
`http` and `so`, which are compiled in and have no file.)

Same layers and the same 176 MB download; the only difference is which `LoadModule` lines are
uncommented. The split exists because the measurement is not marginal — **2.3×**, paid by every
container, and an origin server will never negotiate TLS or HTTP/2 no matter how long it runs.

**Both lists are hand-picked.** 105 of the 130 modules will happily load together and start
clean — that is measured, not assumed — and the result is a container carrying WebDAV write
surface, SSI, CGI and Apache's own demo filters that nobody asked for. A default set is a set
of decisions, so each module below is one. The origin list is the shared base that the
main-server list adds to, so nothing is in one tag and absent from the other by accident.

Enumerated from the image itself, not from Apache's documentation index:

```bash
docker run --rm morsalin1342/apache ls /usr/local/apache2/modules/   # 131 files, incl. httpd.exp
docker run --rm morsalin1342/apache httpd -M                        # what is actually loaded
```

Nothing below needs a rebuild. `a2enmod <name>` uncomments the `LoadModule` line httpd.conf
already carries, runs `httpd -t`, and rolls back if it fails.

---

## The short answer

**Pick the tag that matches where Apache sits**, and the defaults are right as shipped:

```yaml
image: morsalin1342/apache:2.4.68           # Apache faces clients
image: morsalin1342/apache:2.4.68-origin    # nginx/Cloudflare/ALB faces clients
```

Neither needs modules added for the ordinary cases — static sites, PHP over FastCGI,
reverse-proxying to a Node or Python container, `.htaccess`-style rewriting, gzip. Anything
beyond that is one `a2enmod` away with no rebuild, which is exactly why neither list is longer.

If you are on `-origin` and later put Apache in front, you do not need to switch images:
`a2enmod ssl http2 brotli ratelimit` is the difference.

**Never on a public server:** `proxy_connect` (turns Apache into an open forward proxy),
`info` (renders your entire configuration at a URL), `include` (SSI — makes any writable file
a code path), `lua`, `cgi`/`cgid`.

---

## Enabling a module is meant to just work

`a2enmod` resolves prerequisites. This matters more than it sounds: **16 of the 130 modules
either fail to load or come up silently broken when enabled on their own**, and Apache reports
that three different ways.

```
httpd -t fails    mod_dav_fs.so: undefined symbol: dav_do_find_liveprop
starts, broken    AH01177: Failed to lookup provider 'shm' for 'slotmem':
                    is mod_slotmem_shm loaded??
warns only        AH01873: Init: Session Cache is not configured
```

The middle case is the dangerous one — the config test passes, the container starts, and the
feature quietly does nothing. `httpd -t` cannot catch it, which is why `scripts/moddeps.sh`
exists and is consulted before the edit rather than after.

```console
$ a2enmod lbmethod_heartbeat
a2enmod: proxy is already enabled
a2enmod: enabling slotmem_shm (required by lbmethod_heartbeat)
a2enmod: enabling proxy_balancer (required by lbmethod_heartbeat)
a2enmod: enabling watchdog (required by lbmethod_heartbeat)
a2enmod: enabling heartmonitor (required by lbmethod_heartbeat)
a2enmod: enabling lbmethod_heartbeat
a2enmod: done — restart Apache for it to take effect
```

`a2dismod` checks the same table in reverse and refuses to orphan a dependent, again before
the edit — because disabling `slotmem_shm` under a live `proxy_balancer` passes `httpd -t`
perfectly and breaks the balancer at runtime.

Two exceptions are refusals rather than resolutions. **MPMs conflict**: only one may load, and
swapping yours out because you asked for a different one is a bigger decision than a helper
command should make, so `a2enmod mpm_prefork` tells you to run `a2dismod mpm_event` first.

**Verified by re-running the sweep.** Every one of the 100 unloaded modules is enabled on its
own, config-tested, and started in the foreground:

| | modules that fail, warn, or come up broken |
|---|---|
| before the dependency table | 16 |
| after | **2** — `mpm_prefork` and `mpm_worker`, both refused on purpose |

Re-run it after touching `moddeps.sh`: Apache reports the *first* missing prerequisite, not the
set, so one pass can only ever uncover one layer.

### Defaults that keep the log clean

`conf/extra/module-defaults.conf` is included by `httpd.conf` and is entirely `<IfModule>`
blocks, so it is inert until you enable something. It carries **only** settings Apache itself
asks for — a module that logs a warning until configured. Never anything that changes what the
server does: enabling `mod_deflate` will not silently start compressing your responses,
because somebody reading their own configuration would have no idea where that came from.

Exactly one module in the image needs this. `mod_ssl` logs `AH01873` at every start with no
`SSLSessionCache`, and that is not just noise — with no cache, every connection does a full
handshake, resumed ones included. The file supplies the directive, `a2enmod ssl` pulls in the
`socache_shmcb` provider, and the result is a clean start:

```console
$ docker run --rm morsalin1342/apache sh -c 'a2enmod ssl >/dev/null && httpd-foreground'
[mpm_event:notice] AH00489: Apache/2.4.68 (Unix) OpenSSL/3.5.6 configured -- resuming normal operations
```

Verified by mutation, not by reading it back: deleting the `Include` line brings the warning
count from 0 to 1.

---

## What an unconfigured module actually costs

Measured, because the intuition here is wrong. Each row is this image plus those modules and
nothing else — no `SSLEngine`, no `Protocols`, no `SetOutputFilter`, no `rate-limit` — serving
one static file:

| Loaded | Idle RSS | Startup warnings | Response |
|---|---|---|---|
| as shipped | 7.2–7.6 MiB | none | — |
| `+ ssl socache_shmcb` | 8.1 MiB | **one**, every start | identical |
| `+ http2` | 11.3–11.9 MiB | none | identical |
| `+ brotli ratelimit` | 7.1 MiB | none | identical |

**Behaviour does not change.** No extra port is opened — `ssl` alone does not listen on 443,
that takes a `Listen`. `brotli` does not compress: with `Accept-Encoding: br,gzip` the response
carries no `Content-Encoding` and no `Vary`, because nothing put the filter in the chain.
`http2` advertises no `h2c` upgrade without `Protocols`. Diffing the full response headers
between the stock build and one with all four loaded gives no difference at all.

**The cost is `http2`, not `ssl`** — the reverse of what you would guess. mod_http2 allocates
its worker pools and buffers at startup whether or not any connection will ever negotiate h2:
about +4.2 MiB idle. mod_ssl links OpenSSL for about +1 MiB. `brotli` and `ratelimit` are free
to the nearest tenth of a MiB.

**`ssl` warns on every start until you configure the session cache:**

```
[ssl:warn] AH01873: Init: Session Cache is not configured [hint: SSLSessionCache]
```

Loading `socache_shmcb` does not silence it — the directive does:

```apache
SSLSessionCache shmcb:/usr/local/apache2/logs/ssl_scache(512000)
```

Verified: with that line the warning count is zero.

So: enabling all four "just in case" is safe and does nothing visible, at roughly +4.5 MiB and
one recurring log warning. The real argument against it is not memory — it is that a loaded
module is code in the process, and `ssl` in particular means every OpenSSL advisory now
applies to a container that is not serving TLS. Turn them on when you use them.

---

## All 130

`ON stock` = loaded by the official image and kept. `ON added` = enabled by this image, in
**both** tags. `ON server` = only in the main-server tag, not in `-origin`. `off` = shipped and
not loaded in either.

| Module | State | What to do with it |
|---|---|---|
| `access_compat` | ON stock | Translates 2.2's `Order`/`Allow`/`Deny`. Only needed if you paste an old config in. |
| `actions` | off | Runs a CGI script per media type. This image executes nothing. |
| `alias` | ON stock | `Alias`, `Redirect`. Nearly every real vhost uses it. |
| `allowmethods` | ON added | Loaded and unset — `AllowMethods GET POST HEAD` is then the whole of method hardening. |
| `asis` | off | Files that carry their own HTTP headers. Legacy. |
| `auth_basic` | ON stock | HTTP Basic. Covers "put a password on the staging site". |
| `auth_digest` | off | Digest auth. Superseded by Basic over TLS. |
| `auth_form` | off | Apache-rendered login form. Applications do their own. |
| `authn_anon` | off | Anonymous-FTP-style logins. |
| `authn_core` | ON stock | `AuthType` and friends. Required by any auth at all. |
| `authn_dbd` | off | Users from SQL. Needs `dbd`. The application's job. |
| `authn_dbm` | off | Users from a DBM file. |
| `authn_file` | ON stock | htpasswd backend for `auth_basic`. |
| `authn_socache` | off | Caches auth lookups — only worth it with a slow backend you are not using. |
| `authnz_fcgi` | off | Authorization delegated to a FastCGI authorizer. Only if you build one. |
| `authnz_ldap` | off | LDAP auth. Enable with `ldap` if you gate staging on a corporate directory. |
| `authz_core` | ON stock | `Require`. Non-optional. |
| `authz_dbd` | off | Group lookup from SQL. |
| `authz_dbm` | off | Group lookup from DBM. |
| `authz_groupfile` | ON stock | Groups from a plain file. |
| `authz_host` | ON stock | `Require ip` / `Require host`. |
| `authz_owner` | off | Authorize by file owner — meaningless when every file is one uid. |
| `authz_user` | ON stock | `Require valid-user`. |
| `autoindex` | **off — stock loads it, this image unloads it** | Directory listings. `Options -Indexes` already refused them, but the module's whole purpose is enumerating a directory to a stranger and it was one `Options +Indexes` away from doing it. A directory with no index file is 403 either way. |
| `brotli` | **ON server** | Better ratio than gzip, and browsers only offer `br` over HTTPS — so it is useful in exactly this tag and dead weight in the other. |
| `bucketeer` | off | Splits the filter chain's buckets. Apache's own debugging aid. |
| `buffer` | off | Buffers bodies in memory. Rarely wanted in front of FastCGI. |
| `cache` | off | See the caching note below — Souin does this in this stack. |
| `cache_disk` | off | Disk backend for `cache`. |
| `cache_socache` | off | Shared-object-cache backend for `cache`. |
| `case_filter` | off | Example output filter (uppercases the body). Demo code. |
| `case_filter_in` | off | Example input filter. Demo code. |
| `cern_meta` | off | CERN httpd metafiles. |
| `cgi` | off | Forks per request and requires `mpm_prefork`. **Never alongside `mpm_event`.** |
| `cgid` | off | The event-safe CGI daemon. Still: no code runs in this image. |
| `charset_lite` | off | Recodes charsets in flight. Applications emit UTF-8. |
| `data` | off | Server-generated `data:` URLs. Niche. |
| `dav` | off | WebDAV. Enable with `dav_fs` + `dav_lock` for a file-share vhost — a write surface, so not by default. |
| `dav_fs` | off | Filesystem provider for `dav`. Useless alone. |
| `dav_lock` | off | Locking for `dav`. |
| `dbd` | off | SQL connection pool for the `*_dbd` modules. |
| `deflate` | ON added | gzip, configured for text types in `app-server.conf`. Compresses proxied responses too — a JSON body from php-fpm has no extension, which is why the filter is by Content-Type. |
| `dialup` | off | Throttles to modem speed. Not a serious module. |
| `dir` | ON stock | `DirectoryIndex`. Required. |
| `dumpio` | off | Logs every byte in and out. Debugging only — the logs are enormous. |
| `echo` | off | Echo-protocol demo. |
| `env` | ON stock | `SetEnv`, `PassEnv`, `UnsetEnv`. |
| `example_hooks` | off | Apache's hook-API demo. |
| `example_ipc` | off | Apache's IPC demo. |
| `expires` | ON added | `Expires`/`Cache-Control` on static assets Apache serves directly. |
| `ext_filter` | off | Pipes responses through an external program. Slow, and an execution surface. |
| `file_cache` | off | mmaps a fixed file list at startup. Souin's job here. |
| `filter` | ON stock | The filter-chain plumbing `deflate`/`brotli` need. |
| `headers` | ON stock | Header editing. Several applications require it. |
| `heartbeat` | off | Broadcasts load to a balancer front-end. |
| `heartmonitor` | off | Collects those broadcasts, for `lbmethod_heartbeat`. |
| `http2` | **ON server** | HTTP/2 to clients. +3.4 MiB idle — worth it facing real browsers, wasted between two containers on one host. |
| `ident` | off | RFC1413 lookups. Dead protocol, adds latency to every request. |
| `imagemap` | off | Server-side image maps. |
| `include` | off | SSI. **Deliberately off** — it turns any writable file into a code path. |
| `info` | off | `/server-info` renders your whole configuration. Never on anything reachable. |
| `isapi` | off | Windows ISAPI. Not applicable. |
| `lbmethod_bybusyness` | off | Balancer algorithm: fewest active requests. |
| `lbmethod_byrequests` | **ON server** | A balancer with no algorithm balances nothing; this is the sane default one. |
| `lbmethod_bytraffic` | off | Balancer algorithm: by bytes. |
| `lbmethod_heartbeat` | off | Balancer algorithm driven by `heartmonitor`. |
| `ldap` | off | LDAP connection pool, for `authnz_ldap`. |
| `log_config` | ON stock | `CustomLog`, `LogFormat`. Required. |
| `log_debug` | off | Extra per-request debug hooks. |
| `log_forensic` | off | Logs each request twice, before and after. Worth enabling while chasing a crash. |
| `logio` | ON added | Actual bytes in/out per request, already in this image's `LogFormat` as `%I`/`%O`. |
| `lua` | off | Scripting inside Apache. Execution surface. |
| `macro` | **ON server** | `<Macro>` in configuration — worth having once you are hand-writing more than one vhost. |
| `md` | **ON server** | ACME certificates in Apache, so renewal needs no second container. Pulls in `watchdog`. |
| `mime` | ON stock | Content type from extension. |
| `mime_magic` | ON added | Content type by sniffing when the extension does not say. **The most arguable of the eight** — costs a read of each file's first bytes. Drop it if your content is all known extensions. |
| `mpm_event` | ON stock | The right MPM here: no PHP runs in-process, so there is nothing to serialise. |
| `mpm_prefork` | off | Only if you enable `cgi` or a non-thread-safe in-process module. Unload `mpm_event` first — only one MPM may load. |
| `mpm_worker` | off | Superseded by `event` for this workload. |
| `negotiation` | off | Variant selection (`index.html.en`). Costs a directory scan. |
| `optional_fn_export` | off | API demo. |
| `optional_fn_import` | off | API demo. |
| `optional_hook_export` | off | API demo. |
| `optional_hook_import` | off | API demo. |
| `proxy` | ON added | The proxy core. Useless without a submodule. |
| `proxy_ajp` | off | Tomcat's AJP. Prefer `proxy_http` to a Java container. |
| `proxy_balancer` | **ON server** | More than one backend. Pulls in `slotmem_shm`. |
| `proxy_connect` | off | The `CONNECT` method — makes this a forward proxy. **Never on a public server.** |
| `proxy_express` | off | vhost→backend from a DBM map. Mass hosting. |
| `proxy_fcgi` | ON added | How a `.php` request reaches php-fpm in the sibling container. |
| `proxy_fdpass` | off | Hands the client socket to another process. Very niche. |
| `proxy_ftp` | off | FTP through the proxy. |
| `proxy_hcheck` | off | Health checks for balancer members. |
| `proxy_html` | off | Rewrites links inside proxied HTML; needs `xml2enc`. Usually a sign the backend is misconfigured. |
| `proxy_http` | ON added | `ProxyPass` to an HTTP backend — a Node or Python container. Not needed for php-fpm, which is why it is easy to miss: without it `ProxyPass` parses, Apache starts, and nothing is proxied. |
| `proxy_http2` | off | HTTP/2 to the backend. Needs `http2`. |
| `proxy_scgi` | off | SCGI backends. |
| `proxy_uwsgi` | **ON server** | Python backends that speak uWSGI rather than HTTP. |
| `proxy_wstunnel` | **ON server** | WebSockets. The most common thing to reach for after `proxy_http`, and its absence is a confusing failure rather than a clear one. |
| `ratelimit` | **ON server** | Bandwidth cap per connection. Belongs where requests arrive. |
| `reflector` | off | Echoes the request body back through the filter chain. Testing. |
| `remoteip` | ON added | The client's address instead of the gateway's — without it every log line, rate limit and "last login from" is wrong. |
| `reqtimeout` | ON stock | Slowloris defence. Worth knowing you already have it. |
| `request` | off | Makes the parsed request body available to other modules; some auth setups need it. |
| `rewrite` | ON added | The reason to choose Apache — applications whose URL scheme ships as `.htaccess`. |
| `sed` | off | Edits responses with sed expressions. |
| `session` | off | Apache-managed sessions. The application owns its own. |
| `session_cookie` | off | Cookie store for `session`. |
| `session_crypto` | off | Encrypts `session` data. |
| `session_dbd` | off | SQL store for `session`. |
| `setenvif` | ON stock | Conditional environment variables from request attributes. |
| `slotmem_plain` | off | Non-shared slot memory. `slotmem_shm` is the one you want. |
| `slotmem_shm` | **ON server** | Shared memory for `proxy_balancer`. |
| `socache_dbm` | off | DBM shared-object cache. |
| `socache_memcache` | off | memcached shared-object cache. |
| `socache_redis` | off | Redis shared-object cache. |
| `socache_shmcb` | ON added | The TLS session cache, loaded ahead of `ssl` because it is free and `mod_ssl` is materially worse without it. |
| `speling` | off | Silently corrects URL case and typos. Costs a directory scan per miss and surprises people in production. |
| `ssl` | **ON server** | TLS. The reason the main-server tag exists. |
| `status` | ON stock | `/server-status`. Left loaded because a `<Location>` for it is a reasonable health endpoint; it exposes nothing until you write one. |
| `substitute` | off | Search-and-replace in responses. A debugging tool that becomes permanent. |
| `suexec` | off | Runs CGI as another user. No CGI here. |
| `unique_id` | ON added | A per-request token in `UNIQUE_ID`, so one request can be followed across the gateway's log, this one, and the application's. |
| `unixd` | ON stock | Drops privileges to `User`/`Group`. Required on Unix. |
| `userdir` | off | `/~user/` → home directories. |
| `usertrack` | off | Sets a tracking cookie. A privacy liability, and analytics already does it. |
| `version` | ON stock | `<IfVersion>` in configuration. |
| `vhost_alias` | **ON server** | Hostname → document root: several sites from one container, which a front server does far more often than an origin. |
| `watchdog` | **ON server** | Background-task plumbing; `md` and `heartbeat` require it. |
| `xml2enc` | off | Charset handling for `proxy_html`. |

---

## Two group decisions worth stating once

**Caching — `cache`, `cache_disk`, `cache_socache`, `file_cache`.** Not because Apache's cache
is bad, but because caching in this stack is [Souin](https://github.com/darkweak/souin),
standalone, in front of this container. Two caches on one request path means two TTLs, two
purge mechanisms, and two places to look when a stale page is served.

**Authentication backends — the `auth*`, `ldap`, `dbd`, `session*` and `socache_*` families.**
The application authenticates its own users. What stays loaded (`auth_basic` + `authn_file` +
the `authz_*` set) is exactly enough to put a password on a staging site.

---

## Enabling and disabling

```bash
docker run --rm morsalin1342/apache a2enmod --list       # every module and its state
docker run --rm morsalin1342/apache a2enmod deflate      # try it, throw the container away
```

```dockerfile
FROM morsalin1342/apache
RUN a2enmod ssl socache_shmcb http2 \
 && a2dismod autoindex
```

`a2enmod` runs `httpd -t` after the edit and restores the previous `httpd.conf` if it fails —
so a module with an unmet dependency is a failed build, not a container that will not start.
When it does fail it prints **Apache's own message**, which took a bug to get right: an earlier
version tested with `httpd -t 2>/dev/null` and then re-ran `httpd -t` after rolling back to
show the result, so users saw "does not pass httpd -t" followed immediately by "Syntax OK" and
no reason at all.
