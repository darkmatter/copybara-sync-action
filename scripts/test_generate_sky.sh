#!/usr/bin/env bash
# End-to-end test for .github/scripts/generate_sky.sh
#
# The test:
#   1. Creates two local git repos (src with commits, dst as a bare repo).
#   2. Writes a hand-authored copy.bara.sky referencing file:// URLs.
#   3. Runs copybara against that reference and verifies the dst repo
#      received the expected files (and excluded ones stayed out).
#   4. Builds a JSON object with the equivalent workflow inputs (as GitHub
#      would pass them -- strings, with JSON arrays as JSON-encoded strings).
#   5. Pipes that JSON into generate_sky.sh and asserts the output is
#      byte-identical to the hand-authored reference. If it matches, the
#      generator produces a config known to sync correctly.
#   6. Also exercises the `path` and `raw` pass-through options.
#
# Copybara invocation prefers a `copybara` binary on PATH, otherwise
# `java -jar "$COPYBARA_JAR"` (set COPYBARA_JAR to a prebuilt
# copybara_deploy.jar). Set SKIP_COPYBARA=1 to skip the copybara run (the
# generator comparison still runs).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$SCRIPT_DIR/generate_sky.sh"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

SRC="$TMPDIR/src"
DST="$TMPDIR/dst.git"
WORK="$TMPDIR/work"
mkdir -p "$WORK"

echo "==> Creating source repo at $SRC"
git init -q -b main "$SRC"
git -C "$SRC" config user.email test@test.local
git -C "$SRC" config user.name "Test"
git -C "$SRC" config commit.gpgsign false
git -C "$SRC" config tag.gpgsign false
echo "hello world" > "$SRC/README.md"
mkdir -p "$SRC/src" "$SRC/internal"
echo "public code" > "$SRC/src/main.txt"
echo "secret" > "$SRC/internal/secret.txt"
git -C "$SRC" add -A
git -C "$SRC" commit -q -m "initial commit"

echo "==> Creating bare destination repo at $DST"
git init -q --bare -b main "$DST"

# Copybara requires the config filename to be exactly copy.bara.sky.
REF="$WORK/copy.bara.sky"
cat > "$REF" <<EOF
core.workflow(
    name = "default",
    origin = git.origin(
        url = "file://$SRC",
        ref = "main",
    ),
    destination = git.destination(
        url = "file://$DST",
        fetch = "main",
        push = "main",
    ),
    origin_files = glob(include = ["**"], exclude = ["internal/**"]),
    destination_files = glob(include = ["**"], exclude = ["internal/**"]),
    authoring = authoring.pass_thru("Copybara Test <bot@test.local>"),
    mode = "ITERATIVE",
    transformations = [],
)
EOF

# Write a minimal gitconfig for copybara to use inside the container.
cat > "$WORK/.gitconfig" <<EOF
[user]
  email = copybara@test.local
  name = Copybara
EOF

run_copybara_in_dir() {
  local dir="$1"
  if command -v copybara >/dev/null 2>&1; then
    (cd "$dir" && HOME="$dir" copybara migrate copy.bara.sky default --init-history --force)
  elif [ -n "${COPYBARA_JAR:-}" ] && [ -f "$COPYBARA_JAR" ]; then
    (cd "$dir" && HOME="$dir" java -jar "$COPYBARA_JAR" migrate copy.bara.sky default --init-history --force)
  else
    echo "ERROR: no way to run copybara found." >&2
    echo "       Install a 'copybara' binary on PATH, or set COPYBARA_JAR to a" >&2
    echo "       prebuilt copybara_deploy.jar, or set SKIP_COPYBARA=1 to skip." >&2
    return 1
  fi
}

if [ "${SKIP_COPYBARA:-0}" = "1" ]; then
  echo "==> SKIP_COPYBARA=1 set; skipping copybara run"
else
  echo "==> Running copybara against reference config"
  run_copybara_in_dir "$WORK"

  echo "==> Verifying destination repo contents"
  VERIFY="$TMPDIR/verify"
  git clone -q "$DST" "$VERIFY"
  [ -f "$VERIFY/README.md" ]        || { echo "FAIL: README.md missing in dest"; exit 1; }
  [ -f "$VERIFY/src/main.txt" ]     || { echo "FAIL: src/main.txt missing in dest"; exit 1; }
  [ ! -e "$VERIFY/internal/secret.txt" ] || { echo "FAIL: internal/secret.txt leaked to dest"; exit 1; }
  echo "OK: copybara sync produced expected files"
fi

echo "==> Building equivalent JSON inputs"
INPUT_JSON="$TMPDIR/input.json"
SRC_URL="file://$SRC" DST_URL="file://$DST" python3 - > "$INPUT_JSON" <<'PY'
import json, os, sys
payload = {
    "origin_url": os.environ["SRC_URL"],
    "origin_ref": "main",
    "dest_url": os.environ["DST_URL"],
    "dest_fetch": "main",
    "dest_push": "main",
    "dest_files_globs": json.dumps(["**"]),
    "dest_files_excludes": json.dumps(["internal/**"]),
    "author": "Copybara Test <bot@test.local>",
    "transformations": json.dumps([]),
}
json.dump(payload, sys.stdout)
PY

echo "==> Running generate_sky.sh and comparing to reference"
GEN_OUT="$TMPDIR/generated.sky"
"$GEN" < "$INPUT_JSON" > "$GEN_OUT"

if diff -u "$REF" "$GEN_OUT"; then
  echo "OK: generated config is byte-identical to reference"
else
  echo "FAIL: generated config differs from reference" >&2
  exit 1
fi

echo "==> Verifying path= pass-through"
PATH_INPUT="$TMPDIR/path_input.json"
REF_PATH="$REF" python3 -c 'import json,os,sys; json.dump({"path": os.environ["REF_PATH"]}, sys.stdout)' > "$PATH_INPUT"
PATH_OUT="$TMPDIR/path_out.sky"
"$GEN" < "$PATH_INPUT" > "$PATH_OUT"
if diff -u "$REF" "$PATH_OUT"; then
  echo "OK: path option emits referenced file verbatim"
else
  echo "FAIL: path option output differs from referenced file" >&2
  exit 1
fi

echo "==> Verifying raw= pass-through"
RAW_INPUT="$TMPDIR/raw_input.json"
REF_PATH="$REF" python3 -c 'import json,os,sys; json.dump({"raw": open(os.environ["REF_PATH"]).read()}, sys.stdout)' > "$RAW_INPUT"
RAW_OUT="$TMPDIR/raw_out.sky"
"$GEN" < "$RAW_INPUT" > "$RAW_OUT"
if diff -u "$REF" "$RAW_OUT"; then
  echo "OK: raw option emits input verbatim"
else
  echo "FAIL: raw option output differs from input" >&2
  exit 1
fi

echo "==> Verifying path= takes precedence over other fields"
PREC_INPUT="$TMPDIR/prec_input.json"
REF_PATH="$REF" python3 - > "$PREC_INPUT" <<'PY'
import json, os, sys
json.dump({
    "path": os.environ["REF_PATH"],
    "origin_url": "ignored",
    "dest_url": "ignored",
    "author": "ignored",
}, sys.stdout)
PY
PREC_OUT="$TMPDIR/prec_out.sky"
"$GEN" < "$PREC_INPUT" > "$PREC_OUT"
diff -u "$REF" "$PREC_OUT" >/dev/null || { echo "FAIL: path did not override other fields"; exit 1; }
echo "OK: path takes precedence"

echo ""
echo "ALL TESTS PASSED"
