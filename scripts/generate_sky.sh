#!/usr/bin/env bash
# Read a JSON object from stdin and emit a copy.bara.sky file on stdout.
#
# Recognized fields (all optional unless noted):
#   path                 Path to an existing .sky file; its contents are
#                        emitted verbatim and all other fields are ignored.
#   raw                  Inline copy.bara.sky content; emitted verbatim and
#                        all other fields are ignored.
#   origin_url           (required when path/raw unset)
#   origin_ref           default: "main"
#   dest_url             (required when path/raw unset)
#   dest_fetch           default: "main"
#   dest_push            default: "main"
#   dest_files_globs     JSON-encoded array string, default: '["**"]'
#   dest_files_excludes  JSON-encoded array string, default: '[]'
#   author               (required when path/raw unset)
#   transformations      JSON-encoded array string of Starlark exprs,
#                        default: '[]'

set -euo pipefail

INPUT_JSON="$(cat)"
export INPUT_JSON

python3 - <<'PY'
import json, os, sys

inp = json.loads(os.environ["INPUT_JSON"])

path = inp.get("path") or ""
raw = inp.get("raw") or ""

if path:
    with open(path) as f:
        sys.stdout.write(f.read())
    sys.exit(0)

if raw:
    sys.stdout.write(raw)
    sys.exit(0)

def starlark_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

def starlark_list(items):
    return "[" + ", ".join(starlark_str(i) for i in items) + "]"

def parse_array(v, default):
    if v is None or v == "":
        return default
    if isinstance(v, list):
        return v
    return json.loads(v)

required = ["origin_url", "dest_url", "author"]
missing = [k for k in required if not inp.get(k)]
if missing:
    sys.stderr.write(f"generate_sky: missing required field(s): {', '.join(missing)}\n")
    sys.exit(2)

origin_url = inp["origin_url"]
origin_ref = inp.get("origin_ref") or "main"
dest_url = inp["dest_url"]
dest_fetch = inp.get("dest_fetch") or "main"
dest_push = inp.get("dest_push") or "main"
author = inp["author"]

globs = parse_array(inp.get("dest_files_globs"), ["**"])
excludes = parse_array(inp.get("dest_files_excludes"), [])
transforms = parse_array(inp.get("transformations"), [])

if transforms:
    joined = ",\n        ".join(transforms)
    transforms_section = f"    transformations = [\n        {joined}\n    ],"
else:
    transforms_section = "    transformations = [],"

config = f"""core.workflow(
    name = "default",
    origin = git.origin(
        url = {starlark_str(origin_url)},
        ref = {starlark_str(origin_ref)},
    ),
    destination = git.destination(
        url = {starlark_str(dest_url)},
        fetch = {starlark_str(dest_fetch)},
        push = {starlark_str(dest_push)},
    ),
    origin_files = glob(include = {starlark_list(globs)}, exclude = {starlark_list(excludes)}),
    destination_files = glob(include = {starlark_list(globs)}, exclude = {starlark_list(excludes)}),
    authoring = authoring.pass_thru({starlark_str(author)}),
    mode = "ITERATIVE",
{transforms_section}
)
"""
sys.stdout.write(config)
PY
