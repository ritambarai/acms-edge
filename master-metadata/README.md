# ACMS Metadata

A local server for system integrators to initiate a new ACMS project — create a metadata XML file and link it with an edge board ID.

## Files

| File | Description |
|------|-------------|
| `server.py` | Local HTTP server with REST API (`/api/files`, `/api/load`, `/api/save`) |
| `index.html` | Metadata editor UI |
| `style.css` | Stylesheet for the UI |
| `app.js` | Frontend logic |
| `config.xml` | Configuration metadata |
| `field_value.xml` | Field value definitions |

## Usage

```bash
python3 server.py          # runs on port 8000
python3 server.py 9000     # custom port
```

Then open `http://localhost:8000` in your browser.
