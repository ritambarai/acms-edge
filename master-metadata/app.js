/*
 * ACMS Metadata Editor — frontend
 *
 * Talks to server.py via:
 *   GET  /api/files            → JSON array of .xml filenames in the server dir
 *   GET  /api/load/<filename>  → raw XML content
 *   POST /api/save             → JSON {filename, content}  →  writes file to server dir
 *
 * Data structure:
 *   rowList    — flat [{class, key, value}] in insertion order (drives the table)
 *   metaDict   — {ClassName: dict} for ROOT classes only (drives XML output)
 *   classDicts — {ClassName: dict} for ALL classes (root + config-hierarchy-nested)
 *
 * Config-hierarchy-derived nested classes (e.g. PLC1 under PLC/slave) live only
 * in classDicts and are inlined in the XML; they never appear as top-level metaDict
 * keys. inlinedClasses tracks which class names are nested.
 */

// ── state ─────────────────────────────────────────────────────────────────────
let metaDict   = {};   // ROOT classes only (not config-hierarchy-derived nested classes)
let classDicts = {};   // ALL classes (root + nested) — authoritative dict store

let rowList     = [];   // [{class, key, value}, ...]
let dirty       = false;
let pendingLoad = null;
let pendingEdit = null;   // {class, key, value} of row being edited — deleted only on re-insert

// Config-driven dropdown state
let configTree             = {};        // {className: {keys:[{name, subkeys:[]}]}}
let classInheritedKeys     = {};        // {className: string[]} — key names inherited when used as a value
let classInheritedKeyDefs  = {};        // {className: [{name, subkeys}]} — full defs (for deeper nesting)
let inlinedClasses         = new Set(); // class names that live nested inside a parent (never top-level)
let entrySubkeyClasses     = new Set(); // classes whose config keys apply to their entry values, not to the class itself

// ── boot ──────────────────────────────────────────────────────────────────────
window.addEventListener('DOMContentLoaded', async () => {
  document.getElementById('modal-save-btn')  .addEventListener('click', modalSave);
  document.getElementById('modal-nosave-btn').addEventListener('click', modalNoSave);
  document.getElementById('modal-cancel-btn').addEventListener('click', modalCancel);

  await loadConfig();
  await refreshDropdown();

  // Always load from the server file; fall back to localStorage if unavailable
  const fname = getFilename();
  try {
    const res = await fetch('/api/load/' + encodeURIComponent(fname));
    if (res.ok) {
      localStorage.removeItem('acms_metadata_rows');   // clear stale data before fresh load
      parseXML(await res.text());
      saveToLocalStorage();
    } else {
      loadFromLocalStorage();
    }
  } catch (_) {
    loadFromLocalStorage();
  }

  renderTable();
  markClean();
});

// ── CONFIG ────────────────────────────────────────────────────────────────────
async function loadConfig() {
  try {
    const res = await fetch('/api/load/config.xml');
    if (res.ok) parseConfig(await res.text());
  } catch (_) { /* config optional */ }
}

function parseConfig(xmlStr) {
  const doc = new DOMParser().parseFromString(xmlStr, 'application/xml');
  configTree = {};
  entrySubkeyClasses = new Set();
  doc.querySelectorAll('Config > class').forEach(clsEl => {
    const cls = clsEl.getAttribute('name');
    if (!cls) return;
    configTree[cls] = { keys: parseKeyEls(clsEl) };
    if (clsEl.getAttribute('entry-subkeys') === 'true') entrySubkeyClasses.add(cls);
  });
  updateClassDatalist();
}

// Recursively parse <key> children of an element into [{name, subkeys:[]}]
function parseKeyEls(parentEl) {
  return Array.from(parentEl.children)
    .filter(el => el.tagName === 'key')
    .map(el => ({ name: el.getAttribute('name'), subkeys: parseKeyEls(el) }))
    .filter(k => k.name);
}

// Populate Class datalist: config-defined classes first, then any dynamically
// discovered classes (values that were used as class names during entry).
function updateClassDatalist() {
  const dl = document.getElementById('class-list');
  if (!dl) return;
  dl.innerHTML = '';
  const seen = new Set();
  // Config-defined classes (known hierarchy roots + option-less root classes)
  Object.keys(configTree).forEach(cls => {
    seen.add(cls);
    const opt = document.createElement('option');
    opt.value = cls;
    dl.appendChild(opt);
  });
  // Dynamically discovered classes from loaded/entered data
  Object.keys(classDicts).forEach(cls => {
    if (!seen.has(cls)) {
      seen.add(cls);
      const opt = document.createElement('option');
      opt.value = cls;
      dl.appendChild(opt);
    }
  });
}

// Switch Key field between a <select> (when config options exist) and free <input>.
function updateKeyField(cls) {
  const inp  = document.getElementById('inp-key');
  const sel  = document.getElementById('sel-key');
  const opts = getKeyOptionsForClass(cls);
  if (!inp || !sel) return;

  if (opts.length > 0) {
    inp.style.display = 'none';
    sel.innerHTML = '<option value="">— select key —</option>';
    opts.forEach(k => {
      const opt = document.createElement('option');
      opt.value = opt.textContent = k;
      sel.appendChild(opt);
    });
    sel.style.display = '';
  } else {
    sel.style.display = 'none';
    inp.style.display = '';
  }
  document.getElementById('err-key').textContent = '';
  updateValueField('');   // reset value datalist and clear hint when key options change
}

// Returns key names for a class: direct from config, or inherited via sub-keys.
// entry-subkey classes suppress their own config keys from the dropdown (those
// keys apply to the class's entry values, not to the class itself).
function getKeyOptionsForClass(cls) {
  if (configTree[cls] && !entrySubkeyClasses.has(cls)) return configTree[cls].keys.map(k => k.name);
  if (classInheritedKeys[cls]) return classInheritedKeys[cls];
  return [];
}

// Return the key definition ({name, subkeys}) for ownerCls/keyName.
// Also checks sub-keys inherited by ownerCls (classInheritedKeyDefs).
function getKeyDef(ownerCls, keyName) {
  const keys = configTree[ownerCls]?.keys
             ?? classInheritedKeyDefs[ownerCls]
             ?? [];
  return keys.find(k => k.name === keyName) ?? null;
}

// ── helpers ───────────────────────────────────────────────────────────────────
function getFilename() {
  return document.getElementById('inp-filename').value.trim();
}

function focusNext(id) { document.getElementById(id).focus(); }

function focusKeyField() {
  const sel = document.getElementById('sel-key');
  if (sel && sel.style.display !== 'none') sel.focus();
  else document.getElementById('inp-key').focus();
}

function getKeyValue() {
  const sel = document.getElementById('sel-key');
  if (sel && sel.style.display !== 'none') return sel.value.trim();
  return document.getElementById('inp-key').value.trim();
}

function setKeyValue(v) {
  const sel = document.getElementById('sel-key');
  if (sel && sel.style.display !== 'none') sel.value = v;
  else document.getElementById('inp-key').value = v;
}

// ── INSERT ────────────────────────────────────────────────────────────────────
function insertEntry() {
  const cls = document.getElementById('inp-class').value.trim();
  const key = getKeyValue();
  const val = document.getElementById('inp-value').value.trim();

  clearEntryErrors();
  let hasErr = false;
  if (!cls) { showError('err-class', 'Required'); hasErr = true; }
  if (!key) { showError('err-key',   'Required'); hasErr = true; }
  if (!val) { showError('err-value', 'Required'); hasErr = true; }
  if (hasErr) return;

  // If editing an existing row, remove the old entry first then rebuild before inserting
  if (pendingEdit) {
    const ri = rowList.findIndex(r => r.class === pendingEdit.class && r.key === pendingEdit.key && r.value === pendingEdit.value);
    if (ri !== -1) rowList.splice(ri, 1);
    pendingEdit = null;
    const snap = rowList.slice();
    metaDict = {}; classDicts = {}; rowList = []; classInheritedKeys = {}; classInheritedKeyDefs = {}; inlinedClasses = new Set();
    snap.forEach(r => addEntry(r.class, r.key, r.value));
  }

  addEntry(cls, key, val);
  saveToLocalStorage();
  renderTable();
  markDirty();

  document.getElementById('inp-class').value = '';
  setKeyValue('');
  document.getElementById('inp-value').value = '';
  clearValueHint();
  document.getElementById('inp-class').focus();

  console.log('metaDict:', JSON.parse(JSON.stringify(metaDict)));
}

// ── SAVE (POST to server) ─────────────────────────────────────────────────────
async function saveXML() {
  const fname = getFilename();
  clearFilenameError();
  if (!fname) { showError('err-filename', 'Required'); return; }

  const xml = buildXML();
  localStorage.setItem('acms_metadata_xml', xml);

  try {
    const res = await fetch('/api/save', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ filename: fname, content: xml })
    });
    if (!res.ok) throw new Error(await res.text());
    markClean();
    setStatus('Saved → ' + fname, false);
    await refreshDropdown();
  } catch (e) {
    setStatus('Save failed: ' + e.message, true);
    console.error(e);
  }
}

// ── DROPDOWN: list XMLs from server ──────────────────────────────────────────
async function refreshDropdown() {
  try {
    const res   = await fetch('/api/files');
    if (!res.ok) return;
    const files = await res.json();
    const sel   = document.getElementById('xml-dropdown');
    while (sel.options.length > 1) sel.remove(1);
    files.filter(n => n !== 'config.xml').forEach(name => {
      const opt = document.createElement('option');
      opt.value = opt.textContent = name;
      sel.appendChild(opt);
    });
  } catch (_) { /* server might not be up yet */ }
}

function handleDropdownSelect(sel) {
  const name = sel.value;
  sel.value = '';
  if (!name) return;

  const doLoad = async () => {
    try {
      const res = await fetch('/api/load/' + encodeURIComponent(name));
      if (!res.ok) throw new Error(await res.text());
      const text = await res.text();
      parseXML(text);
      document.getElementById('inp-filename').value = name;
      saveToLocalStorage();
      renderTable();
      markClean();
      setStatus('Loaded ' + name, false);
    } catch (e) {
      setStatus('Load failed: ' + e.message, true);
      console.error(e);
    }
  };

  dirty ? showModal(doLoad) : doLoad();
}

// ── FILE UPLOAD (browse button, works offline too) ────────────────────────────
function handleFileUpload(e) {
  const file = e.target.files[0];
  if (!file) return;
  e.target.value = '';

  const doLoad = () => {
    const reader = new FileReader();
    reader.onload = ev => {
      parseXML(ev.target.result);
      document.getElementById('inp-filename').value = file.name;
      saveToLocalStorage();
      renderTable();
      markClean();
      setStatus('Loaded ' + file.name, false);
    };
    reader.readAsText(file);
  };

  dirty ? showModal(doLoad) : doLoad();
}

// ── CORE: metaDict builder ────────────────────────────────────────────────────
function addEntry(cls, key, val) {
  const isNew = !(cls in classDicts);
  ensureClass(cls);

  rowList.push({ class: cls, key, value: val });
  const d = classDicts[cls];
  if (key in d) {
    const ex = d[key];
    d[key] = Array.isArray(ex) ? [...ex, val] : [ex, val];
  } else {
    d[key] = val;
  }

  mergeValueAsClass(cls, key, val);   // embed val's dict if val is a class (config-driven)
  if (isNew) mergeClassAsValue(cls);  // retroactively embed this new class wherever it appears as a value
  registerInheritedKeys(cls, key, val); // propagate config sub-keys to val
}

function ensureClass(cls) {
  if (!(cls in classDicts)) {
    classDicts[cls] = {};
    // Only root classes go into metaDict; nested classes live only in classDicts
    if (!inlinedClasses.has(cls)) metaDict[cls] = classDicts[cls];
  }
}

// When a value equals a class name, embed that class's dict next to the scalar.
// e.g. PLC.slave = 'PLC1'  →  PLC.slave = ['PLC1', PLC1_dict]
function mergeValueAsClass(ownerCls, key, val) {
  if (!(val in classDicts)) return;
  if (val === ownerCls) return;   // prevent self-embedding (e.g. fn_name="Digital Inputs" inside Digital Inputs)
  // Leaf keys in config are plain references (e.g. variable/Card, variable/Fault_Code) — don't embed
  const keyDef = getKeyDef(ownerCls, key);
  if (keyDef && keyDef.subkeys.length === 0) return;
  const d         = classDicts[ownerCls];
  const current   = d[key];
  const nestedDict = classDicts[val];
  if (current === nestedDict) return;
  if (Array.isArray(current)) {
    if (current.includes(nestedDict)) return;  // already embedded
    // Insert nestedDict right after the last occurrence of val as a string
    const idx = current.lastIndexOf(val);
    if (idx === -1) return;
    d[key] = [...current.slice(0, idx + 1), nestedDict, ...current.slice(idx + 1)];
  } else if (typeof current === 'string' && current === val) {
    d[key] = [val, nestedDict];
  }
}

// When a new class is added, embed its dict wherever its name appears as a value.
function mergeClassAsValue(cls) {
  for (const ownerCls of Object.keys(classDicts)) {
    if (ownerCls === cls) continue;
    const d = classDicts[ownerCls];
    for (const key of Object.keys(d)) {
      const v = d[key];
      const scalars = typeof v === 'string' ? [v] : (Array.isArray(v) ? v.filter(s => typeof s === 'string') : []);
      if (scalars.includes(cls)) mergeValueAsClass(ownerCls, key, cls);
    }
  }
}

// If a key has sub-keys in config (or inherited), register val as a nested
// (inlined) class that inherits those sub-keys as its key options.
// Also handles entry-subkey classes: any value added to such a class inherits
// the class's own config keys (e.g. Card → every card name inherits fn_id, fn_name, etc.)
function registerInheritedKeys(ownerCls, key, val) {
  const keyDef = getKeyDef(ownerCls, key);

  // Resolve which sub-keys apply to val
  let subkeys = null;
  if (keyDef && keyDef.subkeys.length > 0) {
    subkeys = keyDef.subkeys;                          // explicit sub-keys on this key
  } else if (entrySubkeyClasses.has(ownerCls) && configTree[ownerCls]) {
    subkeys = configTree[ownerCls].keys;               // class-level entry sub-keys
  }
  if (!subkeys) return;

  // Mark val as a nested class — remove from metaDict if already added there
  inlinedClasses.add(val);
  if (val in metaDict) delete metaDict[val];

  // Store full defs so deeper nesting resolves correctly
  if (!classInheritedKeyDefs[val]) classInheritedKeyDefs[val] = [];
  subkeys.forEach(sk => {
    if (!classInheritedKeyDefs[val].find(d => d.name === sk.name))
      classInheritedKeyDefs[val].push(sk);
  });

  // Store names for the datalist
  if (!classInheritedKeys[val]) classInheritedKeys[val] = [];
  subkeys.forEach(sk => {
    if (!classInheritedKeys[val].includes(sk.name)) classInheritedKeys[val].push(sk.name);
  });

  // Refresh key datalist if this class is currently selected in the form
  const selCls = document.getElementById('inp-class')?.value.trim();
  if (selCls === val) updateKeyField(val);
}

// ── VALUE LOOKUP (green hint when value matches a key in the key's class) ────
// When Key field = a class name (e.g. "Fault_Code"), populate val-list datalist
// with that class's keys. When the typed value matches a key, show the
// corresponding value as a green hint in the err-value span.

function updateValueField(keyName) {
  const dl = document.getElementById('val-list');
  if (dl) {
    dl.innerHTML = '';
    const seen = new Set();

    // Existing values for this key in the current class
    // e.g. class=Card key=name → shows "Card1", "Card2", ...
    const currentCls = document.getElementById('inp-class')?.value.trim();
    if (currentCls && classDicts[currentCls]) {
      const existing = classDicts[currentCls][keyName];
      const existingScalars = typeof existing === 'string' ? [existing]
                            : Array.isArray(existing) ? existing.filter(v => typeof v === 'string') : [];
      existingScalars.forEach(s => {
        seen.add(s);
        const opt = document.createElement('option');
        opt.value = s;
        dl.appendChild(opt);
      });
    }

    // If keyName itself names a class: its keys (e.g. Fault_Code → "101", "201")
    // and any inlined instance names stored as values (e.g. PLC → "PLC1")
    const d = classDicts[keyName];
    if (d) {
      Object.keys(d).forEach(k => {
        if (!seen.has(k)) {
          seen.add(k);
          const opt = document.createElement('option');
          opt.value = k;
          dl.appendChild(opt);
        }
      });
      Object.values(d).forEach(val => {
        const scalars = typeof val === 'string' ? [val]
                      : Array.isArray(val) ? val.filter(v => typeof v === 'string') : [];
        scalars.filter(s => inlinedClasses.has(s) && !seen.has(s)).forEach(s => {
          seen.add(s);
          const opt = document.createElement('option');
          opt.value = s;
          dl.appendChild(opt);
        });
      });
    }
  }
  clearValueHint();
}

function checkValueLookup() {
  const keyName  = getKeyValue();
  const valInp   = document.getElementById('inp-value');
  const errSpan  = document.getElementById('err-value');
  if (!valInp) return;
  const typedVal = valInp.value.trim();
  const d        = classDicts[keyName];
  if (!d || !typedVal) { clearValueHint(); return; }

  let label = null;

  if (typedVal in d) {
    // Direct key lookup (e.g. Fault_Code: user types "101" → shows "Fault")
    const match = d[typedVal];
    label = scalarsOf(match)[0] ?? String(match);
  } else if (inlinedClasses.has(typedVal) && classDicts[typedVal]) {
    // Inlined instance lookup (e.g. Card: user types "Digital Inputs" → show its fn_id)
    const instDict = classDicts[typedVal];
    const firstVal = Object.values(instDict)[0];
    label = scalarsOf(firstVal)[0] ?? String(firstVal ?? typedVal);
  }

  if (label !== null) {
    valInp.style.border = '2px solid green';
    valInp.classList.remove('invalid');
    if (errSpan) { errSpan.textContent = label.toUpperCase(); errSpan.style.color = 'green'; }
  } else {
    clearValueHint();
  }
}

function clearValueHint() {
  const valInp  = document.getElementById('inp-value');
  const errSpan = document.getElementById('err-value');
  if (valInp?.style.border === '2px solid green') valInp.style.border = '';
  if (errSpan?.style.color === 'green') { errSpan.textContent = ''; errSpan.style.color = ''; }
}

// ── XML — nested format mirroring metaDict ───────────────────────────────────
//
// Classes whose name appears as a VALUE or as a key-matching class inside
// another class are inlined as child <entry> elements and NOT emitted as
// standalone <class> elements, so each class appears exactly once.
//
// <Metadata>
//   <class name="Fault_Code">
//     <entry key="Fault" value="101"/>
//   </class>
//   <class name="PLC">
//     <entry key="type" value="RTU"/>
//     <entry key="type" value="TCP"/>
//     <!-- PLC1 inlined; value attr = scalar, child entries = PLC1's dict -->
//     <entry key="10:58:sd:as:ru" value="PLC1" inlines="PLC1">
//       <entry key="pumps" value="1"/>
//     </entry>
//   </class>
//   <!-- No standalone <class name="PLC1"> since it is inlined above -->
// </Metadata>
//
// Parsing rule: if an <entry> has an `inlines` attribute, its child <entry>
// elements are registered under the named class.

function buildXML() {
  // inlinedClasses already tracks every config-derived nested class.
  // metaDict contains only root classes — iterate those directly.
  const lines = ['<Metadata>'];
  for (const [cls, dict] of Object.entries(metaDict)) {
    lines.push(`  <class name="${escXml(cls)}">`);
    for (const [key, val] of Object.entries(dict)) {
      xmlEntries(lines, key, val, '    ', inlinedClasses);
    }
    lines.push(`  </class>`);
  }
  lines.push('</Metadata>');
  return lines.join('\n');
}

// Emit <entry> elements for one key/val, inlining referenced classes.
function xmlEntries(lines, key, val, indent, inlined) {
  const kAttr = `key="${escXml(key)}"`;

  if (typeof val === 'string') {
    const sDict = classDicts[val];
    if (inlined.has(val) && sDict && Object.keys(sDict).length > 0) {
      // Value names a class with entries → inline its entries as children
      lines.push(`${indent}<entry ${kAttr} value="${escXml(val)}" inlines="${escXml(val)}">`);
      for (const [nk, nv] of Object.entries(sDict)) {
        xmlEntries(lines, nk, nv, indent + '  ', inlined);
      }
      lines.push(`${indent}</entry>`);
    } else {
      lines.push(`${indent}<entry ${kAttr} value="${escXml(val)}"/>`);
    }

  } else if (Array.isArray(val)) {
    const scalars = val.filter(v => typeof v === 'string');
    const nested  = val.find(v => typeof v === 'object' && v !== null);
    const refName = nested ? Object.keys(classDicts).find(c => classDicts[c] === nested) : null;

    // Scalar entries (plain, or with value-inlining if the scalar is a class name)
    scalars.forEach(s => {
      const sDict = classDicts[s];
      if (inlined.has(s) && sDict && Object.keys(sDict).length > 0) {
        lines.push(`${indent}<entry ${kAttr} value="${escXml(s)}" inlines="${escXml(s)}">`);
        for (const [nk, nv] of Object.entries(sDict)) {
          xmlEntries(lines, nk, nv, indent + '  ', inlined);
        }
        lines.push(`${indent}</entry>`);
      } else {
        lines.push(`${indent}<entry ${kAttr} value="${escXml(s)}"/>`);
      }
    });

    // Nested dict whose name was NOT already emitted as a scalar value above
    if (refName && inlined.has(refName) && !scalars.includes(refName)) {
      lines.push(`${indent}<entry ${kAttr} inlines="${escXml(refName)}">`);
      for (const [nk, nv] of Object.entries(nested)) {
        xmlEntries(lines, nk, nv, indent + '  ', inlined);
      }
      lines.push(`${indent}</entry>`);
    }
  }
}

function parseXML(xmlStr) {
  const doc = new DOMParser().parseFromString(xmlStr, 'application/xml');
  metaDict            = {};
  classDicts          = {};
  rowList             = [];
  classInheritedKeys  = {};
  classInheritedKeyDefs = {};

  inlinedClasses = new Set();   // reset before re-parsing

  if (doc.querySelector('row')) {
    // ── Legacy flat format ────────────────────────────────────────────────────
    doc.querySelectorAll('row').forEach(row => {
      const cls = (row.querySelector('Class')?.textContent || '').trim();
      const key = (row.querySelector('Key')?.textContent   || '').trim();
      const val = (row.querySelector('Value')?.textContent || '').trim();
      if (cls && key && val) addEntry(cls, key, val);
    });
  } else {
    // ── Nested format ─────────────────────────────────────────────────────────
    // Pre-scan: collect every class referenced via `inlines` anywhere in the doc.
    // These are inlined classes — skip them as standalone top-level <class> elements
    // so they are never parsed twice (once inline + once as a redundant standalone).
    const inlinedNames = new Set(
      Array.from(doc.querySelectorAll('entry[inlines]'))
           .map(el => el.getAttribute('inlines'))
           .filter(Boolean)
    );

    doc.querySelectorAll('Metadata > class').forEach(clsEl => {
      const cls = clsEl.getAttribute('name');
      if (!cls || inlinedNames.has(cls)) return;   // skip inlined classes
      parseEntries(clsEl, cls);
    });
  }

  console.log('metaDict (loaded):', JSON.parse(JSON.stringify(metaDict)));
}

// Recursively parse <entry> children of parentEl under class name `cls`.
function parseEntries(parentEl, cls) {
  Array.from(parentEl.children).forEach(el => {
    if (el.tagName !== 'entry') return;
    const key     = el.getAttribute('key');
    const val     = el.getAttribute('value');
    const inlines = el.getAttribute('inlines');
    if (key && val) addEntry(cls, key, val);
    if (inlines && el.children.length > 0) {
      // Always register the inlined class so buildXML knows to render it nested.
      inlinedClasses.add(inlines);
      if (inlines in metaDict) delete metaDict[inlines];
      // Only parse children if this inlined class hasn't been populated yet.
      // The same class name (e.g. "status") may appear under multiple parents;
      // all parents share one classDicts entry, so reparsing would duplicate attrs.
      const alreadyPopulated = inlines in classDicts && Object.keys(classDicts[inlines]).length > 0;
      if (!alreadyPopulated) {
        parseEntries(el, inlines);   // child entries belong to the inlined class
      }
    }
  });
}

// ── FLAT VIEW: rows grouped by class, then by key (first-appearance order) ───
let displayRows = [];

function buildDisplayRows() {
  const classOrder = [];
  const classSeen  = new Set();
  const groups     = {};   // { cls: { keyOrder, keySeen, keyRows } }

  rowList.forEach(row => {
    const cls = row.class, key = row.key;
    if (!classSeen.has(cls)) {
      classSeen.add(cls);
      classOrder.push(cls);
      groups[cls] = { keyOrder: [], keySeen: new Set(), keyRows: {} };
    }
    const g = groups[cls];
    if (!g.keySeen.has(key)) {
      g.keySeen.add(key);
      g.keyOrder.push(key);
      g.keyRows[key] = [];
    }
    g.keyRows[key].push(row);
  });

  displayRows = [];
  classOrder.forEach(cls => {
    const g = groups[cls];
    g.keyOrder.forEach(key => g.keyRows[key].forEach(row => displayRows.push(row)));
  });
}

function scalarsOf(val) {
  if (typeof val === 'string') return [val];
  if (Array.isArray(val))      return val.filter(v => typeof v === 'string');
  return [];  // plain object (nested dict) — skip
}

// ── HIERARCHY VIEW ────────────────────────────────────────────────────────────
function renderHierarchy() {
  const container = document.getElementById('hierarchy');
  if (!container) return;
  container.innerHTML = '';
  if (Object.keys(metaDict).length === 0) {
    container.innerHTML = '<div class="h-empty">No data loaded</div>';
    return;
  }
  const ul = document.createElement('ul');
  ul.className = 'h-tree';
  for (const [cls, dict] of Object.entries(metaDict)) {
    const li = document.createElement('li');
    li.className = 'h-class';
    const nameSpan = document.createElement('span');
    nameSpan.className = 'h-class-name';
    nameSpan.textContent = cls;
    li.appendChild(nameSpan);
    // Each root class gets its own visited set — only prevents cycles within one branch
    const childUl = buildDictUl(dict, new Set([cls]));
    if (childUl.children.length > 0) li.appendChild(childUl);
    ul.appendChild(li);
  }
  container.appendChild(ul);
}

function buildDictUl(dict, visited) {
  const ul = document.createElement('ul');
  for (const [key, val] of Object.entries(dict)) {
    if (typeof val === 'string') {
      ul.appendChild(hLeaf(key, val));
    } else if (Array.isArray(val)) {
      const plainScalars = [];   // scalars with no following nested dict
      for (let i = 0; i < val.length; i++) {
        if (typeof val[i] !== 'string') continue;
        const s = val[i];
        // The embedded dict for this scalar sits immediately after it in the array
        const nd = (i + 1 < val.length && typeof val[i + 1] === 'object' && val[i + 1] !== null)
                   ? val[i + 1] : null;
        if (nd) {
          const cls = Object.keys(classDicts).find(c => classDicts[c] === nd);
          if (cls && !visited.has(cls)) {
            // Flush any accumulated plain scalars before this folder item
            if (plainScalars.length > 0) {
              ul.appendChild(hLeaf(key, plainScalars.join(', ')));
              plainScalars.length = 0;
            }
            const li = document.createElement('li');
            li.className = 'h-kv h-folder';
            li.innerHTML = '<span class="h-key">' + escHtml(key) + '</span>'
                         + '<span class="h-sep">: </span>'
                         + '<span class="h-val-cls">' + escHtml(s) + '</span>';
            const subUl = buildDictUl(nd, new Set([...visited, cls]));
            if (subUl.children.length > 0) li.appendChild(subUl);
            ul.appendChild(li);
            continue;
          }
        }
        plainScalars.push(s);
      }
      // Emit remaining plain scalars as a single CSV leaf
      if (plainScalars.length > 0) ul.appendChild(hLeaf(key, plainScalars.join(', ')));
    }
  }
  return ul;
}

function hLeaf(key, val) {
  const li = document.createElement('li');
  li.className = 'h-kv h-leaf';
  li.innerHTML = '<span class="h-key">' + escHtml(key) + '</span>'
               + '<span class="h-sep">: </span>'
               + '<span class="h-val">' + escHtml(val) + '</span>';
  return li;
}

// ── TABLE ─────────────────────────────────────────────────────────────────────
function renderTable() {
  buildDisplayRows();
  updateClassDatalist();
  renderHierarchy();
  const tbody = document.getElementById('meta-tbody');
  tbody.innerHTML = '';
  if (displayRows.length === 0) {
    tbody.innerHTML = '<tr><td colspan="5" style="color:#aaa;font-style:italic">No entries yet</td></tr>';
    return;
  }
  displayRows.forEach((row, idx) => {
    const tr = document.createElement('tr');
    tr.innerHTML =
      `<td class="row-actions-left">` +
        `<span class="copy-row" onclick="copyRow(${idx})" title="Copy to form">&#x2398;</span>` +
        `<span class="edit-row" onclick="editRow(${idx})" title="Edit (copy &amp; delete)">&#x270F;</span>` +
      `</td>` +
      `<td class="class-cell">${escHtml(row.class)}</td>` +
      `<td>${escHtml(row.key)}</td>` +
      `<td>${escHtml(row.value)}</td>` +
      `<td class="row-actions">` +
        `<span class="delete" onclick="deleteRow(${idx})" title="Delete">&#x2715;</span>` +
      `</td>`;
    tbody.appendChild(tr);
  });
}

// ── COPY ROW → form ───────────────────────────────────────────────────────────
function copyRow(idx) {
  pendingEdit = null;   // cancel any in-progress edit
  const row = displayRows[idx];
  if (!row) return;
  document.getElementById('inp-class').value = row.class;
  updateKeyField(row.class);

  // Try to set the key; if the select doesn't have that option, fall back to free-text input
  const sel = document.getElementById('sel-key');
  const inp = document.getElementById('inp-key');
  if (sel && sel.style.display !== 'none') {
    sel.value = row.key;
    if (sel.value !== row.key) {
      // Key not among config options — show free-text input instead
      sel.style.display = 'none';
      inp.style.display = '';
      inp.value = row.key;
    }
  } else {
    inp.value = row.key;
  }

  document.getElementById('inp-value').value = row.value;
  updateValueField(row.key);
  checkValueLookup();
  clearEntryErrors();
  document.getElementById('inp-class').focus();
}

// ── EDIT ROW (fill form; old row is removed only when insert is submitted) ────
function editRow(idx) {
  const row = displayRows[idx];
  if (!row) return;
  pendingEdit = { class: row.class, key: row.key, value: row.value };

  document.getElementById('inp-class').value = row.class;
  updateKeyField(row.class);
  const sel = document.getElementById('sel-key');
  const inp = document.getElementById('inp-key');
  if (sel && sel.style.display !== 'none') {
    sel.value = row.key;
    if (sel.value !== row.key) {
      sel.style.display = 'none';
      inp.style.display = '';
      inp.value = row.key;
    }
  } else {
    inp.value = row.key;
  }
  document.getElementById('inp-value').value = row.value;
  updateValueField(row.key);
  checkValueLookup();
  clearEntryErrors();
  document.getElementById('inp-class').focus();
}

// ── DELETE ────────────────────────────────────────────────────────────────────
function deleteRow(idx) {
  const row = displayRows[idx];
  if (!row) return;
  // Remove first matching rowList entry for this (class, key, value)
  const ri = rowList.findIndex(r => r.class === row.class && r.key === row.key && r.value === row.value);
  if (ri !== -1) rowList.splice(ri, 1);
  const snap = rowList.slice();
  metaDict = {}; classDicts = {}; rowList = []; classInheritedKeys = {}; classInheritedKeyDefs = {}; inlinedClasses = new Set();
  snap.forEach(r => addEntry(r.class, r.key, r.value));
  saveToLocalStorage();
  renderTable();
  markDirty();
  console.log('metaDict (after delete):', JSON.parse(JSON.stringify(metaDict)));
}

// ── MODAL ─────────────────────────────────────────────────────────────────────
function showModal(onProceed) {
  pendingLoad = onProceed;
  document.getElementById('modal-overlay').style.display = 'flex';
}

function hideModal() {
  document.getElementById('modal-overlay').style.display = 'none';
  pendingLoad = null;
}

function modalSave()   { const cb = pendingLoad; hideModal(); saveXML(); if (cb) setTimeout(cb, 100); }
function modalNoSave() { const cb = pendingLoad; hideModal(); if (cb) cb(); }
function modalCancel() { hideModal(); }

// ── DIRTY / CLEAN ─────────────────────────────────────────────────────────────
function markDirty() { dirty = true;  setStatus('Unsaved changes', false, 'dirty'); }
function markClean() { dirty = false; }

// ── LOCAL STORAGE (session restore) ──────────────────────────────────────────
function saveToLocalStorage() {
  localStorage.setItem('acms_metadata_rows', JSON.stringify(rowList));
}

function loadFromLocalStorage() {
  try {
    const rows = JSON.parse(localStorage.getItem('acms_metadata_rows') || 'null');
    if (!rows) return;
    metaDict = {}; classDicts = {}; rowList = []; classInheritedKeys = {}; classInheritedKeyDefs = {}; inlinedClasses = new Set();
    rows.forEach(r => addEntry(r.class, r.key, r.value));
    console.log('metaDict (restored):', JSON.parse(JSON.stringify(metaDict)));
  } catch (e) { console.warn('Restore failed:', e); }
}

// ── ESCAPE ────────────────────────────────────────────────────────────────────
function escXml(s) {
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;')
                  .replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}
function escHtml(s) {
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

// ── ERROR DISPLAY ─────────────────────────────────────────────────────────────
function showError(id, msg) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = msg;
  if (id === 'err-key') {
    document.getElementById('inp-key')?.classList.add('invalid');
    document.getElementById('sel-key')?.classList.add('invalid');
  } else {
    el.previousElementSibling?.classList.add('invalid');
  }
}

function clearEntryErrors() {
  clearValueHint();
  ['err-class','err-key','err-value'].forEach(id => {
    const el = document.getElementById(id);
    if (!el) return;
    el.textContent = '';
    if (id === 'err-key') {
      document.getElementById('inp-key')?.classList.remove('invalid');
      document.getElementById('sel-key')?.classList.remove('invalid');
    } else {
      el.previousElementSibling?.classList.remove('invalid');
    }
  });
}

function clearFilenameError() {
  const el = document.getElementById('err-filename');
  if (!el) return;
  el.textContent = '';
  const inp = el.previousElementSibling;
  if (inp) inp.classList.remove('invalid');
}

function setStatus(msg, isError, extraClass) {
  const el = document.getElementById('status-msg');
  el.textContent = msg;
  el.className   = isError ? 'error' : (extraClass || '');
}
