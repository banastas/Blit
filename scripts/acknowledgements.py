#!/usr/bin/env python3
"""acknowledgements.py — writes Blit/Resources/Acknowledgements.txt, the
third-party notices Blit ships with (shown from Blit › About Blit).

Built from the packages Blit actually resolves (the app's Package.resolved,
which includes BlitKit's), each from its own checkout at the pinned revision:
its LICENSE, its NOTICE (Apache 2.0 §4(d) asks for it to be passed on), and
the license files of code it vendors that its own LICENSE doesn't already
contain. The fonts' OFL texts come from Blit/Resources/Fonts. Nothing is
written by hand, so the file follows the dependencies; scripts/release.sh
runs this before archiving.

Usage:
  scripts/acknowledgements.py                 # resolve packages, write the file
  scripts/acknowledgements.py --checkouts DIR # use these checkouts (SourcePackages/checkouts)
  scripts/acknowledgements.py --check         # exit 1 if the file is out of date

It stops (exit 2) if a package's checkout is missing, isn't at the pinned
revision, or has no license file: shipping without its notice isn't an option.
"""

import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOLVED = os.path.join(ROOT, "Blit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
FONTS = os.path.join(ROOT, "Blit/Resources/Fonts")
OUTPUT = os.path.join(ROOT, "Blit/Resources/Acknowledgements.txt")
DEVELOPER_DIR = os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")

# How each package calls itself (its README / NOTICE), by Package.resolved identity.
NAMES = {
    "sparkle": "Sparkle",
    "swift-asn1": "SwiftASN1",
    "swift-atomics": "Swift Atomics",
    "swift-collections": "Swift Collections",
    "swift-crypto": "Swift Crypto",
    "swift-nio": "SwiftNIO",
    "swift-nio-ssh": "SwiftNIO SSH",
    "swift-system": "Swift System",
}
# Folders whose license files describe code that isn't shipped.
SKIP_DIRS = {".git", ".github", "Tests", "Benchmarks", "IntegrationTests", "Examples", "Snippets",
             "Docs", "docs", "Documentation", "scripts", "dev", "Tools", "Utilities"}
RULE = "=" * 78


def fail(message):
    print(f"acknowledgements: {message}", file=sys.stderr)
    sys.exit(2)


def run(args):
    env = dict(os.environ, DEVELOPER_DIR=DEVELOPER_DIR)
    return subprocess.run(args, cwd=ROOT, env=env, capture_output=True, text=True)


def find_checkouts():
    """The checkouts Xcode builds Blit from (resolving them first)."""
    resolve = run(["xcodebuild", "-project", "Blit.xcodeproj", "-scheme", "Blit", "-resolvePackageDependencies", "-quiet"])
    if resolve.returncode != 0:
        fail("couldn't resolve the packages:\n" + resolve.stderr[-2000:])
    settings = run(["xcodebuild", "-project", "Blit.xcodeproj", "-scheme", "Blit", "-configuration", "Release", "-showBuildSettings"])
    match = re.search(r"^\s*BUILD_DIR = (.+)$", settings.stdout, re.M)
    if not match:
        fail("couldn't find Xcode's build folder")
    build_dir = match.group(1).strip()          # …/DerivedData/Blit-xxx/Build/Products
    return os.path.join(os.path.dirname(os.path.dirname(build_dir)), "SourcePackages", "checkouts")


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().replace("\r\n", "\n").strip("\n")


def squash(text):
    return re.sub(r"\s+", " ", text).strip().lower()


def first_file(folder, names):
    for name in names:
        path = os.path.join(folder, name)
        if os.path.isfile(path):
            return path
    return None


def license_name(text):
    if "Apache License" in text and "Version 2.0" in text:
        return "Apache License 2.0" + (" with Runtime Library Exception" if "Runtime Library Exception" in text else "")
    if "SIL OPEN FONT LICENSE" in text.upper():
        return "SIL Open Font License 1.1"
    if "Permission is hereby granted, free of charge" in text:
        return "MIT"
    if "Redistribution and use in source and binary forms" in text:
        return "BSD"
    if "Permission is granted to anyone to use this software for any purpose" in text:
        return "zlib"
    return "see the text below"


def copyright_line(texts, sources):
    """The first real copyright line: from the NOTICE or LICENSE, else the
    package's own source headers (Apache's LICENSE text carries none)."""
    notice = re.compile(r"^Copyright\s+(\(c\)|©|\d{4})", re.I)   # not "copyright notice that is…" in a license's terms
    for text in texts:
        for line in text.splitlines():
            line = line.strip()
            if notice.match(line):
                return line
    for path in sources:
        if os.path.isfile(path):              # Package.swift: the package's own header first
            with open(path, encoding="utf-8", errors="replace") as f:
                match = re.search(r"Copyright (\(c\)|©) ?\d{4}[^\n]*", f.read(2000))
            if match:
                return match.group(0).strip()
    for folder in (p for p in sources if os.path.isdir(p)):
        for directory, dirs, files in sorted(os.walk(folder)):
            dirs.sort()
            for name in sorted(files):
                if not name.endswith((".swift", ".c", ".h", ".m")):
                    continue
                with open(os.path.join(directory, name), encoding="utf-8", errors="replace") as f:
                    head = f.read(2000)
                match = re.search(r"Copyright (\(c\)|©) ?\d{4}[^\n]*", head)
                if match:
                    return match.group(0).strip().rstrip("*/").strip()
    return None


def vendored_licenses(checkout, root_license):
    """License files of code a package vendors (under Sources/, Vendor/…), unless
    its own LICENSE already includes them (Sparkle's lists its vendored code)."""
    found = []
    covered = squash(root_license)
    for directory, dirs, files in os.walk(checkout):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        if directory == checkout:
            continue
        for name in sorted(files):
            lower = name.lower()
            if not (lower.startswith("license") or lower.startswith("copying") or lower.startswith("notice")):
                continue
            path = os.path.join(directory, name)
            text = read(path)
            if squash(text) and squash(text) not in covered:
                found.append((os.path.relpath(path, checkout), text))
    return found


def package_entry(pin, checkouts):
    identity = pin["identity"]
    location = pin["location"]
    state = pin.get("state", {})
    folder = os.path.join(checkouts, os.path.basename(location).removesuffix(".git"))
    if not os.path.isdir(folder):
        fail(f"no checkout of {identity} at {folder} (open the project in Xcode, or pass --checkouts)")
    head = run(["git", "-C", folder, "rev-parse", "HEAD"]).stdout.strip()
    if state.get("revision") and head != state["revision"]:
        fail(f"{identity}'s checkout is at {head[:10]}, not the pinned {state['revision'][:10]}")
    license_path = first_file(folder, ["LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING", "COPYING.txt"])
    if not license_path:
        fail(f"{identity} has no license file")
    license_text = read(license_path)
    notice_path = first_file(folder, ["NOTICE", "NOTICE.txt", "NOTICE.md"])
    notice_text = read(notice_path) if notice_path else None
    sources = [os.path.join(folder, "Package.swift")] + [os.path.join(folder, d) for d in ("Sources", "Sparkle")]
    sources = [p for p in sources if os.path.exists(p)]
    return {
        "name": NAMES.get(identity, identity),
        "version": state.get("version") or state.get("revision", "")[:12],
        "url": location.removesuffix(".git"),
        "copyright": copyright_line([t for t in (notice_text, license_text) if t], sources),
        "license": license_name(license_text),
        # The NOTICE first: the attributions it asks to keep, before the license's terms.
        "texts": ([("NOTICE", notice_text)] if notice_text else [])
                 + [("LICENSE", license_text)]
                 + [(f"{path} (included code)", text) for path, text in vendored_licenses(folder, license_text)],
    }


def font_entries():
    entries = []
    for name in sorted(os.listdir(FONTS)):
        if not name.endswith("-OFL.txt"):
            continue
        text = read(os.path.join(FONTS, name))
        entries.append({
            "name": name.removesuffix("-OFL.txt") + " (font)",
            "version": None,
            "url": None,
            "copyright": copyright_line([text], []),
            "license": license_name(text),
            "texts": [("LICENSE", text)],
        })
    return entries


def render(entries):
    lines = [
        "BLIT — ACKNOWLEDGEMENTS",
        "",
        "Blit is built with the open-source software below. Each is listed with its",
        "copyright notice and license, as its license asks. Thank you to everyone",
        "who made them.",
        "",
        "Written by scripts/acknowledgements.py from the packages Blit is built with;",
        "don't edit it by hand.",
    ]
    for entry in entries:
        title = entry["name"] + (f" {entry['version']}" if entry["version"] else "")
        lines += ["", RULE, title]
        if entry["url"]:
            lines.append(entry["url"])
        if entry["copyright"]:
            lines.append(entry["copyright"])
        lines += [f"License: {entry['license']}", RULE]
        for label, text in entry["texts"]:
            lines += ["", f"--- {label} ---", "", text]
    return "\n".join(lines) + "\n"


def main():
    args = sys.argv[1:]
    checkouts = None
    if "--checkouts" in args:
        index = args.index("--checkouts")
        if index + 1 >= len(args):
            fail("--checkouts needs a folder")
        checkouts = args[index + 1]
    checkouts = checkouts or os.environ.get("ACK_CHECKOUTS") or find_checkouts()
    with open(RESOLVED) as f:
        pins = json.load(f)["pins"]
    entries = sorted((package_entry(pin, checkouts) for pin in pins), key=lambda e: e["name"].lower()) + font_entries()
    text = render(entries)
    current = read(OUTPUT) + "\n" if os.path.exists(OUTPUT) else None
    if "--check" in args:
        if current != text:
            print("acknowledgements: Blit/Resources/Acknowledgements.txt is out of date (run scripts/acknowledgements.py)")
            sys.exit(1)
        print("acknowledgements: up to date")
        return
    if current != text:
        with open(OUTPUT, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"acknowledgements: wrote {os.path.relpath(OUTPUT, ROOT)}")
    else:
        print("acknowledgements: unchanged")
    for entry in entries:
        extra = [label for label, _ in entry["texts"] if label not in ("LICENSE",)]
        print(f"  {entry['name']:24} {entry['version'] or '':10} {entry['license']}" + (f" · {', '.join(extra)}" if extra else ""))


if __name__ == "__main__":
    main()
