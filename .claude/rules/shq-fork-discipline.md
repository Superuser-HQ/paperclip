# Fork Discipline

SHQ-specific changes must be isolated from upstream Paperclip code to minimise rebase conflicts:

- New routes in their own files under `server/src/routes/`
- New adapters in their own packages under `packages/adapters/`
- When you must modify an upstream file, add an entry to `doc/shq/UPSTREAM-MODIFICATIONS.md` with the file path, what was changed, and why — this makes rebases tractable
