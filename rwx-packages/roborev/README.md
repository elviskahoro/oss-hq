# elviskahoro/roborev

Runs roborev (pi agent through the Kilo gateway) on local work against `origin/main`. It fails unless the verdict is `Review Passed`.

The caller passes the `roborev` vault values as parameters (`kilo-*`, `github-token`), because a package cannot read vaults itself.

The caller clones the repo (full depth, `preserve-git-dir: true`) and calls this package with `use: code`. See `.rwx/roborev.yml` for the wrapper.

Parameters: `repository`, `github-token`, `roborev-toml` and `review-guidelines`. The last two apply only when the repo has no `.roborev.toml`.
