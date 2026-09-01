# Module prerequisites and conflicts — the one place either is written down.
#
# Sourced by a2enmod and a2dismod. It is a shared file rather than a copy in
# each because the two must never disagree: a2enmod pulling a prerequisite in
# and a2dismod not knowing it is load-bearing is exactly how you get a container
# that starts today and refuses to start after an unrelated change.
#
# # Where this list comes from
#
# Measured, not copied from Apache's documentation. Every module in the image
# was enabled on its own, config-tested, and then actually started in the
# foreground; 16 of them either failed or logged an error. Apache reports the
# failure three different ways depending on the module, which is why guessing
# from the docs is worse than checking:
#
#   httpd -t fails    mod_dav_fs.so: undefined symbol: dav_do_find_liveprop
#                     — the parent module exports the symbol, so the child
#                       cannot even be loaded
#   starts, broken    AH01177: Failed to lookup provider 'shm' for 'slotmem':
#                       is mod_slotmem_shm loaded??
#                     — the config test passes and Apache comes up, and the
#                       feature silently does not work
#   warns only        AH01873: Init: Session Cache is not configured
#
# The middle case is the reason this file exists. `httpd -t` cannot catch it,
# so without a table there is nothing to catch it at all.
#
# # Prerequisites hide behind prerequisites
#
# The table was built by sweeping, fixing, and sweeping again — and the second
# sweep found two entries the first could not have. mod_auth_form reports the
# missing mod_session and stops there; satisfy that and it reports a missing
# mod_request it had never mentioned. mod_heartmonitor does the same with
# mod_watchdog and then mod_slotmem_shm. Apache reports the first missing
# prerequisite, not the set, so one pass over the modules can only ever find one
# layer. Re-run the sweep after changing this file.

# Prerequisites, printed space-separated on stdout. Empty for most modules.
mod_deps() {
    case "$1" in
        # Config test fails without these — the child needs symbols the parent exports.
        cache_disk|cache_socache)   echo cache ;;
        dav_fs|dav_lock)            echo dav ;;
        session_cookie|session_crypto) echo session ;;
        session_dbd)                echo session dbd ;;
        heartbeat)                  echo watchdog ;;

        # Config test PASSES and the feature is silently dead without these.
        auth_form)                  echo session request ;;
        authnz_ldap)                echo ldap ;;
        heartmonitor)               echo watchdog slotmem_shm ;;
        proxy_balancer)             echo proxy slotmem_shm ;;
        proxy_hcheck)               echo proxy watchdog ;;
        md)                         echo watchdog ;;

        # mod_proxy is the core; every proxy_* is a submodule of it and does
        # nothing at all on its own.
        proxy_ajp|proxy_connect|proxy_express|proxy_fcgi|proxy_fdpass) echo proxy ;;
        proxy_ftp|proxy_http|proxy_scgi|proxy_uwsgi|proxy_wstunnel)    echo proxy ;;
        proxy_http2)                echo proxy http2 ;;
        proxy_html)                 echo proxy xml2enc ;;

        # Balancer algorithms need something to balance.
        lbmethod_bybusyness|lbmethod_byrequests|lbmethod_bytraffic)
                                    echo proxy proxy_balancer slotmem_shm ;;
        lbmethod_heartbeat)         echo proxy proxy_balancer slotmem_shm heartmonitor ;;

        # Compression rides the filter chain.
        brotli|deflate)             echo filter ;;

        # Not a hard requirement — mod_ssl loads and serves without it — but
        # without a session cache every connection pays a full handshake, and
        # Apache says so at every single start (AH01873). Pulling it in, plus
        # the SSLSessionCache line in conf/extra/module-defaults.conf, is what
        # makes `a2enmod ssl` produce a clean start instead of homework.
        ssl)                        echo socache_shmcb ;;

        *) : ;;
    esac
}

# Modules that cannot be loaded alongside "$1". Only one MPM may ever load.
mod_conflicts() {
    case "$1" in
        mpm_event)   echo mpm_prefork mpm_worker ;;
        mpm_prefork) echo mpm_event mpm_worker ;;
        mpm_worker)  echo mpm_event mpm_prefork ;;
        *) : ;;
    esac
}

# Everything that lists "$1" as a prerequisite, for a2dismod's reverse check.
mod_dependents() {
    for f in "$MODDIR"/mod_*.so; do
        [ -f "$f" ] || continue
        c="$(basename "$f" .so)"; c="${c#mod_}"
        for d in $(mod_deps "$c"); do
            [ "$d" = "$1" ] && echo "$c"
        done
    done
}
