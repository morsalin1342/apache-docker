---
name: Feature request
about: Request a module in the default set, or another change
title: '[Feature] '
labels: enhancement
assignees: ''
---

**Request type**
<!-- Module in the default set / configuration change / other -->

**If it is a module: does enabling it at runtime already solve your problem?**
<!--
    docker run --rm morsalin1342/apache a2enmod --list      # is it already on?
    docker run --rm morsalin1342/apache a2enmod <name>      # does this do the job?

This image ships all 130 of Apache's modules and loads a chosen subset, so
a2enmod works with no rebuild. If that is enough, you may not need a change here.
-->

**Which tag, and why that one**
<!-- `latest` (Apache is the main server) or `-origin` (behind a reverse proxy).
     They load different sets on purpose. -->

**What breaks without it**
<!-- Concretely. "ProxyPass silently does nothing without proxy_http" is a reason;
     "it might be useful" is not. -->

**What it costs**
<!--
Please measure — every number in MODULES.md was produced this way:

    docker run -d --name m morsalin1342/apache sh -c 'a2enmod <name> && httpd-foreground'
    sleep 3 && docker stats --no-stream m && docker logs m | grep warn

A module that is free is an easy yes. mod_http2 costs +3.4 MiB idle, which is
why it is in one tag and not the other.
-->

**Additional context**
<!-- MODULES.md gives a verdict for all 130 modules. If you disagree with one,
     that is the argument to engage with. -->
