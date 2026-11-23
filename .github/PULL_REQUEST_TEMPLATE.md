## Description
<!-- What does this PR do, and why? -->

## Type of change
- [ ] Module added to a default set
- [ ] Version upgrade (`ARG HTTPD_VERSION` / `ARG DEBIAN_RELEASE`)
- [ ] Configuration change (`conf/`)
- [ ] Change to the a2* scripts (`scripts/`)
- [ ] Bug fix
- [ ] Documentation update

## Testing

Both targets, because they are not the same image:

```bash
docker build --target origin -t test-apache:origin .
docker build              -t test-apache:latest .

for t in origin latest; do
  docker run --rm test-apache:$t httpd -M | grep -c '_module'
  docker run --rm test-apache:$t sh -c 'timeout 3 httpd -DFOREGROUND 2>&1 | grep warn'
done
```

<!-- Paste the output. Module counts and "no warnings" are the two things reviewers check. -->

## Checklist
- [ ] Both targets build, start, and serve
- [ ] Neither logs a warning at startup
- [ ] Module counts are stated in the PR, and any change to them is intentional
- [ ] MODULES.md updated if a module's state changed — it documents all 130
- [ ] `README.dockerhub*.md` regenerated if `README.md` changed (see CONTRIBUTING.md)
- [ ] If `scripts/` changed: the full module sweep was re-run (enable each alone,
      config-test, start) — it is the only thing that catches a module which passes
      `httpd -t` and is broken at runtime
- [ ] Claims about memory or behaviour are measured, not asserted
- [ ] No unrelated changes are included
