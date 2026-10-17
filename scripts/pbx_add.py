#!/usr/bin/env python3
"""Add Swift files (and the GRDB package) to AmachHealth.xcodeproj.

The project lists every file by hand, so new sources need a file reference,
a build file, a group entry and a Sources-phase entry. Idempotent: files that
are already referenced are skipped.

  python3 scripts/pbx_add.py app AmachHealth/Sources/Vault/Foo.swift ...
  python3 scripts/pbx_add.py test AmachHealth/Tests/FooTests.swift ...
  python3 scripts/pbx_add.py grdb
"""
import hashlib
import os
import re
import sys

PBX = os.path.join(os.path.dirname(__file__), "..", "AmachHealth.xcodeproj", "project.pbxproj")

APP_SOURCES_PHASE = "AA0000000000000000000200"
TEST_SOURCES_PHASE = "FF0000000000000000000300"
APP_SOURCES_GROUP = "AA0000000000000000000410"
TESTS_GROUP = "FF0000000000000000000400"
VAULT_GROUP = "5BABE2000000000000000000"
APP_TARGET = "AA0000000000000000000500"
APP_FRAMEWORKS_PHASE = "AA0000000000000000000300"
PROJECT = "AA0000000000000000000700"

GRDB_PKG = "5BABE2000000000000000A01"
GRDB_PRODUCT = "5BABE2000000000000000A02"
GRDB_BUILD = "5BABE2000000000000000A03"


def oid(seed: str) -> str:
    return "5BABE2" + hashlib.sha1(seed.encode()).hexdigest()[:18].upper()


def q(value: str) -> str:
    """Quote a plist string unless it only has characters plist allows bare."""
    return value if re.fullmatch(r"[A-Za-z0-9_./$]+", value) else f'"{value}"'


def insert_after(s: str, marker: str, text: str) -> str:
    i = s.index(marker) + len(marker)
    return s[:i] + text + s[i:]


def add_to_list(s: str, owner_id: str, list_name: str, entry: str) -> str:
    """Append `entry` into `list_name = ( ... );` inside the object `owner_id`."""
    m = re.search(rf"^\t\t{owner_id}( /\*.*?\*/)? = \{{", s, re.M)
    start = m.start()
    lst = s.index(f"{list_name} = (", start)
    close = s.index(");", lst)
    return s[:close] + f"\t{entry},\n\t\t\t" + s[close:]


def ensure_vault_group(s: str) -> str:
    if f"{VAULT_GROUP} /* Vault */ = {{" in s:
        return s
    group = (
        f"\t\t{VAULT_GROUP} /* Vault */ = {{\n"
        f"\t\t\tisa = PBXGroup;\n"
        f"\t\t\tchildren = (\n\t\t\t);\n"
        f"\t\t\tname = Vault;\n"
        f"\t\t\tsourceTree = \"<group>\";\n"
        f"\t\t}};\n"
    )
    s = insert_after(s, "/* Begin PBXGroup section */\n", group)
    return add_to_list(s, APP_SOURCES_GROUP, "children", f"{VAULT_GROUP} /* Vault */")


def add_file(s: str, path: str, kind: str) -> str:
    name = os.path.basename(path)
    if f"path = {q(path)};" in s:
        print(f"skip {path}")
        return s
    ref, build = oid("ref:" + path), oid("build:" + path)
    s = insert_after(
        s, "/* Begin PBXFileReference section */\n",
        f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
        f"name = {q(name)}; path = {q(path)}; sourceTree = SOURCE_ROOT; }};\n",
    )
    s = insert_after(
        s, "/* Begin PBXBuildFile section */\n",
        f"\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};\n",
    )
    if kind == "app":
        group = VAULT_GROUP if "/Sources/Vault/" in path else APP_SOURCES_GROUP
        phase = APP_SOURCES_PHASE
    else:
        group, phase = TESTS_GROUP, TEST_SOURCES_PHASE
    s = add_to_list(s, group, "children", f"{ref} /* {name} */")
    s = add_to_list(s, phase, "files", f"{build} /* {name} in Sources */")
    print(f"added {path}")
    return s


def add_grdb(s: str) -> str:
    if GRDB_PKG in s:
        print("skip GRDB")
        return s
    s = insert_after(
        s, "/* Begin PBXBuildFile section */\n",
        f"\t\t{GRDB_BUILD} /* GRDB in Frameworks */ = {{isa = PBXBuildFile; productRef = {GRDB_PRODUCT} /* GRDB */; }};\n",
    )
    s = add_to_list(s, APP_FRAMEWORKS_PHASE, "files", f"{GRDB_BUILD} /* GRDB in Frameworks */")
    s = add_to_list(s, APP_TARGET, "packageProductDependencies", f"{GRDB_PRODUCT} /* GRDB */")
    s = add_to_list(s, PROJECT, "packageReferences", f'{GRDB_PKG} /* XCRemoteSwiftPackageReference "GRDB.swift" */')
    s = insert_after(
        s, "/* Begin XCRemoteSwiftPackageReference section */\n",
        f'\t\t{GRDB_PKG} /* XCRemoteSwiftPackageReference "GRDB.swift" */ = {{\n'
        f"\t\t\tisa = XCRemoteSwiftPackageReference;\n"
        f'\t\t\trepositoryURL = "https://github.com/groue/GRDB.swift";\n'
        f"\t\t\trequirement = {{\n\t\t\t\tkind = upToNextMajorVersion;\n\t\t\t\tminimumVersion = 7.9.0;\n\t\t\t}};\n"
        f"\t\t}};\n",
    )
    s = insert_after(
        s, "/* Begin XCSwiftPackageProductDependency section */\n",
        f"\t\t{GRDB_PRODUCT} /* GRDB */ = {{\n"
        f"\t\t\tisa = XCSwiftPackageProductDependency;\n"
        f'\t\t\tpackage = {GRDB_PKG} /* XCRemoteSwiftPackageReference "GRDB.swift" */;\n'
        f"\t\t\tproductName = GRDB;\n"
        f"\t\t}};\n",
    )
    print("added GRDB")
    return s


def main() -> None:
    mode, paths = sys.argv[1], sys.argv[2:]
    with open(PBX) as f:
        s = f.read()
    if mode == "grdb":
        s = add_grdb(s)
    else:
        if mode == "app":
            s = ensure_vault_group(s)
        for p in paths:
            s = add_file(s, p, mode)
    with open(PBX, "w") as f:
        f.write(s)


if __name__ == "__main__":
    main()
