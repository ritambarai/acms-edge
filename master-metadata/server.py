#!/usr/bin/env python3
"""
ACMS Metadata local server.

Serves the page and provides three API endpoints:
  GET  /api/files            -> JSON list of .xml files in this directory
  GET  /api/load/<filename>  -> raw XML content of that file
  POST /api/save             -> writes JSON {filename, content} to this directory

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

DIR = Path(__file__).resolve().parent


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
    print('Press Ctrl+C to stop.')
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\nStopped.')
