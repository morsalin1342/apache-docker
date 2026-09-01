---
name: Bug report
about: Report an issue with the Apache Docker image
title: '[Bug] '
labels: bug
assignees: ''
---

**Image tag(s) affected**
<!-- e.g. morsalin1342/apache:2.4.68 or morsalin1342/apache:2.4.68-origin.
     The two tags load different module sets, so please say which. -->

**Describe the bug**
<!-- A clear description of what's wrong -->

**Steps to reproduce**
1.
2.
3.

**Expected behavior**
<!-- What should have happened -->

**Environment**
- Docker version:
- Host OS:

**Additional context**
<!--
Useful output, with any secrets redacted:

    docker run --rm <tag> httpd -M          # modules actually loaded
    docker run --rm <tag> a2enmod --list    # and their prerequisites
    docker logs <container>                 # startup log

If Apache will not start, the startup log is usually the one with the answer —
`httpd -t` only parses the configuration and does not run a module's own
initialisation, so it can say "Syntax OK" for a config that cannot start.

If you mounted your own configuration, please include it.
-->
