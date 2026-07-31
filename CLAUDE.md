# Working agreements

## Git

**Never commit on your own.** Do not run `git commit`, `git push`, `git tag`,
or anything else that writes to history unless I ask for it in that same turn.
Finishing a task, getting a green test run, or updating docs is not a request
to commit — leave the work in the tree and tell me what changed. Ask if you
think a commit is warranted; do not assume.

**A commit you make is mine, not yours.** When I do ask for one, author it with
the repository's configured identity (`user.name` / `user.email`) and nothing
else:

- No `Co-Authored-By: Claude ...` trailer.
- No "Generated with Claude Code" line.
- Do not pass `--author`, and do not set `GIT_AUTHOR_*` or `GIT_COMMITTER_*`.

Write the message in my voice: what changed and why, no AI attribution. The
same goes for pull request titles and bodies.
