# elviskahoro/pullfrog

Reviews a pull request with Pullfrog through the Kilo gateway. It fails unless the `{approve, summary}` verdict approves, and it posts nothing on the PR.

The caller passes the `roborev` vault values as parameters (`kilo-*`, `github-token`), because a package cannot read vaults itself.

The caller owns the trigger, the `pullfrog-approval` status check, the same-repo `if:` and the concurrency pools. See `.rwx/pullfrog.yml`.

Parameters: `repository`, `pr` and `review-guidelines`.
