# copybara-sync-action

A GitHub Action that syncs one git repository into another using
[Google Copybara](https://github.com/google/copybara). Unlike most existing
copybara actions, this one does **not** depend on Docker — it builds copybara
from source with Bazel (cached across runs) and invokes it via `java -jar`.

## Usage

```yaml
jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: darkmatter/copybara-sync-action@v1
        with:
          origin_url: https://github.com/your-org/internal
          dest_url:   https://github.com/your-org/public
          author:     "Sync Bot <bot@example.com>"
          github_token: ${{ secrets.SYNC_TOKEN }}
```

## Matrix usage

To sync several repository pairs in one workflow, put the action call inside
a matrix job:

```yaml
jobs:
  sync:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        include:
          - origin_url: https://github.com/your-org/a
            dest_url:   https://github.com/your-org/a-public
            dest_files_excludes: '["internal/**"]'
            transformations: '[]'
          - origin_url: https://github.com/your-org/b
            dest_url:   https://github.com/your-org/b-public
            dest_files_globs: '["src/**", "README.md"]'
            transformations: '["core.move(\"src/\", \"lib/\")"]'
    steps:
      - uses: darkmatter/copybara-sync-action@v1
        with:
          origin_url:          ${{ matrix.origin_url }}
          dest_url:            ${{ matrix.dest_url }}
          dest_files_globs:    ${{ matrix.dest_files_globs || '["**"]' }}
          dest_files_excludes: ${{ matrix.dest_files_excludes || '[]' }}
          transformations:     ${{ matrix.transformations || '[]' }}
          author:              "Sync Bot <bot@example.com>"
          github_token:        ${{ secrets.SYNC_TOKEN }}
```

## Inputs

All inputs are optional unless otherwise noted; defaults shown below.

| Input | Default | Notes |
|---|---|---|
| `path` | `""` | Path to a `copy.bara.sky` file in the caller's repo. If set, all generation inputs below are ignored. |
| `raw` | `""` | Inlined `copy.bara.sky` contents. If set, all generation inputs below are ignored. (`path` takes precedence over `raw`.) |
| `origin_url` | `""` | Origin git repository URL. Required when `path` and `raw` are unset. |
| `origin_ref` | `"main"` | Origin ref/branch. |
| `dest_url` | `""` | Destination git repository URL. Required when `path` and `raw` are unset. |
| `dest_fetch` | `"main"` | Destination ref to fetch. |
| `dest_push` | `"main"` | Destination ref to push. |
| `dest_files_globs` | `'["**"]'` | JSON-encoded array. Applied to both `origin_files` and `destination_files`. |
| `dest_files_excludes` | `'[]'` | JSON-encoded array. Applied to both `origin_files` and `destination_files`. |
| `author` | `""` | `"Name <email>"`. Required when `path` and `raw` are unset. Also used to set git `user.name` / `user.email` for the destination commit. |
| `transformations` | `'[]'` | JSON array of raw Starlark transformation expressions, e.g. `'["core.move(\"src/\", \"lib/\")"]'`. |
| `version` | `"master"` | A `google/copybara` git ref (branch, tag, or SHA). Cached `copybara_deploy.jar` is keyed on the resolved SHA. |
| `github_token` | `""` | A GitHub token with write access to the destination. Configured for HTTPS pushes. |
| `ssh_key` | `""` | An SSH private key with write access to the destination. Configured at `~/.ssh/id_rsa`. |

## Generated config

When neither `path` nor `raw` is set, the action emits:

```python
core.workflow(
    name = "default",
    origin = git.origin(
        url = "<origin_url>",
        ref = "<origin_ref>",
    ),
    destination = git.destination(
        url = "<dest_url>",
        fetch = "<dest_fetch>",
        push = "<dest_push>",
    ),
    origin_files      = glob(include = <dest_files_globs>, exclude = <dest_files_excludes>),
    destination_files = glob(include = <dest_files_globs>, exclude = <dest_files_excludes>),
    authoring = authoring.pass_thru("<author>"),
    mode = "ITERATIVE",
    transformations = [
        <transformations...>
    ],
)
```

For anything more complex (multiple workflows, custom origin/destination,
hooks), use `path` to point at a hand-authored `copy.bara.sky`.

## Caching and the `version` input

Google does not publish stable copybara releases — `master` is the canonical
ref. The action resolves the value of `version` to a SHA via
`git ls-remote https://github.com/google/copybara`, keys the cache on that
SHA, and only rebuilds when the SHA changes.

A cold-cache build takes roughly 5–10 minutes on a `ubuntu-latest` runner.
Cached runs skip the build entirely.

To pin to a known-good copybara revision, pass an explicit SHA:

```yaml
- uses: darkmatter/copybara-sync-action@v1
  with:
    version: a1b2c3d4...
```

## Authentication

For HTTPS pushes, pass a token via `github_token`. The action writes
`https://x-access-token:<token>@github.com` to `~/.git-credentials` and
configures git's `store` credential helper.

For SSH, pass the private key via `ssh_key`. It is written to
`~/.ssh/id_rsa` and `github.com` is added to `~/.ssh/known_hosts`.

## License

Apache-2.0.
