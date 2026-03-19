#!/usr/bin/env python3
"""
board-stage  [<dest_in_board>  <file1> [file2 ...]]
board-stage  --config/-c <config.xml>

No-arg form (reads ~/acms/board-stage for directories to process):
    board-stage.py

Positional form:
    board-stage.py usr/local/bin acms-network-setup.sh acms-portal.sh
    board-stage.py etc/systemd/system acms-network-setup.service

Config form (reads file list + destinations from XML):
    board-stage.py --config encryption/config.xml
    board-stage.py -c server_comm/config.xml

Config XML schema:
    <board-stage>
        <file src="filename" dest="path/in/board" [name="renamed_name"] />
        <dir  src="dirname"  dest="path/in/board" />
        ...
    </board-stage>

  <file>  src  — filename to locate (searched relative to the XML dir first, then ~/acms)
          dest — destination path inside ~/acms/board/
          name — optional rename; defaults to src filename

  <dir>   src  — directory path relative to the XML file's directory
          dest — destination path inside ~/acms/board/
                 all files directly inside src/ are staged (non-recursive)

board-stage conf file (~/acms/board-stage):
    One directory name per line (relative to ~/acms).
    Lines starting with # are ignored.
    Each listed directory must contain a config.xml.
"""

import sys
import shutil
import xml.etree.ElementTree as ET
from pathlib import Path

ACMS = Path.home() / "acms"
BOARD = ACMS / "board"
CONF_FILE = ACMS / "board-stage"


def find_file(name: str, search_root: Path = None) -> Path:
    """
    Search for *name* under search_root first (if given), then under ACMS.
    Excludes board/ from the search.
    """
    roots = []
    if search_root and search_root.is_dir() and search_root != BOARD:
        roots.append(search_root)
    if ACMS not in roots:
        roots.append(ACMS)

    seen = set()
    matches = []
    for root in roots:
        for p in root.rglob(name):
            if BOARD not in p.parents and p != BOARD and p not in seen:
                seen.add(p)
                matches.append(p)

    if not matches:
        raise FileNotFoundError(f"'{name}' not found under {ACMS}")
    if len(matches) > 1:
        paths = "\n  ".join(str(m) for m in matches)
        raise RuntimeError(
            f"'{name}' matched multiple files — be more specific:\n  {paths}"
        )
    return matches[0]


def stage(src_path: Path, dest_dir: Path, dest_name: str):
    dest_dir.mkdir(parents=True, exist_ok=True)
    dst = dest_dir / dest_name
    shutil.copy2(src_path, dst)
    print(f"  {src_path.relative_to(ACMS)}  →  board/{dest_dir.relative_to(BOARD)}/{dest_name}")


def run_config(config_path: Path):
    config_path = config_path.resolve()
    if not config_path.exists():
        print(f"ERROR: config file not found: {config_path}", file=sys.stderr)
        sys.exit(1)

    tree = ET.parse(config_path)
    root = tree.getroot()
    if root.tag != "board-stage":
        print(f"ERROR: root element must be <board-stage>, got <{root.tag}>", file=sys.stderr)
        sys.exit(1)

    xml_dir = config_path.parent
    for entry in root:
        src_attr  = entry.get("src")
        dest_rel  = entry.get("dest")

        if not src_attr or not dest_rel:
            print(f"ERROR: each <{entry.tag}> must have 'src' and 'dest' attributes",
                  file=sys.stderr)
            sys.exit(1)

        if entry.tag == "file":
            dest_name = entry.get("name", Path(src_attr).name)
            try:
                local = xml_dir / src_attr
                src_path = local if local.exists() else find_file(src_attr, xml_dir)
                stage(src_path, BOARD / dest_rel, dest_name)
            except (FileNotFoundError, RuntimeError) as e:
                print(f"ERROR: {e}", file=sys.stderr)
                sys.exit(1)

        elif entry.tag == "dir":
            src_dir = (xml_dir / src_attr).resolve()
            if not src_dir.is_dir():
                print(f"ERROR: directory not found: {src_dir}", file=sys.stderr)
                sys.exit(1)
            files = sorted(p for p in src_dir.iterdir() if p.is_file())
            if not files:
                print(f"  (no files in {src_attr}/)")
            for src_path in files:
                stage(src_path, BOARD / dest_rel, src_path.name)

        else:
            print(f"ERROR: unknown element <{entry.tag}> in {config_path}", file=sys.stderr)
            sys.exit(1)


def run_positional(dest_rel: str, file_names: list):
    dest_dir = BOARD / dest_rel
    for name in file_names:
        try:
            src = find_file(name)
            stage(src, dest_dir, src.name)
        except (FileNotFoundError, RuntimeError) as e:
            print(f"ERROR: {e}", file=sys.stderr)
            sys.exit(1)


def run_all():
    if not CONF_FILE.exists():
        print(f"ERROR: conf file not found: {CONF_FILE}", file=sys.stderr)
        print("  Create ~/acms/board-stage listing directories to stage.", file=sys.stderr)
        sys.exit(1)

    dirs = [
        line.strip()
        for line in CONF_FILE.read_text().splitlines()
        if line.strip() and not line.startswith("#")
    ]

    if not dirs:
        print(f"ERROR: {CONF_FILE} contains no directories", file=sys.stderr)
        sys.exit(1)

    errors = False
    for d in dirs:
        config_path = ACMS / d / "config.xml"
        print(f"\n[{d}]")
        if not config_path.exists():
            print(f"  ERROR: config.xml not found: {config_path}", file=sys.stderr)
            errors = True
            continue
        run_config(config_path)

    if errors:
        sys.exit(1)


def main():
    cwd = Path.cwd().resolve()
    if cwd != ACMS and ACMS not in cwd.parents:
        print(f"ERROR: board-stage must be run from inside {ACMS}", file=sys.stderr)
        sys.exit(1)

    args = sys.argv[1:]

    if not args:
        run_all()
    elif args[0] in ("--config", "-c"):
        if len(args) < 2:
            print("ERROR: --config/-c requires a path to a config.xml", file=sys.stderr)
            sys.exit(1)
        run_config(Path(args[1]))
    else:
        if len(args) < 2:
            print(__doc__)
            sys.exit(1)
        run_positional(args[0], args[1:])


if __name__ == "__main__":
    main()
