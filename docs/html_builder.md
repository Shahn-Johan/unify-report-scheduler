# HTML Builder — Internals

`tools/schedule_builder.html` is a single-file SPA (HTML + CSS + JS, no build step, no dependencies). Open in any browser.

---

## Layout

4-column CSS grid:

```css
body {
  grid-template-columns: 220px 440px 1fr 1fr;
  grid-template-rows: 52px 1fr;
}
```

| Panel ID | Column | Purpose |
|---|---|---|
| `header` | 1 / -1 | App header, 52px |
| `#tok-side` | 1 | Token Reference sidebar — 220px |
| `#wizard` | 2 | Step wizard — 440px |
| `#obj-panel` | 3 | Object Builder — `1fr` |
| `#sql-panel` | 4 | Generated SQL output — `1fr` |

---

## State stores

All state lives in module-level JavaScript variables declared at the top of the `<script>` block.

### fieldState — 11 keys

```javascript
const fieldState = {
  'dlv-email':      { mode:'static', staticVal:'', dynamicVal:'' },
  'dlv-subject':    { mode:'static', staticVal:'', dynamicVal:'' },
  'dlv-body':       { mode:'static', staticVal:'', dynamicVal:'' },
  'dlv-filename':   { mode:'static', staticVal:'', dynamicVal:'' },
  'dlv-folder':     { mode:'static', staticVal:'', dynamicVal:'' },
  'fo-email':       { mode:'static', staticVal:'', dynamicVal:'' },
  'fo-subject':     { mode:'static', staticVal:'', dynamicVal:'' },
  'fo-body':        { mode:'static', staticVal:'', dynamicVal:'' },
  'fo-filename':    { mode:'parent', staticVal:'', dynamicVal:'' },  // default: Use from Delivery
  'fo-folder':      { mode:'parent', staticVal:'', dynamicVal:'' },  // default: Use from Delivery
  'fo-displayname': { mode:'static', staticVal:'', dynamicVal:'' },
};
```

`mode` is one of: `'static'` | `'dynamic'` | `'parent'`. The `'parent'` option is available on `fo-folder`, `fo-filename`, `fo-subject`, and `fo-body`. It means "inherit from the Delivery group" — the field reads from `dlv-folder`, `dlv-filename`, `dlv-subject`, or `dlv-body` respectively. `fo-folder` and `fo-filename` initialise to `mode:'parent'`; `fo-subject` and `fo-body` initialise to `mode:'static'` but show the "Use from Delivery" tab when open in the Object Builder.

`fieldState` is the single source of truth for all source/value fields. The DOM inputs are always read from `fieldState` via `getFieldValue(key)` and `getFieldSource(key)`.

### rcpState — recipient array

```javascript
let rcpState = []; // [{ role:'CC'|'BCC', email:'string', includeInFanOut:false }]
```

The single source of truth for all standing recipients. `syncCore()` reads it via `getRecipients()`. The DOM recipient list is a rendered view — never read directly.

### params — parameter array

```javascript
let params = []; // [{ id, name, type, required, sortOrder, values[], valueSource, valueQuery, dateMode, dateToken, todayDir, todayN }]
```

`id` is auto-incremented from `pidx`. Displayed as ob-group cards in Step 3.

### Other module-level variables

| Variable | Type | Purpose |
|---|---|---|
| `pidx` | `number` | Counter for generating unique param IDs |
| `delivery` | `string` | Current delivery mode: `EMAIL` \| `FOLDER` \| `BOTH` |
| `fanout` | `string` | Current fan-out mode: `NONE` \| `INDIVIDUAL` \| `BOTH` |
| `_foParamId` | `number` | ID of the primary fan-out parameter; set only by `syncCore()` |
| `schedNameEdited` | `boolean` | `true` once user manually edits schedule name |
| `activeObjField` | `object \| null` | `{key, open, close}` for currently open OB section |
| `_obMouseDownInside` | `boolean` | Set `true` on `mousedown` inside `#obj-panel`; prevents click-away |

`isEmail` and `isFolder` are **not** module-level — they are `const` locals declared at the top of `syncCore()` on every call:

```javascript
const isEmail  = ['EMAIL','BOTH'].includes(delivery);
const isFolder = ['FOLDER','BOTH'].includes(delivery);
```

---

## Steps 1–5

### Step 1 — Report Document (`id="s1"`)

| Field ID | Type | Purpose |
|---|---|---|
| `#docName` | text | Document name |
| `#outputFormat` | select | `xlsx` / `pdf` / `csv` (default: `xlsx`) |
| `#language` | number | Language code (default: `1`) |
| `#confidentiality` | select | `normal` / `personal` / `private` / `confidential` / `webpublished` / `none` |
| `#importJson` | textarea | Paste Request JSON to auto-fill Document Name from `$['Document']['sDocumentName']` |

### Step 2 — Schedule Timing (`id="s2"`)

| Field ID | Shown when |
|---|---|
| `#schedName` | always |
| `#freq` | always — select: `DAILY` / `WEEKLY` / `MONTHLY` (default) / `ADHOC` / `INTERVAL` |
| `#runTime` | DAILY, WEEKLY, MONTHLY |
| `#dow` | WEEKLY |
| `#dom` | MONTHLY |
| `#intervalMin` | INTERVAL |
| `#winStart`, `#winEnd` | INTERVAL |
| `#startDate`, `#endDate` | always |

`schedNameEdited` is set `true` on first manual keystroke in `#schedName`; prevents auto-name from overwriting once user has customised it.

### Step 3 — Parameters (`id="s3"`)

Parameters are rendered as `ob-group` cards by `renderParams()` → `makeParamCard(p)`. Each card:

```
div.ob-group#pc-{id}
  div.ob-group-header  — name, type badge, DYNAMIC badge (if valueSource='dynamic'), FAN-OUT badge (if _foParamId === p.id)
  div.ob-group-row     — value summary text (id="pvs-text-{id}")
  div#pval-{id}        — value editor (DOM-moved into OB when card is clicked)
```

Clicking a card calls `toggleParamCard(id)` → `openInObjectBuilder({key:'param-{id}', ...})` → `openParamValueInOB(id)`.

Add button calls `addParam()` which pushes to `params[]` and calls `renderParams()`.

### Step 4 — Delivery (`id="s4"`)

Delivery type selected via `setDelivery('EMAIL'|'FOLDER'|'BOTH')`. Sets `delivery` and shows/hides the relevant ob-group cards.

| Group ID | Opens |
|---|---|
| `#dlv-email-group` | `openDeliveryGroup('email')` |
| `#dlv-folder-group` | `openDeliveryGroup('folder')` — hidden unless `delivery` includes FOLDER |

Each group opens in the Object Builder panel via `_openGroupInOB()`.

### Step 5 — Fan-out (`id="s5"`)

Fan-out mode selected via `setFanout('NONE'|'INDIVIDUAL'|'BOTH')`. Sets `fanout` and shows/hides config panel `#fo-config`.

When fan-out is active, `#fo-param` select chooses which parameter drives fan-out (its value becomes `_foParamId` after `syncCore()`).

| Group ID | Opens |
|---|---|
| `#fo-dn-group` | `openFanoutGroup('displayname')` |
| `#fo-email-group` | `openFanoutGroup('email')` — hidden unless EMAIL or BOTH |
| `#fo-folder-group` | `openFanoutGroup('folder')` — hidden unless FOLDER or BOTH |

---

## Object Builder (OB) architecture

The OB panel (`#obj-panel`) is a shared workspace. When a group or param card is opened, its content section is physically DOM-moved into the OB panel body element. It is restored to its original DOM position when the OB is closed.

### openInObjectBuilder(config)

`config = { key, open: () => void, close: () => void }`

1. If another field is open: run `validateObjField` on it. If invalid, show error / shake and abort.
2. If same key is clicked again: close (toggle).
3. Run `config.close()` for current field (if any), then restore its DOM section.
4. Set `activeObjField = config`.
5. Run `config.open()` — populates the OB body.

### _openGroupInOB(key, label, contentFn)

Used by delivery and fan-out groups. `contentFn()` returns an HTML string.

1. `openInObjectBuilder({key, open, close})`
2. `open()`:
   - `ob-field-body.innerHTML = contentFn()`
   - Shows `#ob-field-zone`, hides empty-state element
   - Sets breadcrumb and context text
   - Adds `.active` class to the matching `.ob-group` card
   - Calls `wireTokenDrop(obBody)` — enables drag-drop into all inputs/textareas
   - Calls `updateOverwriteWarn()` — shows warning if `fo-folder`/`fo-filename` override delivery
   - Calls `rcpRender()` — re-renders recipient list (only relevant for email group)
   - Runs `_runValidateDynSQL(k)` for all fieldState keys currently in `dynamic` mode

### openParamValueInOB(id)

Physically moves `div#pval-{id}` into the OB panel body. Restores it on close.

---

## Validation system

### validateObjField(section)

Routes to the appropriate validator based on `section` (the active `activeObjField.key`):

1. `section.startsWith('param-')` → `validateParamCard(id)`
2. Exact match for group keys before `startsWith` fallback:
   - `'dlv-grp-email'` → `validateDeliveryGroup('email')`
   - `'dlv-grp-folder'` → `validateDeliveryGroup('folder')`
   - `'fo-grp-email'` → `validateFanoutGroup('email')`
   - `'fo-grp-folder'` → `validateFanoutGroup('folder')`
   - `'fo-grp-displayname'` → `validateFanoutGroup('displayname')`
3. `section.startsWith('dlv-')` → `validateDeliveryField(section)`
4. `section.startsWith('fo-')` → `validateFanoutField(section)`

The group key check **must** happen before the `startsWith` check — `'dlv-grp-email'.startsWith('dlv-')` is `true`, so reversing the order would skip group validation.

### _runValidateDynSQL(key)

Returns `true` (invalid) if the dynamic SQL textarea is non-empty but does not contain the required alias/column name. Returns `false`/`undefined` when valid.

### typeof err guard

In both `openInObjectBuilder` and the click-away handler:

```javascript
if (err) {
  if (typeof err === 'string') showObjValidationError(err);
  else { /* shake #obj-panel */ }
  return;
}
```

When `_runValidateDynSQL` returns `true`, the shake runs (no banner). When a validator returns a string message, the banner is shown.

### displayNameUsed()

Module-level function. Returns `true` if `{{DISPLAYNAME}}` appears in any of the six fields that support it (`dlv-subject`, `dlv-body`, `dlv-filename`, `fo-subject`, `fo-body`, `fo-filename`). Used by `validateFanoutField` and `validateFanoutGroup` to require `fo-displayname` when `{{DISPLAYNAME}}` is referenced.

---

## Click-away guard

Closes the active OB field when the user clicks outside of it.

```javascript
let _obMouseDownInside = false;

document.addEventListener('mousedown', function(e) {
  _obMouseDownInside = !!e.target.closest('#obj-panel');
}, true);

document.addEventListener('click', function(e) {
  if (!activeObjField) return;
  if (_obMouseDownInside) return;   // drag started inside OB — don't close

  const skip = e.target.closest('#obj-panel') || e.target.closest('#tok-side')
            || e.target.closest('#right-panel') || e.target.closest('#sql-panel')
            || e.target.closest('.load-panel') || e.target.closest('.step-header')
            || e.target.closest('.ob-trigger');
  if (skip) return;

  // .ob-group is NOT excluded — clicking another group validates and closes current

  const err = validateObjField(activeObjField.key);
  if (err) { /* show error or shake */ return; }
  clearObjectBuilder();
}, true);
```

`_obMouseDownInside` is never reset after being set to `true`. This is intentional — once a mousedown occurs inside the OB in a given session, the flag stays `true` and subsequent external clicks do not close the OB. This prevents accidental close when text-selecting inside the OB and releasing the mouse outside.

---

## Token system

### TOKEN_LIST (23 tokens)

Tokens are grouped:

| Group | Tokens |
|---|---|
| Today | `{{TODAY}}`, `{{TODAY-N}}`, `{{TODAY+N}}` |
| Current Week | `{{WEEK_START}}`, `{{WEEK_END}}` |
| Previous Week | `{{PREV_WEEK_START}}`, `{{PREV_WEEK_END}}` |
| Current Month | `{{MONTH_START}}`, `{{MONTH_END}}` |
| Previous Month | `{{PREV_MONTH_START}}`, `{{PREV_MONTH_END}}` |
| Next Month | `{{NEXT_MONTH_START}}`, `{{NEXT_MONTH_END}}` |
| Quarter | `{{QUARTER_START}}`, `{{QUARTER_END}}` |
| Previous Quarter | `{{PREV_QUARTER_START}}`, `{{PREV_QUARTER_END}}` |
| Year | `{{YEAR}}`, `{{YEAR_START}}`, `{{YEAR_END}}` |
| Previous Year | `{{PREV_YEAR}}`, `{{PREV_YEAR_START}}`, `{{PREV_YEAR_END}}` |

`{{DISPLAYNAME}}` is not in `TOKEN_LIST` — it is a special runtime token resolved by `usp_BuildDispatchQueue` after `fn_ResolveAllTokens`.

### wireTokenDrop(container)

Sets `ondragover` and `ondrop` on every `input[type=text]` and `textarea` inside `container`. On drop: inserts the token text at the cursor position and dispatches `input`+`change` events so `sync()` picks up the change.

Called after rendering any OB content: `_openGroupInOB`, `openParamValueInOB`, `renderFieldEditorInto`, and inside `setFieldMode` for folder/filename rebuilds.

### FIELD_ALIASES

Maps fieldState key → display alias:

| Key | Alias |
|---|---|
| `dlv-email` / `fo-email` | `EmailAddress` |
| `dlv-subject` / `fo-subject` | `Subject` |
| `dlv-body` / `fo-body` | `Body` |
| `dlv-filename` / `fo-filename` | `FileName` |
| `dlv-folder` / `fo-folder` | `FolderPath` |
| `fo-displayname` | `DisplayName` |

Used for error messages and for labelling field editors.

---

## updateOverwriteWarn()

Called when a group opens or when `fo-folder`/`fo-filename` mode changes. Displays a warning inside the fan-out folder group if the per-entity folder/filename overrides the delivery-level value — informing the user that the INDIVIDUAL rows will use the fan-out value, not the delivery value.

### Call sites

1. Inside `_openGroupInOB` after rendering group content
2. Inside `setFieldMode()` when `key === 'fo-folder'` or `key === 'fo-filename'` **and** `activeObjField.key === 'fo-grp-folder'` (folder group must be the active OB section). This guard prevents `buildFanoutGroupContent('folder')` from clobbering the email group when `fo-filename` mode is changed while the email group is open.
3. Inside `updateGroupSummary()` (called from `setDelivery`, `setFanout`, and `sync`)

---

## syncCore() — SQL generation

`syncCore()` is called on every state change via `sync()`. It regenerates the full `EXEC [schdl].[usp_RegisterSchedule]` statement in `#sql-out`.

Key steps:

1. Compute `isEmail` / `isFolder` from `delivery`
2. Build `@ParametersJson` array — for each param in `params[]`:
   - Add value/query fields
   - If this param's `id === _foParamId` (determined by `#fo-param` select): add `fanOut` block with all `fo-*` fieldState values
3. Build `@DispatchJson` object from `dlv-*` fieldState values
4. Build `@RecipientsJson` array from `rcpState[]`
5. Set `_foParamId = parseInt(#fo-param.value)` (module-level update)
6. Format the full `EXEC` statement as a T-SQL string

**Output key names are fixed** — all `*Source` / `*SourceValue`, never `*Template`:
- `subjectSource` not `subjectTemplate`
- `bodySource` not `bodyTemplate`
- `fileNameSource` not `fileNameTemplate`

---

## Load Schedule (round-trip from database)

The load panel (`class="load-panel"`, `z-index:20`) sits above Step 1 with `z-index:20`. Step body has `z-index:0` so it never occludes the panel.

### loadSchedule()

1. Reads `#loadScheduleJson` textarea
2. `extractSqlParam(raw, paramName)` — regex: `@ParamName\s*=\s*N?'((?:''|[^'])*)'` — handles escaped `''` inside SQL string literals
3. Extracts all `usp_RegisterSchedule` parameters
4. Parses `@DispatchJson`, `@ParametersJson`, `@RecipientsJson` as JSON
5. Rebuilds `params[]`, `rcpState[]`, `fieldState`, `delivery`, `fanout`
6. Backward compat: reads legacy `@Subject` / `@BodyTemplate` proc params (overridden if `@DispatchJson` also has them); reads `fileNameTemplate` / `subjectTemplate` / `bodyTemplate` keys inside JSON

After load: calls `renderParams()`, `rcpRender()`, `syncCore()`, and sets UI controls to the loaded values.
