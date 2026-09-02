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
# THE GUARD, and why it is shaped the way it is. An earlier version of this script tried to
# ENUMERATE the dangerous things: it ran a regular expression over each package manifest
# looking for `.macro(name: "X")` / `.plugin(name: "X")` and demanded that each match be an
# allowlisted, hash-pinned component. That is unsound, and provably so. A Package.swift is
# executable Swift, not data: a target can be declared through a helper function, a variable,
# a loop, `#if` logic, or simply formatting the pattern does not match. A package carrying a
# build-tool plugin declared in any of those forms produced ZERO matches, contributed no
# component to check, and -- because a package with no recognised components was not itself
# required to be allowlisted -- sailed through with "OK". Reproduced before this rewrite: a
# package whose manifest builds its plugin target via `func buildToolTarget(_:) -> Target`
# was added to the graph and the old script printed
# "OK: every macro/plugin target in the graph is reviewed and unchanged", exit 0.
#
# So trust is no longer bound to what a regex can find INSIDE the graph. It is bound to the
# ENTIRE RESOLVED INPUT, in a form that cannot be evaded by how a target is declared:
#
#   1. THE PACKAGE SET. Every pin in Package.resolved must be one recorded in
#      package-trust.json's "graph" section, and every recorded package must still be pinned.
#      A NEW PACKAGE ENTERING THE GRAPH IS A HARD FAILURE, whatever it does or does not
#      declare. This is the check the regex approach could not provide.
#   2. THE PINNED REVISION. Each package's revision must be exactly the reviewed one. A git
#      revision is a hash over that package's whole tree, so an unchanged revision is a
#      cryptographic guarantee that not one byte of that package -- manifest, plugin source,
#      anything -- has changed. A moved pin is a hard failure.
#   3. THE TREE AND THE MANIFESTS, recorded explicitly. Per package this file also carries
#      the root tree object id and the blob object id of every root `Package*.swift`. These
#      are implied by (2), but recording them makes the review record legible on its own
#      terms and catches the case where a pin's `location` is repointed at a different
#      repository.
#   4. THE RESOLVED FILE ITSELF. sha256 of Package.resolved's bytes, so any edit at all --
#      including one to a field this script does not otherwise model -- forces a re-bless.
#
#   5. AND, as additional review evidence rather than as the mechanism, the previous
#      per-component records: for each macro/plugin target the regex CAN see, the path and
#      git tree id of its sources, plus the note recording what reading them found. These
#      still fail on an unreviewed match, a moved revision or a changed source tree. They are
#      kept because they are useful, not because they are sufficient.
#
# Nothing here compiles or executes any package code: it uses `git` only, fetching trees but
# not blobs, and identifies content by git object ids.
#
#   ./scripts/verify-package-trust.sh            verify against package-trust.json (CI)
#   ./scripts/verify-package-trust.sh --update   RE-BLESS: rewrite package-trust.json from
#                                                the current pins. The diff on that file IS
#                                                the review record -- see "Re-blessing" in
#                                                FORK-PATCHES.md section 6.
#
# Exit 0 = the resolved graph is exactly the reviewed one, and every reviewed component is
# unchanged.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
resolved="$repo_root/VoiceInk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
trust_file="$repo_root/package-trust.json"
mode="${1:-verify}"

case "$mode" in
  -h|--help)
    sed -n '2,70p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0 ;;
esac

[ -f "$resolved" ] || { echo "error: no Package.resolved at $resolved" >&2; exit 1; }
if [ "$mode" = "--update" ]; then mode=update; else mode=verify; fi
[ "$mode" = "update" ] || [ -f "$trust_file" ] || { echo "error: no $trust_file (run with --update)" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 - "$resolved" "$trust_file" "$work" "$mode" <<'PYEOF'
import hashlib, json, os, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

resolved_path, trust_path, work, mode = sys.argv[1:5]

resolved_bytes = open(resolved_path, "rb").read()
resolved_sha = hashlib.sha256(resolved_bytes).hexdigest()
pins = json.loads(resolved_bytes)["pins"]

try:
    trust = json.load(open(trust_path)) if os.path.exists(trust_path) else {}
except json.JSONDecodeError as e:
    # Fail closed with a readable message rather than a traceback: an unparseable trust
    # file is a trust file nobody can have reviewed.
    raise SystemExit(f"error: {trust_path} is not valid JSON ({e}).\n"
                     f"    A trust file that cannot be parsed cannot be a reviewed one. Fix it,\n"
                     f"    or regenerate it with scripts/verify-package-trust.sh --update.")
graph_trust = trust.get("graph") or {}
trusted_pkgs = {p["identity"]: p for p in graph_trust.get("packages", [])}
trusted_components = {(c["package"], c["name"]): c for c in trust.get("components", [])}

# `.macro(name: "X"` / `.plugin(name: "X"` in any package manifest. This is the LEGIBILITY
# pass, not the guard: see the header. It is best-effort by construction, which is exactly
# why the graph-level checks above it do not depend on it.
DECL = re.compile(r'\.(macro|plugin)\s*\(\s*\n?\s*name:\s*"([^"]+)"')
CAPABILITY = re.compile(r'capability:\s*\.(buildTool|command)')
MANIFESTS = re.compile(r'^Package(@swift-[0-9.]+)?\.swift$')
# SPM's conventional locations, plus the ones these packages actually use.
CANDIDATE_DIRS = ("Plugins", "Sources", "Libraries", "Source", "Plugin")
# The only pin kind this fork's graph uses. A registry pin or a local path pin has different
# state fields and different trust properties, so an unrecognised kind is a hard failure
# rather than something to model speculatively.
SUPPORTED_KINDS = ("remoteSourceControl",)

RE_BLESS = ("Read what changed, then re-bless with:\n"
            "        scripts/verify-package-trust.sh --update\n"
            "    and commit the package-trust.json diff -- that diff IS the review record.\n"
            "    See FORK-PATCHES.md section 6, \"Re-blessing the package trust file\".")

failures, notes = [], []

def git(repo, *args, check=True):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise SystemExit(f"error: git {' '.join(args)} in {repo} failed: {r.stderr.strip()}")
    return r.stdout.strip() if r.returncode == 0 else None

def oid(repo, revision, path):
    """git object id of <path> at <revision>: a content hash over that whole subtree."""
    return git(repo, "rev-parse", "--verify", "--quiet", f"{revision}:{path}", check=False)

def fetch(pin):
    identity = pin["identity"]
    kind = pin.get("kind")
    if kind not in SUPPORTED_KINDS:
        raise SystemExit(
            f"error: pin '{identity}' has kind '{kind}', which this trust check does not\n"
            f"    model. Refusing to pass: extend scripts/verify-package-trust.sh to bind\n"
            f"    that kind's inputs before allowing it into the graph.")
    location = pin["location"]
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
    return pin, repo

with ThreadPoolExecutor(max_workers=8) as pool:
    fetched = list(pool.map(fetch, pins))

# ---------------------------------------------------------------- 1..4: the resolved graph
pkg_records, component_records, found = [], [], []

for pin, repo in fetched:
    identity = pin["identity"]
    location = pin["location"]
    revision = pin["state"]["revision"]

    root_tree = oid(repo, revision, "")
    if root_tree is None:
        raise SystemExit(f"error: cannot read the tree of {identity} @ {revision}")

    manifests = {}
    for line in (git(repo, "ls-tree", revision) or "").splitlines():
        meta, _, name = line.partition("\t")
        _, objtype, objid = meta.split()
        if objtype == "blob" and MANIFESTS.match(name):
            manifests[name] = objid
    if not manifests:
        failures.append(f"package '{identity}' @ {revision[:12]} has no root Package*.swift -- "
                        f"refusing to trust a pin whose manifest cannot be located")

    record = {"identity": identity, "kind": pin["kind"], "location": location,
              "revision": revision, "tree": root_tree,
              "manifests": dict(sorted(manifests.items()))}
    for k in ("version", "branch"):
        if k in pin["state"]:
            record[k] = pin["state"][k]
    # Preserve a reviewer's free-text note across --update the same way components already
    # do (see the "entry.get('note', ...)" below): a package record is otherwise rebuilt from
    # scratch every run, so an unrelated pin bump elsewhere in the graph would silently drop
    # this package's note with no failure to catch it. Only carried forward if one already
    # exists -- this does not force "PENDING REVIEW" onto every package the way components
    # does, since most plain packages carry no note at all and never need one.
    prev_pkg = trusted_pkgs.get(identity)
    if prev_pkg and "note" in prev_pkg:
        record["note"] = prev_pkg["note"]
    pkg_records.append(record)

    if mode == "verify":
        prev = trusted_pkgs.get(identity)
        if prev is None:
            failures.append(
                f"NEW PACKAGE '{identity}' @ {revision[:12]} entered the resolved graph.\n"
                f"    location: {location}\n"
                f"    Every package in the graph can contribute a macro or build-tool plugin that\n"
                f"    runs on the build machine, and CI passes -skipPackagePluginValidation, so an\n"
                f"    unreviewed package is an unreviewed executable. It does not matter whether\n"
                f"    this one appears to declare a plugin: how a target is declared inside a\n"
                f"    manifest is not something this check relies on.\n"
                f"    " + RE_BLESS)
            continue
        if prev.get("location") != location:
            failures.append(f"package '{identity}': pin LOCATION changed\n"
                            f"    reviewed: {prev.get('location')}\n"
                            f"    resolved: {location}\n"
                            f"    " + RE_BLESS)
        if prev.get("revision") != revision:
            failures.append(f"package '{identity}': pinned REVISION moved\n"
                            f"    reviewed: {prev.get('revision')}\n"
                            f"    resolved: {revision}\n"
                            f"    A revision is a hash over the whole package tree, so this is an\n"
                            f"    arbitrary content change: new manifests, new plugins, new sources.\n"
                            f"    " + RE_BLESS)
        elif prev.get("tree") != root_tree:
            failures.append(f"package '{identity}': root TREE differs at the same revision\n"
                            f"    reviewed: {prev.get('tree')}\n"
                            f"    actual:   {root_tree}")
        prev_manifests = prev.get("manifests") or {}
        if prev_manifests != record["manifests"]:
            added = sorted(set(record["manifests"]) - set(prev_manifests))
            removed = sorted(set(prev_manifests) - set(record["manifests"]))
            changed = sorted(n for n in set(record["manifests"]) & set(prev_manifests)
                             if record["manifests"][n] != prev_manifests[n])
            detail = []
            for n in added:
                detail.append(f"      + {n} (new manifest, blob {record['manifests'][n][:12]})")
            for n in removed:
                detail.append(f"      - {n} (manifest removed)")
            for n in changed:
                detail.append(f"      ~ {n}: {prev_manifests[n][:12]} -> {record['manifests'][n][:12]}")
            failures.append(f"package '{identity}': package MANIFEST changed\n"
                            + "\n".join(detail) + "\n"
                            f"    A manifest is executable Swift and decides which targets -- including\n"
                            f"    macro and build-tool plugin targets -- are in the graph. Any change to\n"
                            f"    it must be read, in whatever form the declaration takes.\n"
                            f"    " + RE_BLESS)

if mode == "verify":
    for identity in sorted(set(trusted_pkgs) - {p["identity"] for p in pkg_records}):
        failures.append(f"reviewed package '{identity}' is NO LONGER in the resolved graph.\n"
                        f"    Not dangerous in itself, but it means package-trust.json no longer\n"
                        f"    describes the graph, and a stale trust file is not a reviewed one.\n"
                        f"    " + RE_BLESS)

    recorded_sha = graph_trust.get("resolved_sha256")
    if not graph_trust:
        failures.append("package-trust.json has NO 'graph' section.\n"
                        "    This file predates the graph-level binding and only records the\n"
                        "    macro/plugin components a regex could find, which is not a guarantee\n"
                        "    that no new plugin entered the graph.\n"
                        "    " + RE_BLESS)
    elif recorded_sha != resolved_sha:
        # Distinguish "the graph moved" from "only the file's bytes moved", because the fix
        # is the same command but the review needed is very different.
        if failures:
            failures.append(f"Package.resolved sha256 differs (see the specific changes above)\n"
                            f"    reviewed: {recorded_sha}\n"
                            f"    actual:   {resolved_sha}")
        else:
            failures.append(
                f"Package.resolved BYTES changed, though no package, pin, location or manifest\n"
                f"    did: this is a formatting or metadata-only edit (originHash, key order,\n"
                f"    whitespace). Still a failure -- the reviewed input is the file, not a\n"
                f"    summary of it -- but the review needed is a glance at `git diff`.\n"
                f"    reviewed: {recorded_sha}\n"
                f"    actual:   {resolved_sha}\n"
                f"    " + RE_BLESS)

# --------------------------------------------- 5: per-component review evidence (as before)
for pin, repo in fetched:
    identity = pin["identity"]
    revision = pin["state"]["revision"]
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
        entry = trusted_components.get((identity, name))
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
        component_records.append(record)

        if mode == "verify":
            if entry is None:
                failures.append(
                    f"UNREVIEWED {capability} '{name}' in package '{identity}' @ {revision[:12]}.\n"
                    f"    A macro or build-tool plugin runs code on the build machine. This one\n"
                    f"    entered the pinned graph without review.\n"
                    f"    " + RE_BLESS)
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

pkg_records.sort(key=lambda r: r["identity"])
component_records.sort(key=lambda r: (r["package"], r["name"]))

# ------------------------------------------------------------------------------- re-bless
if mode == "update":
    # Structural problems (a pin with no root manifest, a component whose sources cannot be
    # located) are collected even in update mode. Blessing over them silently would write a
    # trust file that cannot subsequently verify, so say so loudly first.
    for f in failures:
        print("  warning: " + f.splitlines()[0], file=sys.stderr)
    was = {p["identity"]: p for p in graph_trust.get("packages", [])}
    now = {p["identity"]: p for p in pkg_records}
    for i in sorted(set(now) - set(was)):
        print(f"  + package {i} @ {now[i]['revision'][:12]}  {now[i]['location']}")
    for i in sorted(set(was) - set(now)):
        print(f"  - package {i} (left the graph)")
    for i in sorted(set(was) & set(now)):
        if was[i].get("revision") != now[i]["revision"]:
            print(f"  ~ package {i}: {was[i].get('revision','?')[:12]} -> {now[i]['revision'][:12]}")
        elif was[i].get("manifests") != now[i]["manifests"]:
            print(f"  ~ package {i}: manifest set changed at the same revision")
    with open(trust_path, "w") as fh:
        json.dump({
            "_comment": "The reviewed build-time input of this fork. 'graph' binds the WHOLE "
                        "resolved package graph -- the exact set of pinned packages, each pin's "
                        "location and revision (a revision is a hash over that package's entire "
                        "tree), each package's root tree and root Package*.swift blob ids, and "
                        "sha256 of Package.resolved itself -- so a new package, a moved pin or a "
                        "changed manifest fails the check no matter how a target is declared "
                        "inside it. 'components' is additional review evidence: the macro/plugin "
                        "targets a regex can see, with the note recording what reading them found. "
                        "Regenerate with scripts/verify-package-trust.sh --update AFTER reading "
                        "what changed: the diff on this file IS the review record. "
                        "See FORK-PATCHES.md S6.",
            "graph": {
                "resolved_sha256": resolved_sha,
                "packages": pkg_records,
            },
            "components": component_records,
        }, fh, indent=2, sort_keys=False)
        fh.write("\n")
    print(f"wrote {trust_path}: {len(pkg_records)} pinned package(s), "
          f"{len(component_records)} reviewed macro/plugin component(s)")
    for r in component_records:
        print(f"  {r['capability']:9} {r['package']}/{r['name']}  {r['path']}  tree {r['tree'][:12]}")
    sys.exit(0)

# ---------------------------------------------------------------------------------- report
for pkg, name in sorted(set(trusted_components) - set(found)):
    print(f"  note: reviewed component {pkg}/{name} is no longer declared in the graph "
          f"(drop it with --update)")

print(f"resolved graph: {len(pkg_records)} pinned package(s), "
      f"Package.resolved sha256 {resolved_sha[:12]}")
print(f"reviewed macro/plugin component(s) located and hashed: {len(component_records)}")
for r in component_records:
    print(f"  {r['capability']:9} {r['package']}/{r['name']}  tree {r['tree'][:12]}")

if failures:
    print("\nerror: package trust check FAILED", file=sys.stderr)
    for f in failures:
        print("  " + f, file=sys.stderr)
    sys.exit(1)
print("OK: the resolved package graph is exactly the reviewed one "
      "(every pin, revision and manifest), and every reviewed component is unchanged")
PYEOF
