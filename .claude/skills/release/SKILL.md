---
name: release
description: How versions, commits and deploys work in this repository — conventional commit format, what bumps major/minor/patch, how to see the next version, how to roll back. Use when writing a commit message, when the user asks what version a change will produce, how to force a major release, or how to roll production back.
---

# Releases

Every push to `main` is a release. CI computes the version from commit subjects since the last `v*` tag
(`scripts/next-version.sh`), tags `vX.Y.Z`, publishes `ghcr.io/<owner>/<repo>:{latest,X.Y.Z,X.Y,sha-…}`, writes a
GitHub Release with generated notes, and waits until every replica serves the new revision (`/version`).
Watchtower on the VPS pulls `latest` within a minute. Push to live: about 5–6 minutes.

## Commit subjects (enforced by `.githooks/commit-msg` and CI)

```
<type>(<optional-scope>)!: <imperative summary, ≤72 chars>
```

| type | bump | use for |
|---|---|---|
| `feat` | minor | new behaviour visible to users or operators |
| `fix`, `perf` | patch | bug fixes, performance |
| `refactor`, `docs`, `test`, `build`, `ci`, `chore`, `style`, `revert` | patch | everything else |
| any type with `!` (or a `BREAKING CHANGE:` footer) | **major** | only when the user explicitly calls the change breaking or asks for a major |

Scope is lowercase (`feat(api): …`). Body explains *why*. Never mark a commit `!` on your own initiative.

- Next version without pushing: `make release-name`.
- The first release of a fresh project is `v0.1.0`; a `!` promotes it to `v1.0.0`.

## Rollback (on the VPS)

```bash
make prod-rollback TAG=1.4.1      # pins APP_IMAGE_TAG, recreates app, stops Watchtower
```
Rolling the image back does not roll the schema back: Liquibase changesets must stay compatible with the previous
release (expand/contract). See `docs/deployment.md`. Resume auto-deploys afterwards with the command the target
prints.
