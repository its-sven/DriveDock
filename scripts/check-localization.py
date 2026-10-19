#!/usr/bin/env python3
"""Checks that every UI text in Sources/ has a translation in each language.

English is the development language, so the English text in the code is the key.
Finds keys in tr("…") calls and in SwiftUI initializers that localize string literals
(Text("…"), Button("…"), .help("…") …) and compares them with
Resources/<lang>.lproj/Localizable.strings:

  - keys used in code but missing in a translation
  - translations whose key is no longer used
  - placeholders (%@, %lld) that differ between key and translation
  - SwiftUI literals with \\( … ) interpolation, which can't be matched to a key

Usage: scripts/check-localization.py        (exit code 1 on problems)
       scripts/check-localization.py --keys (print all keys)
"""

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
RESOURCES = ROOT / "Resources"

# Texts that stay the same in every language (product names, technical labels).
UNTRANSLATED = {"DriveDock"}

STRING = r'"((?:[^"\\]|\\.)*)"'
PATTERNS = [
    # tr("key") and tr("key", args…)
    re.compile(r'\btr\(\s*' + STRING),
    # SwiftUI initializers whose first argument is a LocalizedStringKey literal.
    re.compile(r'\b(?:Text|Button|Toggle|Label|TextField|SecureField|Section|Picker|'
               r'LabeledContent|Menu|Link|ContentUnavailableView)\(\s*' + STRING),
    re.compile(r'\.(?:help|navigationTitle)\(\s*' + STRING),
]
PLACEHOLDER = re.compile(r'%(?:\d+\$)?(@|lld|ld|d)')


def unescape(literal: str) -> str:
    return literal.replace('\\"', '"').replace("\\\\", "\\")


def keys_in_code():
    keys, problems = {}, []
    for path in sorted(SOURCES.rglob("*.swift")):
        for lineno, line in enumerate(path.read_text().splitlines(), 1):
            if line.strip().startswith("//"):
                continue
            for pattern in PATTERNS:
                for match in pattern.finditer(line):
                    literal = match.group(1)
                    where = f"{path.relative_to(ROOT)}:{lineno}"
                    if "\\(" in literal:
                        problems.append(f"{where}: interpolated literal can't be localized: \"{literal}\"")
                        continue
                    key = unescape(literal)
                    if key and key not in UNTRANSLATED:
                        keys.setdefault(key, where)
    return keys, problems


def load_strings(path: Path) -> dict:
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(path)],
                         capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"{path}: invalid .strings file\n{out.stderr}")
    return json.loads(out.stdout)


def placeholders(text: str) -> list:
    return sorted(m.group(1) for m in PLACEHOLDER.finditer(text))


def main() -> int:
    keys, problems = keys_in_code()
    if "--keys" in sys.argv:
        for key in sorted(keys, key=str.lower):
            print(key)
        return 0

    for key in keys:
        if placeholders(key) and "%" in key.replace("%@", "").replace("%lld", ""):
            problems.append(f"{keys[key]}: unexpected % in key \"{key}\"")

    languages = sorted(p.stem for p in RESOURCES.glob("*.lproj"))
    for lang in languages:
        table_path = RESOURCES / f"{lang}.lproj" / "Localizable.strings"
        if lang == "en":
            continue  # development language: the keys are the English texts
        if not table_path.exists():
            problems.append(f"{lang}: {table_path.relative_to(ROOT)} is missing")
            continue
        table = load_strings(table_path)
        for key, where in sorted(keys.items()):
            if key not in table:
                problems.append(f"{lang}: missing translation for \"{key}\" ({where})")
            elif placeholders(key) != placeholders(table[key]):
                problems.append(f"{lang}: placeholders differ for \"{key}\" → \"{table[key]}\"")
        for key in sorted(set(table) - set(keys)):
            problems.append(f"{lang}: unused translation \"{key}\"")

    for problem in problems:
        print(problem)
    print(f"{len(keys)} keys, languages: {', '.join(languages) or 'none'} – "
          f"{'OK' if not problems else f'{len(problems)} problem(s)'}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
