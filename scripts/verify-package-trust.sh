#!/bin/bash
# verify-package-trust.sh [--update]
#
# Guards the ONE remaining build-time trust weakening in this fork's CI.
#
# THE PROBLEM. Swift package MACROS and BUILD-TOOL PLUGINS are executables that Xcode
# compiles and RUNS on the build machine, with the build user's privileges, during every
# build. Xcode gates the first use of each behind an interactive "Trust & Enable" dialog
# that a headless runner cannot answer, so CI passes -skipPackagePluginValidation. That
# flag is blanket: it trusts EVERY plugin in the resolved graph, including ones added later
# by a transitive dependency bump that nobody looked at.
#
# THE GUARD. This script re-derives, from Package.resolved alone, every macro and plugin
# target declared anywhere in the pinned package graph, and fails unless each one is a
# component this fork has explicitly reviewed and its source is byte-identical to what was
# reviewed. It therefore fails on:
#
#   * a new macro or plugin appearing in ANY package in the graph (the case the blanket
#     flag would otherwise wave through);
#   * a pinned revision moving under an already-reviewed component;
#   * the component's source tree differing in content at the same revision.
#
# It runs BEFORE the build, uses git only -- nothing is compiled, nothing is executed --
# and identifies content by git object ids: `git rev-parse <rev>:<path>` is the id of that
# directory's tree, i.e. a hash over every file under it.
#
#   ./scripts/verify-package-trust.sh            verify against package-trust.json (CI)
#   ./scripts/verify-package-trust.sh --update   rewrite package-trust.json from the
#                                                current pins -- ONLY after reading the
#                                                sources; the diff on that file IS the
#                                                review record.
#
# Exit 0 = every macro/plugin target in the graph is reviewed and unchanged.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
resolved="$repo_root/VoiceInk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
trust_file="$repo_root/package-trust.json"
mode="${1:-verify}"

[ -f "$resolved" ] || { echo "error: no Package.resolved at $resolved" >&2; exit 1; }
if [ "$mode" = "--update" ]; then mode=update; else mode=verify; fi
[ "$mode" = "update" ] || [ -f "$trust_file" ] || { echo "error: no $trust_file (run with --update)" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 - "$resolved" "$trust_file" "$work" "$mode" <<'PYEOF'
import json, os, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

resolved_path, trust_path, work, mode = sys.argv[1:5]

pins = json.load(open(resolved_path))["pins"]
trust = json.load(open(trust_path)) if os.path.exists(trust_path) else {"components": []}
trusted = {(c["package"], c["name"]): c for c in trust.get("components", [])}

# `.macro(name: "X"` / `.plugin(name: "X"` in any package manifest. Matches both the
# declaration of a component and a target's USE of one; both are treated as in-graph,
# which is the conservative direction.
DECL = re.compile(r'\.(macro|plugin)\s*\(\s*\n?\s*name:\s*"([^"]+)"')
CAPABILITY = re.compile(r'capability:\s*\.(buildTool|command)')
MANIFESTS = re.compile(r'^Package(@swift-[0-9.]+)?\.swift$')
# SPM's conventional locations, plus the ones these packages actually use.
CANDIDATE_DIRS = ("Plugins", "Sources", "Libraries", "Source", "Plugin")

def git(repo, *args, check=True):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise SystemExit(f"error: git {' '.join(args)} in {repo} failed: {r.stderr.strip()}")
    return r.stdout.strip() if r.returncode == 0 else None

def oid(repo, revision, path):
    """git object id of <path> at <revision>: a content hash over that whole subtree."""
    return git(repo, "rev-parse", "--verify", "--quiet", f"{revision}:{path}", check=False)

def fetch(pin):
    identity, location = pin["identity"], pin["location"]
    revision = pin["state"]["revision"]
    repo = os.path.join(work, identity)
    os.makedirs(repo, exist_ok=True)
    git(repo, "init", "-q")
    git(repo, "remote", "add", "origin", location, check=False)
    # Trees but not blobs; blobs are fetched lazily, only for the manifests we read.
    r = subprocess.run(["git", "-C", repo, "fetch", "-q", "--depth", "1",
                        "--filter=blob:none", "origin", revision], capture_output=True, text=True)
    if r.returncode != 0:
        # Some servers refuse fetch-by-sha; fall back to a full blobless fetch.
        if git(repo, "fetch", "-q", "--filter=blob:none", "origin",
               "+refs/heads/*:refs/remotes/origin/*", "+refs/tags/*:refs/tags/*",
               check=False) is None:
            raise SystemExit(f"error: could not fetch {location} @ {revision}")
    if git(repo, "cat-file", "-e", revision + "^{commit}", check=False) is None:
        raise SystemExit(f"error: {location} does not contain revision {revision}")
    return identity, revision, repo

failures, found, records = [], [], []

with ThreadPoolExecutor(max_workers=8) as pool:
    fetched = list(pool.map(fetch, pins))

for identity, revision, repo in fetched:
    listing = git(repo, "ls-tree", "--name-only", revision) or ""
    manifests = [n for n in listing.splitlines() if MANIFESTS.match(n)]
    components = {}
    for m in manifests:
        text = git(repo, "cat-file", "-p", f"{revision}:{m}") or ""
        for match in DECL.finditer(text):
            kind, name = match.group(1), match.group(2)
            cap = CAPABILITY.search(text, match.end(), match.end() + 400)
            capability = cap.group(1) if cap else ("macro" if kind == "macro" else "unknown")
            # A capability seen at the declaration wins over a bare `.plugin(name:)` use site.
            if components.get(name) in (None, "unknown"):
                components[name] = capability

    for name, capability in sorted(components.items()):
        found.append((identity, name))
        entry = trusted.get((identity, name))
        # Locate the component's sources: a recorded path wins, else probe SPM's layouts.
        # A component whose sources cannot be located cannot be hashed, so that is a hard
        # failure rather than a silent pass.
        path, tree = (entry or {}).get("path"), None
        if path:
            tree = oid(repo, revision, path)
        if tree is None:
            for d in CANDIDATE_DIRS:
                tree = oid(repo, revision, d + "/" + name)
                if tree:
                    path = d + "/" + name
                    break
        if tree is None:
            failures.append(f"{capability} '{name}' ({identity}): cannot locate its sources "
                            f"in the repository at {revision[:12]} -- refusing to trust it")
            continue

        extra = {}
        for p in (entry or {}).get("also", []):
            t = oid(repo, revision, p)
            if t is None:
                failures.append(f"{capability} '{name}' ({identity}): companion path {p} "
                                f"no longer exists at {revision[:12]}")
                continue
            extra[p] = t

        record = {"package": identity, "name": name, "capability": capability,
                  "path": path, "revision": revision, "tree": tree}
        if extra:
            record["also"] = sorted(extra)
            record["also_trees"] = extra
        record["note"] = (entry or {}).get("note", "PENDING REVIEW")
        records.append(record)

        if mode == "verify":
            if entry is None:
                failures.append(
                    f"UNREVIEWED {capability} '{name}' in package '{identity}' @ {revision[:12]}.\n"
                    f"    A macro or build-tool plugin runs code on the build machine. This one\n"
                    f"    entered the pinned graph without review. Read its source, then run\n"
                    f"    scripts/verify-package-trust.sh --update to record the review.")
                continue
            if entry["revision"] != revision:
                failures.append(f"{capability} '{name}' ({identity}): pinned revision moved\n"
                                f"    reviewed: {entry['revision']}\n"
                                f"    resolved: {revision}")
            if entry["tree"] != tree:
                failures.append(f"{capability} '{name}' ({identity}): source tree at {path} CHANGED\n"
                                f"    reviewed: {entry['tree']}\n"
                                f"    actual:   {tree}")
            for p, t in extra.items():
                if entry.get("also_trees", {}).get(p) != t:
                    failures.append(f"{capability} '{name}' ({identity}): companion tree {p} CHANGED\n"
                                    f"    reviewed: {entry.get('also_trees', {}).get(p)}\n"
                                    f"    actual:   {t}")

records.sort(key=lambda r: (r["package"], r["name"]))

if mode == "update":
    with open(trust_path, "w") as fh:
        json.dump({
            "_comment": "Every macro / package-plugin target declared anywhere in the pinned "
                        "SPM graph, with the git object id of its source tree. Regenerate with "
                        "scripts/verify-package-trust.sh --update AFTER reading the sources: "
                        "the diff on this file IS the review record. See FORK-PATCHES.md S6.",
            "components": records,
        }, fh, indent=2, sort_keys=False)
        fh.write("\n")
    print("wrote " + trust_path + f" with {len(records)} component(s)")
    for r in records:
        print(f"  {r['capability']:9} {r['package']}/{r['name']}  {r['path']}  tree {r['tree'][:12]}")
    sys.exit(0)

# A reviewed component that has left the graph is not a security failure, but it does mean
# the trust file is stale, so say so rather than silently carrying dead entries.
for pkg, name in sorted(set(trusted) - set(found)):
    print(f"  note: reviewed component {pkg}/{name} is no longer declared in the graph "
          f"(drop it with --update)")

print(f"scanned {len(pins)} pinned packages; "
      f"{len(found)} macro/plugin target(s) declared in the graph")
for r in records:
    print(f"  {r['capability']:9} {r['package']}/{r['name']}  tree {r['tree'][:12]}")

if failures:
    print("\nerror: package trust check FAILED", file=sys.stderr)
    for f in failures:
        print("  " + f, file=sys.stderr)
    sys.exit(1)
print("OK: every macro/plugin target in the graph is reviewed and unchanged")
PYEOF
