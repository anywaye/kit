# CI backends

**A project writes a pipeline, kit runs it.** The pipeline is the project's
own — its gate, its build, its deploy — and it lives in the project at
`ci/pipeline.sh`. The backend is how that pipeline gets triggered and with
what environment, and it is chosen once, in `ci/backend`:

```
instabox
```

| backend | what it is | when it is the right one |
| --- | --- | --- |
| `github-actions` | GitHub Actions, via `.github/workflows/` calling kit's reusable workflows | the default; free minutes exist |
| `instabox` | a sandbox that polls the repo and runs the pipeline on new master | Actions minutes are gone, the run needs to reach a private network, or the machine matters |

## The contract

A project's `ci/pipeline.sh` must:

1. be executable (`chmod +x`), run from anywhere, and be idempotent — the
   backend runs it repeatedly;
2. read its inputs from the **environment the backend provides**, never from
   the backend's shape. The variables every backend provides:

   | variable | meaning |
   | --- | --- |
   | `WORKSPACE` | the directory holding `cafaye/<name>` checkouts |
   | `GH_TOKEN` | a token that can read the project's private sources |
   | `CI` | `1`, so a pipeline can skip interactivity |

3. anything else — a deploy host, a key, a bucket — the project declares and
   the backend materializes from its own secret store. The instabox backend
   reads `$HOME/.ci-env` (one `KEY=value` per line, written by provision);
   GitHub Actions reads repository secrets. A pipeline that reads
   `DEPLOY_HOST` works on both without knowing which.

## Switching backends

Change the one line in `ci/backend` and, for `github-actions`, ensure the
workflow files exist. The pipeline is unchanged; that is the point. A project
that wants a third backend (a self-hosted runner, a cron on a box) adds
`kit/backends/<name>/` and a line to the table above, and every other
project's pipeline keeps working.

## What kit owns vs what the project owns

| kit | the project |
| --- | --- |
| the poller, the provisioner, the backends' plumbing | `ci/backend` and `ci/pipeline.sh` |
| the secret-store mapping per backend | which secrets it needs, declared in its README |
| the switch, in one file | nothing about the runner's shape |
