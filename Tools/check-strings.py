#!/usr/bin/env python3
"""Keep Localizable.xcstrings in step with the code, from the terminal.

The problem this exists for: opening the project in Xcode and pressing Run
rewrites `Localizable.xcstrings` in the *source tree*, and the resulting git
diff has nothing to do with anything you just did. It looks like Xcode being
untidy. It is not — it is Xcode reporting that the catalog and the code
disagree, which is worth knowing and is only annoying because of when and how
it says so.

Two kinds of disagreement, and they are not equally serious:

  MISSING   a string is in the code and not in the catalog. Xcode will add it,
            untranslated, and until somebody translates it the app shows
            English to every Japanese, Korean and Chinese reader. This is a
            bug, and the only reason it is invisible is that an untranslated
            string still renders.

  DEAD      an entry is in the catalog and no longer in the code. Xcode marks
            it `"extractionState": "stale"` rather than deleting it, because it
            cannot know whether you are mid-refactor. That mark is the diff
            that keeps appearing.

Xcode only writes the catalog when SWIFT_EMIT_LOC_STRINGS is on, and in this
project it is deliberately off — that is what stops the surprise diffs. The
setting is forced back on for this tool's own build, into a DerivedData path of
its own, so the safety net is still available on demand without the IDE ever
touching the file.

The key list here is the compiler's own, not a guess. Building with
SWIFT_EMIT_LOC_STRINGS=YES emits a .stringsdata file per source file into
DerivedData, holding exactly the keys the extractor found. Reading those is the
only way to get this right: a regex over the source cannot tell
`Text("swap")` from the word "swap" in a comment, and a scan that tried it
missed eight dead entries in this very catalog — `swap`, `match` and `paste`
all appear as substrings of ordinary identifiers.

    Tools/check-strings.py           report drift, exit 1 if any
    Tools/check-strings.py --fix     delete dead entries, clear stale marks

Edits are textual. The file is rewritten by Xcode with its own pretty-printer
and ICU-collated key order, neither of which round-trips through Python's json
module, so entries are excised from the source text and everything untouched
stays byte-identical.
"""

import argparse
import json
import os
import plistlib
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = "FaceFusionMac"
CATALOG = os.path.join(HERE, "FaceFusionMac", "Localizable.xcstrings")
SOURCE_ROOT = os.path.join(HERE, "FaceFusionMac")
DESTINATION = ["-configuration", "Release", "-destination", "generic/platform=macOS"]

# One top-level entry: four spaces, a JSON string, " : {". Anchored to the line
# start so nested keys at deeper indents cannot match.
ENTRY = re.compile(r'^    "((?:[^"\\]|\\.)*)" : \{', re.M)


def fail(message):
    print("error: " + message, file=sys.stderr)
    sys.exit(2)


# --------------------------------------------------------------- the catalog --

def entries(text):
    """(key, start, end) for every top-level entry, end exclusive of any comma.

    The key is JSON-decoded, so it matches what `json.loads` produces for the
    same file: a literal containing \\n is two characters in the file and one
    in the parsed object, and comparing the two forms silently treats a live
    string as dead.
    """
    found = []
    for match in ENTRY.finditer(text):
        depth, i = 0, match.end() - 1
        while True:
            char = text[i]
            if char == '"':                       # skip a string literal whole
                i += 1
                while text[i] != '"':
                    i += 2 if text[i] == "\\" else 1
            elif char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        found.append((json.loads('"' + match.group(1) + '"'), match.start(), i + 1))
    return found


def excise(text, start, end):
    """Remove one entry along with whichever comma joined it to its neighbours.

    A trailing comma belongs to the entry being removed. The last entry has
    none, so the comma that has to go is the one *before* it — miss that and
    the file ends `},\n  }`, which is not JSON.
    """
    if text[end] == ",":
        after = end + 1
        while text[after] in " \n":
            after += 1
        return text[:start] + text[after:]
    return text[:text.rfind(",", 0, start)] + text[end:]


# ------------------------------------------------------------- the extractor --

def newest_swift_mtime():
    newest = 0.0
    for root, _, files in os.walk(SOURCE_ROOT):
        for name in files:
            if name.endswith(".swift"):
                newest = max(newest, os.path.getmtime(os.path.join(root, name)))
    return newest


def source_basenames():
    """Every Swift file the app target could contribute strings from."""
    names = {}
    for root, dirs, files in os.walk(HERE):
        dirs[:] = [d for d in dirs
                   if not d.startswith(".") and d != "build"
                   and not d.endswith("Tests") and not d.endswith("UITests")]
        for name in files:
            if name.endswith(".swift"):
                names[name[:-6]] = os.path.join(root, name)
    return names


def extracted_keys():
    """Every key the compiler found, from a build made for this purpose.

    Two things make a naive read of DerivedData wrong, and both were observed
    here before this was written:

    A .stringsdata file outlives the source file it came from. Deleting
    EngineBenchmark.swift left its extracted strings sitting in DerivedData,
    so every string that file owned still looked live. Anything whose matching
    .swift no longer exists is therefore ignored.

    A DerivedData directory can hold a partial build. Reading one left 49 live
    Mac strings looking dead. So the source files are counted, and a build that
    did not produce data for nearly all of them is refused rather than reported
    on.
    """
    sources = source_basenames()
    build = os.path.join(HERE, ".strings-check")

    print("building with string extraction forced on…")
    result = subprocess.run(
        ["xcodebuild", "-project", os.path.join(HERE, PROJECT + ".xcodeproj"),
         "-scheme", "Morphiqo"] + DESTINATION +
        ["-derivedDataPath", build, "SWIFT_EMIT_LOC_STRINGS=YES", "build"],
        capture_output=True, text=True)
    if result.returncode != 0:
        tail = "\n".join(l for l in result.stdout.splitlines() if "error:" in l)
        fail("the build failed, so there is nothing to compare against:\n" + (tail or result.stderr[-800:]))

    keys, seen = set(), set()
    for root, _, names in os.walk(build):
        for name in names:
            if not name.endswith(".stringsdata"):
                continue
            stem = name[:-len(".stringsdata")]
            if stem not in sources:        # a file that no longer exists
                continue
            try:
                with open(os.path.join(root, name), "rb") as handle:
                    raw = handle.read()
                try:
                    data = json.loads(raw)
                except ValueError:
                    data = plistlib.loads(raw)
            except Exception:
                continue
            table = (data.get("tables") or {}).get("Localizable")
            if table is None:
                continue
            seen.add(stem)
            for item in table:
                if isinstance(item, dict) and "key" in item:
                    keys.add(item["key"])

    # No coverage threshold: swiftc emits a .stringsdata only for a file that
    # actually contains a localizable string, so most files legitimately
    # produce none. What guards against the partial-build trap instead is
    # owning the DerivedData path above — this data came from the build that
    # just succeeded, and from nothing else.
    if not keys:
        fail("the build produced no localizable strings at all, which cannot "
             "be right — check that SWIFT_EMIT_LOC_STRINGS reached the target.")
    print("read %d keys from %d of %d source files" % (len(keys), len(seen), len(sources)))
    return keys


def normalise(key):
    """Compare keys independently of how a placeholder is spelled.

    The catalog stores what the source wrote — `%@`, `%lld`, `%1$@` — and the
    compiler reports every one of them as `%arg`. Without this, every single
    format string looks both missing and dead at once.
    """
    return re.sub(r"%(?:\d+\$)?(?:arg|@|lld|ld|d|lf|f)", "%arg", key)


# -------------------------------------------------------------------- report --

def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--fix", action="store_true",
                        help="delete dead entries and clear stale marks")
    args = parser.parse_args()

    text = open(CATALOG, encoding="utf-8").read()
    catalog = json.loads(text)["strings"]
    found = extracted_keys()

    have = {normalise(k): k for k in catalog if k}
    want = {normalise(k) for k in found if k}
    missing = sorted(k for k in found if k and normalise(k) not in have)
    dead = sorted(have[n] for n in set(have) - want)
    stale = sorted(k for k, v in catalog.items()
                   if v.get("extractionState") == "stale")

    languages = {"ja", "ko", "zh-Hans", "zh-Hant"}
    untranslated = sorted(
        k for k in catalog
        if k not in dead and k
        and not languages <= set(catalog[k].get("localizations", {})))

    print("catalog %d entries, code %d keys" % (len(catalog), len(found)))
    for label, items in (("MISSING from the catalog", missing),
                         ("DEAD, no longer in the code", dead),
                         ("marked stale by Xcode", stale),
                         ("missing a translation", untranslated)):
        if items:
            print("\n%s (%d):" % (label, len(items)))
            for key in items:
                print("    %s" % json.dumps(key, ensure_ascii=False)[:100])

    if not args.fix:
        if missing or dead or stale or untranslated:
            print("\nRun with --fix to delete the dead entries and clear the stale marks.")
            print("Anything MISSING or untranslated has to be written by hand.")
            return 1
        print("\nin sync — opening Xcode will not change this file")
        return 0

    if not dead and not stale:
        print("\nnothing to fix")
        return 1 if (missing or untranslated) else 0

    spans = {k: (a, b) for k, a, b in entries(text)}
    for key in sorted(dead, key=lambda k: -spans[k][0]):
        start, end = spans[key]
        text = excise(text, start, end)
    # Clearing the mark rather than the entry: these are live strings that were
    # stale for some earlier reason and are used again.
    text = re.sub(r'\n *"extractionState" : "stale",(?=\n)', "", text)

    after = json.loads(text)["strings"]          # must still parse
    if set(after) != set(catalog) - set(dead):
        fail("refusing to write: the edit changed more than the dead entries")
    if any(v.get("extractionState") == "stale" for v in after.values()):
        fail("refusing to write: a stale mark survived")

    open(CATALOG, "w", encoding="utf-8").write(text)
    print("\nremoved %d dead entries, cleared %d stale marks — %d entries remain"
          % (len(dead), len(stale), len(after)))
    if missing or untranslated:
        print("Still to do by hand: %d missing, %d untranslated."
              % (len(missing), len(untranslated)))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
