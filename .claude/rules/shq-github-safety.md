# GitHub Safety

This repo is a **private fork** of a public upstream repo. Leaking SHQ content to upstream is a serious confidentiality breach.

## Mandatory

- **Never create PRs on `paperclipai/paperclip`** (upstream). All PRs go to `Superuser-HQ/paperclip`.
- **Never push branches to upstream.** Only push to `origin` (`Superuser-HQ/paperclip`).
- `gh repo set-default` is configured to `Superuser-HQ/paperclip` — do not override it.
- When using `gh pr create`, do not pass `--repo` targeting upstream.
- Closing a leaked PR does **not** remove it from public view — contact upstream admins to delete.

## Verification

Before any `gh pr create` or `gh pr` command, confirm the target:

```sh
gh repo set-default --view
# Must show: Superuser-HQ/paperclip
```
