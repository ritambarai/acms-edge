#!/usr/bin/env python3
"""
ACMS Metadata local server.

Serves the page and provides API endpoints:
  GET  /api/files            -> JSON list of .xml files in this directory
  GET  /api/load/<filename>  -> raw XML content of that file
  POST /api/save             -> writes JSON {filename, content} to this directory
  POST /api/state            -> receives board state from send_state

/api/state payload (from send_state):
  {"stateCode": <uint>, "args": [...], "kwargs": {...}}

  stateCode is resolved to a state name via state_table.
  State-specific logic is applied (e.g. Board_Registration saves coreId).
  Response always includes the next stateCode for the board to advance to.

Device state is persisted to devices.json keyed by coreId.

Run:
    python3 server.py          # default port 8000
    python3 server.py 9000     # custom port
"""

import json
import sys
import os
from http.server import HTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from urllib.parse import unquote
from datetime import datetime, timezone

DIR = Path(__file__).resolve().parent


# ── state_table loader ─────────────────────────────────────────────────────────

def load_state_table():
    """
    Parse state_table into two dicts:
      code_to_name: {2: 'Board_Registration', ...}
      name_to_code: {'Board_Registration': 2, ...}
    Ordered list of codes preserved for next-state lookup.
    """
    path = DIR / 'state_table'
    code_to_name, name_to_code, ordered_codes = {}, {}, []
    if not path.exists():
        return code_to_name, name_to_code, ordered_codes

    section = None
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if line.startswith('['):
            section = line.strip('[]')
            continue
        if '=' not in line:
            continue
        key, _, val = line.partition('=')
        key, val = key.strip(), val.strip()
        if section == 'stateCode' and val.isdigit():
            code = int(val)
            code_to_name[code] = key
            name_to_code[key]  = code
            ordered_codes.append(code)

    return code_to_name, name_to_code, ordered_codes


CODE_TO_NAME, NAME_TO_CODE, ORDERED_CODES = load_state_table()


def next_state_code(current_code):
    """Return the next stateCode in sequence, or the current one if already last."""
    try:
        idx = ORDERED_CODES.index(current_code)
        return ORDERED_CODES[idx + 1] if idx + 1 < len(ORDERED_CODES) else current_code
    except ValueError:
        return current_code


class Handler(SimpleHTTPRequestHandler):

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(DIR), **kwargs)

    # ── routing ───────────────────────────────────────────────────────────────

    def do_GET(self):
        if self.path == '/favicon.ico':
            self._respond(204, 'text/plain', b'')
        elif self.path == '/api/files':
            self._api_files()
        elif self.path.startswith('/api/load/'):
            name = unquote(self.path[len('/api/load/'):])
            self._api_load(name)
        else:
            super().do_GET()

    def do_POST(self):
        if self.path == '/api/save':
            self._api_save()
        elif self.path == '/api/state':
            self._api_state()
        else:
            self._respond(404, 'text/plain', b'Not found')

    # ── handlers ──────────────────────────────────────────────────────────────

    def _api_files(self):
        files = sorted(p.name for p in DIR.glob('*.xml'))
        self._json(files)

    def _api_load(self, name):
        path = (DIR / name).resolve()
        if path.parent != DIR or path.suffix.lower() != '.xml':
            self._respond(400, 'text/plain', b'Invalid filename')
            return
        if not path.exists():
            self._respond(404, 'text/plain', b'File not found')
            return
        self._respond(200, 'application/xml', path.read_bytes())

    def _api_save(self):
        try:
            length = int(self.headers.get('Content-Length', 0))
            body   = self.rfile.read(length)
            data   = json.loads(body)
        except Exception as e:
            self._respond(400, 'text/plain', f'Bad request: {e}'.encode())
            return

        fname = str(data.get('filename', '')).strip()
        content = str(data.get('content', ''))

        if not fname or not fname.lower().endswith('.xml'):
            self._respond(400, 'text/plain', b'filename must end in .xml')
            return

        path = (DIR / fname).resolve()
        if path.parent != DIR:
            self._respond(400, 'text/plain', b'Invalid path')
            return

        path.write_text(content, encoding='utf-8')
        self._json({'ok': True, 'saved': fname})

    def _api_state(self):
        try:
            length = int(self.headers.get('Content-Length', 0))
            body   = self.rfile.read(length)
            data   = json.loads(body)
        except Exception as e:
            self._respond(400, 'text/plain', f'Bad request: {e}'.encode())
            return

        state_code = data.get('stateCode')
        kwargs     = data.get('kwargs', {})
        args       = data.get('args', [])

        if state_code is None:
            self._respond(400, 'text/plain', b'stateCode required')
            return

        state_name = CODE_TO_NAME.get(state_code, f'Unknown({state_code})')
        core_id    = str(kwargs.get('CoreID', '')).strip()
        if not core_id:
            self._respond(400, 'text/plain', b'CoreID required in kwargs')
            return

        now = datetime.now(timezone.utc).isoformat()
        ip  = self.client_address[0]

        devices_path = DIR / 'devices.json'
        devices = json.loads(devices_path.read_text()) if devices_path.exists() else {}
        device  = devices.get(core_id, {'coreId': core_id})

        if state_name == 'Board_Registration':
            device.update({
                'coreId':        core_id,
                'hostname':      str(kwargs.get('hostname',   '')),
                'macAddress':    str(kwargs.get('macAddress', '')),
                'ip':            ip,
                'registered_at': device.get('registered_at', now),
                'last_seen':     now,
            })
            print(f'[{state_name}]  coreId={core_id}  ip={ip}  hostname={device["hostname"]}')
        else:
            device['last_seen'] = now
            device['ip']        = ip
            print(f'[{state_name}]  coreId={core_id}  ip={ip}')

        device['last_state'] = {
            'stateCode':   state_code,
            'stateName':   state_name,
            'args':        args,
            'kwargs':      kwargs,
            'received_at': now,
        }

        devices[core_id] = device
        devices_path.write_text(json.dumps(devices, indent=2))

        next_sc = next_state_code(state_code)
        self._json({'ok': True, 'coreId': core_id, 'stateCode': next_sc})

    # ── helpers ───────────────────────────────────────────────────────────────

    def _json(self, data):
        body = json.dumps(data).encode()
        self._respond(200, 'application/json', body)

    def _respond(self, code, ctype, body: bytes):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        # only log API calls; suppress static file noise
        first = str(args[0]) if args else ''
        if '/api/' in first:
            super().log_message(fmt, *args)

if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
    server = HTTPServer(('', port), Handler)
    print(f'ACMS Metadata server running at  http://localhost:{port}')
    print(f'Serving files from: {DIR}')
    print(f'States loaded: { {c: CODE_TO_NAME[c] for c in ORDERED_CODES} }')
    print('Press Ctrl+C to stop.')
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\nStopped.')
