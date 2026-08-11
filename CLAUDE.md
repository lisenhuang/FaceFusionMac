# Working agreements

<!-- AGENTS.md sits next to this file and contains only `@CLAUDE.md`. They are
     two separate files: editing one no longer changes the other. The rules
     themselves live here, not there. -->

## Every code change

**Bump the version, then build.** Both, every time — not just when it feels
significant.

1. **Bump.** Raise `MARKETING_VERSION` in
   `FaceFusionMac.xcodeproj/project.pbxproj`: patch for a fix (`1.0.4` →
   `1.0.5`), minor for a new feature. Raise `CURRENT_PROJECT_VERSION` by one
   alongside it. Each appears **8 times** — once per target per configuration —
   so change every occurrence or the app and the engine disagree about what
   they are.

2. **Build.** Not "it should compile":

   ```sh
   xcodebuild -project FaceFusionMac.xcodeproj -scheme Morphiqo \
              -configuration Release -destination 'generic/platform=macOS' build
   ```

   Use `-scheme`, never `-target`: SPM module maps are only generated for
   scheme builds. `generic/platform=macOS` builds both architectures, which is
   what ships — `arch=arm64` hides Intel-only breakage.

Work that has not been built is not finished, and I do not want to hear it is
done until it has compiled.

Note that a tag build in CI overrides both values from the git tag, so the
number in the project is what local and untagged builds report.

## Things that are load-bearing

- **The target and scheme are `Morphiqo`; the folders and the `.xcodeproj` are
  still `FaceFusionMac`.** `-project FaceFusionMac.xcodeproj -scheme Morphiqo`
  is the correct pairing, not a mistake to tidy up. The app ships as
  `Morphiqo.app` with bundle ID `com.lisenhuang.morphiqo`.
- **`EngineServiceIdentity.name` must equal the engine target's
  `PRODUCT_BUNDLE_IDENTIFIER`** (`com.lisenhuang.morphiqo.Engine`). A mismatch
  fails at runtime when the XPC connection is made, not at build time, so
  nothing catches it for you.
- **Renaming the product breaks the release pipeline in silence.**
  `.github/workflows/release.yml` and `Tools/make-dmg.sh` both refer to the app
  by name — the scheme, the archive path, `Contents/MacOS/<name>`, the DMG
  volume and filename. Change one, grep for the rest.

## The app is published

Morphiqo ships as a DMG from GitHub Releases and people have it installed.
Every change has to be one an existing install can *upgrade into*: the first
launch after an update starts with whatever the previous version left behind,
and "works on a clean install" is not the bar.

- **The model library in the Group Container.** `models.json` is
  content-addressed. Adding an entry is safe and costs an existing user nothing
  until they choose to download it; changing an entry's digest makes the copy
  they already have stale and charges them the download again. The sweep deletes
  whatever the manifest no longer claims, so work out what a rename would
  reclaim before renaming anything.
- **Derived caches keyed by what you are changing.** The Core ML compile cache is
  keyed by model file name — a change that renames model files silently spends
  the whole compile cost on the next launch.
- **Anything persisted or decoded.** Remembered locations, the purchase state,
  saved settings. The `Codable` types in `Shared/` are the sharp edge: a new
  field needs a default so an older blob still decodes.
- **The XPC contract is the one thing that is *not* a compatibility problem.**
  The app and the engine ship in the same bundle and are always the same build,
  so changing `FaceFusionEngineProtocol` or the shapes it carries is free — but
  the selector and its `setClasses` allow-list in `makeEngineInterface` must
  change together, and a mismatch fails at runtime rather than at build time.

If a change genuinely cannot be made upgrade-safe, say so and describe the
migration it needs — do not ship something that only holds together on a Mac
that has never run the app before.

## Git

**Never commit on your own.** Do not run `git commit`, `git push`, `git tag`,
or anything else that writes to history unless I ask for it in that same turn.
Finishing a task, getting a green test run, or updating docs is not a request
to commit — leave the work in the tree and tell me what changed. Ask if you
think a commit is warranted; do not assume.

### Work lands on `main`

When I do ask for a commit, the change belongs on `main` by the end of it:
branch, commit, merge back with `--no-ff`, and push `main` to the remote. Do not
leave finished work parked on a feature branch waiting for a pull request unless
I ask for one — a branch nobody merges is a change nobody has. Push the branch
too, so the history of how it landed survives. `main` is what the release
workflow builds, so this is also the first real compile of anything written
without Xcode to hand.

### The commit is mine, and so is the name on it

When I ask you to commit, **the author and the committer are me, not you.** Take
the identity from the repository's own configuration — `git config user.name`
and `git config user.email`, currently `Ethan <lisen8018@gmail.com>` — and do
nothing that changes it:

- **Do not pass `--author`.** Do not set `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`,
  `GIT_COMMITTER_NAME` or `GIT_COMMITTER_EMAIL`.
- **Never put an assistant, bot or tool address in either field.**
  `noreply@anthropic.com`, `claude@…`, `bot@…`, `*@users.noreply.github.com`
  and anything similar are all wrong, in the author field and the committer
  field alike.
- **No `Co-Authored-By:` trailer for an AI**, and no second author of any kind.
- **No "Generated with Claude Code", "🤖", or any tool named anywhere** in the
  subject, body or trailers.

If `user.name` or `user.email` is unset, stop and ask me. Do not guess, and do
not let git fall back to the `user@hostname` identity it derives on its own —
a commit authored by `easonsmith@Mac.local` is as wrong as one authored by a
model.

After committing, check it actually landed as me:

```sh
git log -1 --format='%an <%ae> | %cn <%ce>'
```

This holds however the commit is made — the CLI, the VS Code Source Control
panel, or a generated message — and it holds for pull request titles and bodies,
issue comments and release notes too. Write the message in my voice: what
changed and why, no AI attribution.

`.vscode/git-commit-instructions.md` is the standard this repository holds
commit messages to; follow it when you write one, so a message you draft and one
the editor generates read the same.
