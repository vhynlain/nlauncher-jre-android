#!/usr/bin/env python3
"""NLauncher launcher change (nl-0007): the `java` launcher honours $NLAUNCHER_JAVA_HOME.

Android 10+ only lets an app execute files from its native library directory, so the app ships bin/java as lib<name>.so there. The
launcher normally derives the JRE from its own location (/proc/self/exe, two levels up) and would not find lib/libjava.so. With this
change, GetApplicationHome() returns $NLAUNCHER_JAVA_HOME when it is set; nothing changes when it is not.

This is a script instead of a .patch file because `git apply` (no fuzz) needs the exact surrounding lines of the upstream file; the
script anchors on the function signature and fails loudly when upstream changes it. Run by apply-patches.sh after the series.

Usage: patch-launcher-home.py <jdk source tree>
"""
import os, re, sys

MARK = "NLAUNCHER_JAVA_HOME"
SNIPPET = '''
    {   /* NLauncher: the app runs the launcher from its native library directory (see scripts/patch-launcher-home.py) */
        const char *nl_home = getenv("NLAUNCHER_JAVA_HOME");
        if (nl_home != NULL && nl_home[0] != '\\0' && strlen(nl_home) < (size_t) bufsize) {
            snprintf(buf, bufsize, "%s", nl_home);
            return JNI_TRUE;
        }
    }
'''
SIGNATURE = re.compile(r'(\bGetApplicationHome\s*\(\s*char\s*\*\s*buf\s*,\s*jint\s+bufsize\s*\)\s*\{)')
INCLUDES = "#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n"

def main():
    root = sys.argv[1]
    directory = os.path.join(root, "src/java.base/unix/native/libjli")
    if not os.path.isdir(directory):
        sys.exit("not a jdk source tree (missing %s)" % directory)
    hits = []
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".c"):
            continue
        path = os.path.join(directory, name)
        text = open(path, encoding="utf-8").read()
        if SIGNATURE.search(text):
            hits.append((path, text))
    if len(hits) != 1:
        sys.exit("expected GetApplicationHome in exactly one file of %s, found %d" % (directory, len(hits)))
    path, text = hits[0]
    if MARK in text:
        print("already patched: " + path); return
    text = SIGNATURE.sub(lambda m: m.group(1) + SNIPPET, text, count=1)
    first_include = re.search(r'^#include[^\n]*\n', text, re.M)
    if not first_include:
        sys.exit("no #include found in " + path)
    text = text[:first_include.start()] + INCLUDES + text[first_include.start():]
    open(path, "w", encoding="utf-8").write(text)
    print("patched " + path)

main()
