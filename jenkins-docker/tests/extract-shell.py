#!/usr/bin/env python3
"""Print the text of a Jenkins job's build steps, unescaped, for linting and tests.

usage: extract-shell.py CONFIG_XML [--groovy] [--index N]

  (default)   the <command> of the N-th hudson.tasks.Shell step (default 0)
  --groovy    the source of the N-th SystemGroovy step instead
"""
import sys
import xml.etree.ElementTree as ET


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__, file=sys.stderr)
        return 2
    path = argv[0]
    groovy = "--groovy" in argv
    index = 0
    if "--index" in argv:
        index = int(argv[argv.index("--index") + 1])

    root = ET.parse(path).getroot()
    if groovy:
        # <SystemGroovy><source><script plugin=..><script>CODE</script>...
        found = [e.text or "" for e in root.findall(".//builders/hudson.plugins.groovy.SystemGroovy/source/script/script")]
    else:
        found = [e.text or "" for e in root.findall(".//builders/hudson.tasks.Shell/command")]
    if index >= len(found):
        print(f"{path}: no step #{index} (found {len(found)})", file=sys.stderr)
        return 1
    sys.stdout.write(found[index])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
