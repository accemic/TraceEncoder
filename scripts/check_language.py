#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""This repository is English. Comments and messages included.

The predecessor of this guard (`check_mixed_language.py`) looked for one thing
only: a comment block that is HALF translated, and only in `*.py`, and only in
runs of `#` lines. It reported a clean OK over 108 files while

  * `examples/dashboard/index.html` carried 994 German lines in CSS and JS
    block comments -- the file a reviewer opens first,
  * the simulation testbenches under `examples/kv260/` carried 183 more,
    including the texts of `$display`/`$fatal`, which end up in the log a
    reviewer reads while re-running them,
  * `themes.json` shipped German KEYS that `index.html` reads by name.

None of that is a half translation, so none of it was a finding. A guard that
is narrower than its name is worse than no guard: it produces a green line.

This guard has since been caught by the same class of defect, twice, and both
holes are closed below:

  * `examples/kv260/common/board/ctrace_resmem.dtso` -- German from the first
    comment line to the last, shipped inside every board app package -- was
    never opened, because `.dtso` was not in `SUFFIXES`. Neither were `.dts`,
    `.c`, `.S`, `.adoc` (the published documentation!), `.xdc`, `.config`, or
    a file with NO extension at all: `p.suffix` is `""` there, so the
    membership test dropped `Makefile`, `VERSION` and the three Buildroot
    `*_defconfig`s, one of which carried 24 German lines.
  * `examples/dashboard/server.py:957` and `:962` were read and passed,
    because the words that make them German -- `alle`, `Werte`, `wie`,
    `Kosmetik` -- were not in the word list. A trailing comment
    (`code  # German text`) is not a comment BLOCK, so it only ever meets the
    per-line rule, and that rule needs two markers on one line.

What this one checks, in every tracked text file of the repository:

  1. COMMENT BLOCKS -- runs of `#` or `//` lines, `/* ... */` and `<!-- ... -->`
     blocks. A block is reported when it contains at least two DIFFERENT German
     function words. That covers the half-translated block (the old case) and
     the fully German one (the case that was missed) in one rule.
  2. SINGLE LINES anywhere in the file -- same threshold. This is what catches
     German inside a string: a `$display` text, a check label, a JSON value.

Both rules count DISTINCT markers, so one loan word does not trip them ("von
Neumann" is one marker, not two). The word list holds only function words with
no English homograph -- `die`, `man`, `war`, `hat` are deliberately absent,
because they are ordinary English words as well.

Deliberately NOT covered:

  * `examples/dashboard/check_replay_public.py` and its test -- the German
    word list IS the detector there, and the German fixtures are what test it.
  * `legal/` -- a signed licence grant is a legal document, not documentation;
    it is quoted, not maintained.
  * this file -- it names German words in order to find them.

Exemptions are single paths, never prefixes: a guard that cannot see itself
has not been tested.
"""
import re
import subprocess
import sys
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SUFFIXES = (
    # sources and markup
    ".py", ".js", ".mjs", ".html", ".css", ".sv", ".svh", ".v",
    ".sh", ".ps1", ".json", ".md", ".tcl", ".rdl", ".yml", ".yaml",
    # C and assembly of the example software
    ".c", ".h", ".s", ".ld",
    # device trees and their templates -- shipped inside the board app
    # packages, and the reason this list grew (ctrace_resmem.dtso was
    # commented in German from top to bottom and nobody's guard saw it)
    ".dts", ".dtsi", ".dtso", ".in",
    # documentation and licence texts
    ".adoc", ".rst", ".txt",
    # build, synthesis and formal flow descriptions
    ".abc", ".ys", ".sby", ".smtc", ".xdc", ".mk", ".f", ".pl",
    # configuration and metadata
    ".config", ".toml", ".cff", ".desc", ".license", ".verible_lint",
    # tabular data carrying prose columns
    ".csv", ".tsv",
    # vendoring deltas. THE ONLY GERMAN THAT ACTUALLY SHIPPED (2026-08-21):
    # examples/kv260/third_party/patches/cva6/*.patch carried German comments
    # in all six files while cva6_ref/ -- where the applied result lives --
    # is gitignored and never published. The patches were invisible twice
    # over: once through SKIP_PARTS below, once through this list.
    ".patch", ".diff",
)
# `third_party` is NOT in this list, on purpose. It used to be, and that is
# how six German patch files survived every sweep. The vendored source trees
# themselves are not reached anyway -- this guard walks TRACKED files, and
# cva6_ref/ is gitignored (.gitignore:74). What remains inside third_party
# and IS tracked -- the patch series and rocket_ref/ -- is our own material
# and has to hold the same language rule as the rest.
SKIP_PARTS = ("bld", ".git", "node_modules")
# `fpga/prebuilt` trees hold the PUBLISHED demo bundles, extracted verbatim
# and verified against the sha256 pins (scripts/demo.pin) and their own
# MANIFEST.sha256 -- editing a file there to translate a comment would break
# both proofs, which is worse than the four German comment blocks the
# v1.0.1-demo2 series froze in (ctrace_resmem.dtso of four Linux demos; the
# LIVE source of that file, examples/kv260/common/board/ctrace_resmem.dtso,
# is English since the 2026-08-20 sweep). Denominator, stated per the
# exclusion-list lesson: this skips ONLY <demo>/fpga/prebuilt/** -- 12 app
# dirs of four files each as of 2026-08-26 -- and nothing the build can
# reach; a NEW prebuilt drop is covered by its provenance README instead.
SKIP_PREBUILT_MARKER = ("fpga", "prebuilt")
SKIP_FILES = {
    "examples/dashboard/check_replay_public.py",
    "examples/dashboard/test_replay_public.py",
    "scripts/check_language.py",
}

# Function words without an English homograph. Distinct hits are counted.
#
# Every word here was checked against English before it was added, because a
# marker that is also an English word makes the guard fire on English prose,
# and a guard that cries wolf gets switched off. Deliberately ABSENT for that
# reason: die, man, war, hat, is, in, so, bin, hex, den (a den), alt (alt
# text), links (hyperlinks), also, am, an, des (matches DES case-insensitively),
# rechts/oben-style pairs whose partner is English.
GER = re.compile(
    r"\b(nicht|nichts|kein|keine|keinen|keinem|keiner|und|oder|wird|werden"
    r"|wurde|wurden|worden|sind|ist|fuer|für|mit|von|vom|aus"
    r"|nach|ueber|über|unter|durch|ohne|beim|zum|zur|muss|müssen|muessen"
    r"|soll|sollen|sollte|darf|duerfen|dürfen|dann|noch|schon|nur|auch"
    r"|jede|jeder|jedes|jeden|jedem|eine|einen|einem|einer|eines|ein"
    r"|dass|weil|damit|sonst|wenn|sich|ihre|seine|seinen|diese|dieser"
    r"|dieses|diesem|diesen|hier|dort|jetzt|waere|wäre|haette|hätte"
    r"|koennen|können|koennte|könnte|kann|deshalb|daher|dafuer|dafür"
    r"|dabei|davon|dazu|darin|gibt|steht|stehen|liegt|liegen|bleibt"
    r"|bleiben|laeuft|läuft|laufen|gehoert|gehört|gehoeren|gehören"
    r"|haengt|hängt|heisst|heißt|gilt|gelten|zeigt|zeigen|braucht"
    r"|brauchen|nimmt|nehmen|macht|machen|liest|lesen|zwischen|gegen"
    r"|immer|wieder|bereits|jedoch|allerdings|sondern|statt|obwohl"
    r"|nachdem|bevor|solange|sobald|sowie|jeweils|selbst|zusammen"
    r"|weiter|weiterhin|zurueck|zurück|mehr|weniger|etwa|genau|bewusst"
    r"|gemessen|erzeugt|geschrieben|gelesen|gesetzt|verwendet|benutzt"
    r"|alle|allen|aller|alles|beide|beiden|viele|einzeln|einzelne"
    r"|erst|erste|ersten|neue|neuen|alte|alten|ganze|ganzen|unten"
    r"|Zeile|Zeilen|Datei|Dateien|Fehler|Speicher|Adresse|Adressen"
    # ASCII transcriptions. The UMLAUT rule below cannot see these, and
    # in the vendoring deltas that is not an edge case but the norm --
    # every one of them is written Huelle/laesst/gehoeren, so the rule
    # was structurally dead exactly where the German was (2026-08-21).
    r"|Huelle|Groesse|Groessen|Laenge|Laengen|Aenderung|Aenderungen"
    r"|Ueberlauf|Uebersetzung|Ausfuehrung|ausfuehrbar|zufuegen"
    r"|gehoerig|moeglich|noetig|hoeher|groesser|spaeter|naechste"
    r"|waehrend|zunaechst|urspruenglich|vollstaendig|abhaengig"
    r"|unveraendert|veraendert|erklaert|waehlt|zaehlt|haelt|faellt"
    r"|Beispiel|Achtung|Hinweis|siehe|bzw|ggf|Grund|Ursache|Zweck"
    r"|Nachweis|Pruefung|Prüfung|Quelle|Senke|Kern|Kerne|Fenster"
    r"|Ausgabe|Eingabe|Anzahl|Groesse|Größe|Reihenfolge|Bedingung"
    r"|Verzeichnis|Befund|Zaehler|Zähler|Schluessel|Schlüssel"
    r"|Meldung|Meldungen|Knoten|Abzeichen|Szenario|Szenarien"
    r"|wie|das|Wert|Werte|echte|echten|eigene|eigenen|andere|anderen"
    r"|etwas|ausserdem|bisher|dadurch|somit|zugleich|zunaechst)\b", re.I)

# A word carrying an umlaut or an eszett is German, full stop -- no word list
# can be as complete as the alphabet is. Counted as one marker like any other,
# so a single author name (`Preußer`, rtl/external/**) does not trip anything;
# German prose reaches the threshold of two on its own.
UMLAUT = re.compile(r"\b\w*[äöüßÄÖÜ]\w*\b", re.U)

BLOCK_RE = (
    re.compile(r"/\*.*?\*/", re.S),
    re.compile(r"<!--.*?-->", re.S),
)


def tracked_files():
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files"],
                         capture_output=True, text=True, encoding="utf-8").stdout
    for rel in out.split("\n"):
        if not rel:
            continue
        p = ROOT / rel
        # A file without any extension is text as often as not in this tree
        # -- `Makefile`, `VERSION`, and the Buildroot `*_defconfig`s, one of
        # which carried 24 German lines. Scan them; a binary one drops out
        # at the UnicodeDecodeError below.
        if p.suffix and p.suffix.lower() not in SUFFIXES:
            continue
        if any(part in SKIP_PARTS for part in p.parts):
            continue
        if any(p.parts[i:i + 2] == SKIP_PREBUILT_MARKER
               for i in range(len(p.parts) - 1)):
            continue
        if rel in SKIP_FILES or rel.startswith("legal/"):
            continue
        if not p.is_file():
            continue
        yield rel, p


DIFF_MARK = ("+", "-", " ")


def strip_diff(lines, rel):
    """Remove the leading +/-/space column of a unified diff.

    Without this every line of a `.patch` starts with a diff marker, no line
    starts with `#` or `//` any more, and the comment-block detection finds
    nothing at all -- the single-line pass would still fire, but only where
    two markers meet in ONE line, which German prose rarely does.
    Hunk headers and file headers are dropped: `--- a/foo` and `+++ b/foo`
    are not text anybody wrote.
    """
    if not rel.endswith((".patch", ".diff")):
        return lines
    out = []
    for ln in lines:
        if ln.startswith(("---", "+++", "@@", "diff ", "index ")):
            out.append("")
            continue
        out.append(ln[1:] if ln[:1] in DIFF_MARK else ln)
    return out


def line_blocks(lines, marker):
    """Runs of consecutive lines starting with `marker`."""
    i = 0
    while i < len(lines):
        if lines[i].strip().startswith(marker):
            j = i
            while j < len(lines) and lines[j].strip().startswith(marker):
                j += 1
            yield i + 1, "\n".join(lines[i:j])
            i = j
        else:
            i += 1


def german(text):
    hits = {m.lower() for m in GER.findall(text)}
    hits |= {w.lower() for w in UMLAUT.findall(text)}
    return hits


def main() -> int:
    findings = []
    scanned = 0
    for rel, path in tracked_files():
        try:
            src = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        scanned += 1
        lines = strip_diff(src.splitlines(), rel)
        seen = set()

        for marker in ("#", "//"):
            for start, text in line_blocks(lines, marker):
                hits = german(text)
                if len(hits) >= 2:
                    findings.append((rel, start, "comment block",
                                     sorted(hits)[:4]))
                    seen.update(range(start, start + text.count("\n") + 1))

        block_src = "\n".join(lines) if rel.endswith((".patch", ".diff")) else src
        for rx in BLOCK_RE:
            for m in rx.finditer(block_src):
                hits = german(m.group(0))
                if len(hits) >= 2:
                    start = block_src.count("\n", 0, m.start()) + 1
                    findings.append((rel, start, "comment block",
                                     sorted(hits)[:4]))
                    seen.update(range(start, start + m.group(0).count("\n") + 1))

        for i, ln in enumerate(lines, 1):
            if i in seen:
                continue
            hits = german(ln)
            if len(hits) >= 2:
                findings.append((rel, i, "line", sorted(hits)[:4]))

    if findings:
        print("[check_language] %d German passage(s) in an English repository:"
              % len(findings))
        for rel, start, kind, hits in findings[:60]:
            print("  %s:%d  (%s: %s)" % (rel, start, kind, ", ".join(hits)))
        if len(findings) > 60:
            print("  ... and %d more" % (len(findings) - 60))
        print("  Translate the whole passage. A phrase-wise sweep produces")
        print("  half-translated blocks, which read worse than the original.")
        return 1
    print("[check_language] OK: %d file(s), no German passages" % scanned)
    return 0


if __name__ == "__main__":
    sys.exit(main())
