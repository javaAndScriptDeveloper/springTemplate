#!/usr/bin/env bash
# Exercises the .bricks wiring that is not scripts/brick.sh: the Makefile include, help output and the test runner.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bricks/demo/tests" "$tmp/scripts/tests"
cp "$root/Makefile" "$tmp/"
cp "$root/scripts/tests/run.sh" "$tmp/scripts/tests/"
printf '# comment\n\ndemo\n' > "$tmp/.bricks"
cat > "$tmp/bricks/demo/Makefile" <<'EOM'
demo-hello: ## Say hello from the demo brick
	@echo hello-from-demo
EOM
printf '#!/usr/bin/env bash\necho demo-test-ran\n' > "$tmp/bricks/demo/tests/demo.test.sh"
printf '#!/usr/bin/env bash\necho core-test-ran\n' > "$tmp/scripts/tests/core.test.sh"

# A brick listed in .bricks contributes make targets and appears in help.
out="$(make -s -C "$tmp" --no-print-directory demo-hello)"
[[ "$out" == "hello-from-demo" ]] || fail "brick target not included: $out"
make -s -C "$tmp" --no-print-directory help | grep -q 'demo-hello' || fail "brick target missing from help"

# Comments and blank lines in .bricks are ignored; an unlisted brick contributes nothing.
printf '# nothing enabled\n' > "$tmp/.bricks"
if make -s -C "$tmp" --no-print-directory demo-hello >/dev/null 2>&1; then fail "disabled brick still contributes targets"; fi
# The command line can override the list (brick tests rely on this).
out="$(make -s -C "$tmp" --no-print-directory BRICKS=demo demo-hello)"
[[ "$out" == "hello-from-demo" ]] || fail "BRICKS= override ignored"

# Brick overrides (partials of core services) join the docker compose -f list; the Makefile is the one place that builds it.
printf 'services:\n  app:\n    environment:\n      X: "1"\n' > "$tmp/bricks/demo/override.prod.yml"
printf 'services:\n  app:\n    environment:\n      X: "1"\n' > "$tmp/bricks/demo/override.yml"
printf 'demo\n' > "$tmp/.bricks"
out="$(make -s -C "$tmp" --no-print-directory print-prod)"
[[ "$out" == *"-f bricks/demo/override.prod.yml"* ]] || fail "prod override missing from print-prod: $out"
[[ "$out" != *"-f bricks/demo/override.yml"* ]] || fail "local override leaked into print-prod: $out"
out="$(make -s -C "$tmp" --no-print-directory PROD_ENV_FILE=x print-prod)"
[[ "$out" == *"--env-file x"* ]] || fail "PROD_ENV_FILE not honoured: $out"
printf '# nothing enabled\n' > "$tmp/.bricks"
out="$(make -s -C "$tmp" --no-print-directory print-prod)"
[[ "$out" != *override* ]] || fail "override listed with the brick disabled: $out"

# The test runner runs brick tests whether or not the brick is enabled.
out="$(bash "$tmp/scripts/tests/run.sh")"
grep -q 'core-test-ran' <<<"$out" || fail "core test not run"
grep -q 'demo-test-ran' <<<"$out" || fail "brick test not run"
echo "bricks-wiring: all passed"
