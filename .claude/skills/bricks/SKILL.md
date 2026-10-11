---
name: bricks
description: Add, remove, operate or author a brick (optional infrastructure under bricks/). Use when the user wants MinIO, Grafana, backups or another component, asks what bricks exist, or wants a new component packaged so it can be added with one command.
---

# Bricks

- List: `make bricks`. Enable: `make add BRICK=<name>`. Disable: `make remove BRICK=<name>`. Enabled list: `.bricks`.
- After add or remove: `make build && make test-scripts`; commit the whole diff as one `feat(<name>)` / `chore(<name>)`.
- Before touching a brick's files or operating it in prod: read `bricks/<name>/README.md` (it is the runbook).
- Before writing a new brick: read `bricks/README.md` (anatomy, rules, checklist). Keep it self-contained; test the
  round trip; add it to the CI matrix.
- What add does, in order: compose includes → env blocks → Java/resources (`__PKG__` → service package) → skill →
  `.bricks` → lockfile → Spotless. `scripts/brick.sh` is the source of truth.
