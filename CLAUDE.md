# Working agreements

## Every code change

**Bump the version, then build.** Both, every time — not just when it feels
significant.

1. **Bump.** Raise `MARKETING_VERSION` in
   `FaceFusionMac.xcodeproj/project.pbxproj`: patch for a fix (`1.0.3` →
   `1.0.4`), minor for a new feature. Raise `CURRENT_PROJECT_VERSION` by one
   alongside it. Each appears **8 times** — once per target per configuration —
   so change every occurrence or the app and the engine disagree about what
   they are.

2. **Build.** Not "it should compile":

   ```sh
   xcodebuild -project FaceFusionMac.xcodeproj -scheme FaceFusionMac \
              -configuration Release -destination 'generic/platform=macOS' build
   ```

   Use `-scheme`, never `-target`: SPM module maps are only generated for
   scheme builds. `generic/platform=macOS` builds both architectures, which is
   what ships — `arch=arm64` hides Intel-only breakage.

Work that has not been built is not finished, and I do not want to hear it is
done until it has compiled.

Note that a tag build in CI overrides both values from the git tag, so the
number in the project is what local and untagged builds report.

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
