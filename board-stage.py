#!/usr/bin/env python3
"""
board-stage  [<dest_in_board>  <file1> [file2 ...]]
board-stage  --config/-c <config.xml>
board-stage  --default/-d

No-arg form (reads ~/acms/board-stage for directories to process):
    board-stage.py

Positional form:
    board-stage.py usr/local/bin acms-network-setup.sh acms-portal.sh
    board-stage.py etc/systemd/system acms-network-setup.service

Config form (reads file list + destinations from XML):
    board-stage.py --config encryption/config.xml
    board-stage.py -c server_comm/config.xml

Default form (full staging + auto-patch host WiFi + host IP):
    board-stage.py --default
    board-stage.py -d

  Runs full staging (same as no-arg), then patches board/ in-place:
    - board/etc/acms/default-wifi.conf  — adds host's current WiFi (SSID/password/BSSID)
    - board/etc/acms/server_details     — sets SERVER_URL to host's LAN IP

Config XML schema:
    <board-stage>
        <file src="filename" dest="path/in/board" [name="renamed_name"] />
        <dir  src="dirname"  dest="path/in/board" [exclude="file1,file2"] />
        ...
    </board-stage>

  <file>  src  — filename to locate (searched relative to the XML dir first, then ~/acms)
          dest — destination path inside ~/acms/board/
          name — optional rename; defaults to src filename

  <dir>   src  — directory path relative to the XML file's directory
          dest — destination path inside ~/acms/board/
                 all files directly inside src/ are staged (non-recursive)
          exclude — comma-separated filenames to skip

board-stage conf file (~/acms/board-stage):
    One directory name per line (relative to ~/acms).
    Lines starting with # are ignored.
    Each listed directory must contain a config.xml.
"""

import re
import sys
import shutil
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

ACMS = Path.home() / "acms"
BOARD = ACMS / "board"
OVERLAY = ACMS / "secure-build" / "armbian-build" / "userpatches" / "overlay"
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
    rel = dest_dir.relative_to(BOARD)
    print(f"  {src_path.relative_to(ACMS)}  →  board/{rel}/{dest_name}")

    # Mirror to armbian overlay if that path already exists there
    overlay_dst = OVERLAY / rel / dest_name
    if overlay_dst.exists():
        shutil.copy2(src_path, overlay_dst)
        print(f"  {src_path.relative_to(ACMS)}  →  overlay/{rel}/{dest_name}")


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
            excludes = {e.strip() for e in entry.get("exclude", "").split(",") if e.strip()}
            files = sorted(p for p in src_dir.iterdir() if p.is_file() and p.name not in excludes)
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


# ── --default helpers ──────────────────────────────────────────────────────────

def _get_host_wifi():
    """Return (ssid, password, bssid) of the host's active WiFi, or None."""
    try:
        out = subprocess.check_output(
            ['nmcli', '-t', '-f', 'ACTIVE,SSID,BSSID', 'dev', 'wifi', 'list'],
            text=True, stderr=subprocess.DEVNULL
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None

    for line in out.splitlines():
        if not line.startswith('yes:'):
            continue
        # nmcli -t escapes colons in values: "yes:SSID:AA\:BB\:CC\:DD\:EE\:FF"
        rest = line[4:]  # strip "yes:"
        # Split on unescaped colons only
        fields = re.split(r'(?<!\\):', rest)
        ssid  = fields[0].replace('\\:', ':')
        bssid = ':'.join(fields[1:]).replace('\\:', ':') if len(fields) > 1 else ''
        if not ssid or not bssid:
            continue

        # Get password via nmcli --show-secrets
        password = ''
        try:
            pw_out = subprocess.check_output(
                ['nmcli', '--show-secrets', '-t', '-f',
                 '802-11-wireless-security.psk', 'connection', 'show', ssid],
                text=True, stderr=subprocess.DEVNULL
            )
            for pw_line in pw_out.splitlines():
                if pw_line.startswith('802-11-wireless-security.psk:'):
                    password = pw_line.split(':', 1)[1]
                    break
        except (subprocess.CalledProcessError, FileNotFoundError):
            print("  [default] WARN: could not read WiFi password (permission denied?)")

        return ssid, password, bssid

    return None


def _get_host_lan_ip():
    """Return the host's outbound LAN IP (interface used to reach the internet)."""
    try:
        out = subprocess.check_output(
            ['ip', 'route', 'get', '8.8.8.8'],
            text=True, stderr=subprocess.DEVNULL
        )
        tokens = out.split()
        if 'src' in tokens:
            return tokens[tokens.index('src') + 1]
    except (subprocess.CalledProcessError, FileNotFoundError, IndexError):
        pass
    return None


def _patch_default_wifi(ssid: str, password: str, bssid: str):
    """Add or update host WiFi entry in default-wifi.conf (board + overlay).

    If the SSID already exists, updates the password but preserves the existing
    BSSID — the host may be on a different radio (e.g. 5 GHz) than the board
    (e.g. 2.4 GHz) and the BSSID should not be silently overwritten.
    If the SSID is new, appends a full entry using the host's BSSID.
    """
    new_content = None
    for wifi_file in [
        BOARD / 'etc' / 'acms' / 'default-wifi.conf',
        OVERLAY / 'etc' / 'acms' / 'default-wifi.conf',
    ]:
        if not wifi_file.exists():
            continue
        if new_content is None:
            lines = wifi_file.read_text().splitlines()
            new_lines = []
            updated = False
            for line in lines:
                if line.startswith('#') or not line.strip():
                    new_lines.append(line)
                    continue
                parts = line.split(',', 2)
                if parts[0].strip() == ssid:
                    # SSID found — update password, preserve BSSID
                    existing_bssid = parts[2].strip() if len(parts) > 2 else bssid
                    new_lines.append(f"{ssid},{password},{existing_bssid}")
                    if existing_bssid != bssid:
                        print(f"  [default] NOTE: kept existing BSSID {existing_bssid} for '{ssid}' (host is on {bssid})")
                    updated = True
                else:
                    new_lines.append(line)
            if not updated:
                # New SSID — append with host BSSID
                while new_lines and not new_lines[-1].strip():
                    new_lines.pop()
                new_lines.append(f"{ssid},{password},{bssid}")
            new_content = '\n'.join(new_lines) + '\n'
        wifi_file.write_text(new_content)
        label = "board" if BOARD in wifi_file.parents else "overlay"
        print(f"  [default] default-wifi.conf ({label})  ← {ssid} updated")

    if new_content is None:
        print(f"  [default] WARN: default-wifi.conf not found in board/ or overlay/ — skipping WiFi patch")


def _patch_server_details(lan_ip: str):
    """Update SERVER_URL in server_details with the host's LAN IP (board + overlay)."""
    new_content = None
    for details_file in [
        BOARD / 'etc' / 'acms' / 'server_details',
        OVERLAY / 'etc' / 'acms' / 'server_details',
    ]:
        if not details_file.exists():
            continue
        lines = details_file.read_text().splitlines()
        new_lines = []
        for line in lines:
            if line.startswith('SERVER_URL='):
                m = re.match(r'SERVER_URL=https?://[^:/]+(:\d+)?(/.*)?', line)
                port = m.group(1) or ':8000' if m else ':8000'
                path = m.group(2) or ''      if m else ''
                line = f"SERVER_URL=http://{lan_ip}{port}{path}"
            new_lines.append(line)
        new_content = '\n'.join(new_lines) + '\n'
        details_file.write_text(new_content)
        label = "board" if BOARD in details_file.parents else "overlay"
        print(f"  [default] server_details ({label})  ← SERVER_URL=http://{lan_ip}:8000")

    if new_content is None:
        print(f"  [default] WARN: server_details not found in board/ or overlay/ — skipping server IP patch")


def run_default():
    """Full staging + auto-patch host WiFi and LAN IP into board/."""
    run_all()

    print("\n[default patches]")

    wifi = _get_host_wifi()
    if wifi:
        _patch_default_wifi(*wifi)
    else:
        print("  [default] WARN: no active WiFi connection found — skipping WiFi patch")

    lan_ip = _get_host_lan_ip()
    if lan_ip:
        _patch_server_details(lan_ip)
    else:
        print("  [default] WARN: could not determine LAN IP — skipping server IP patch")


# ── main ───────────────────────────────────────────────────────────────────────

def main():
    cwd = Path.cwd().resolve()
    if cwd != ACMS and ACMS not in cwd.parents:
        print(f"ERROR: board-stage must be run from inside {ACMS}", file=sys.stderr)
        sys.exit(1)

    args = sys.argv[1:]

    if not args:
        run_all()
    elif args[0] in ("--default", "-d"):
        run_default()
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
