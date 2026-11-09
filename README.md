# omniroute-gh-auto-dupfix

Fix for the **4x duplicated streaming output** bug in [OmniRoute](https://www.npmjs.com/package/omniroute) (v3.8.53) when the client uses the GitHub Copilot auto model — e.g. `gh/auto` (upstream picks `mai-code-1.1-flash` / `gpt-6-luna`).

**Symptom:** every streamed response is repeated 4 times. `- "1"` becomes `"1111"`, `"Greeting"` becomes `"GreetingGreetingGreetingGreeting"` (session titles in clients like OpenCode and Claude Code get visibly duplicated).

## Root cause

The GitHub Copilot upstream speaks the OpenAI **Responses API** (`targetFormat: "openai-responses"` in the call logs), and — this is the nasty part — **every event carries a different, random `item_id`**:

```
response.output_text.delta   item_id: AAAA...
response.output_text.delta   item_id: BBBB...
response.output_text.delta   item_id: CCCC...
response.output_text.done    item_id: DDDD...
response.content_part.done   item_id: EEEE...
response.output_item.done    item_id: FFFF...
```

OmniRoute's text-snapshot tracker (`synthesizeTextSnapshots`, module `710972` in the compiled bundles) links deltas to `.done` snapshots by `item_id`. With mismatched ids the tracker resolves the `.done` events into **fresh items that contain no recorded fragments**, so its `reconcile()` function treats the *entire accumulated text* as "un-emitted suffix" and re-emits it. There are three `.done`-snapshot recovery paths, so the full text is re-emitted 3 times on top of the real stream: **4 copies total**.

The provider-side call log confirms accumulation upstream is correct (only one copy) — the duplication happens purely during emission to the client.

## The fix

A guard is injected into the minified `reconcile()` function inside **6 compiled chunk files** under
`<omniroute>/dist/.build/next/server/chunks/` (`_0kgjpideqjanh._.js`, `_1ah0e82mpy16a._.js`, `_1c7p-bd9pe129._.js`, `_1lsot6wv_bh7k._.js`, `_1nm0or0vulb48._.js`, `_1yl09nkoaczea._.js`):

```js
// compiled reconcile(tracker t, part e, snapshot n)
function (e, t, n) {
  if (n.length < t.length) return "";
  // ── injected guard ──────────────────────────────────────────────
  if (0 === t.length && (() => {
    for (const g of e.items)
      for (const h of g.parts.values())
        if (h.fragments.length > 0) return !0;
    return !1
  })()) return "";   // this part has no recorded fragments
                     // while deltas exist elsewhere → identity
                     // mismatch → do NOT re-emit the full text
  // ───────────────────────────────────────────────────────────────
  let o = 0;
  for (let e of t.fragments) { ... }   // normal suffix logic unchanged
}
```

**Why it is safe:**

| Upstream behavior | Guard effect |
| --- | --- |
| Deltas + `.done` share the same `item_id` (standard OpenAI) | part has fragments → guard not triggered, normal suffix logic |
| Upstream sends **no deltas**, only final snapshots | tracker has no fragments anywhere → guard not triggered, full text emitted (correct) |
| Copilot-style per-event random `item_id` | guard suppresses the 3 spurious full-text re-emits ✅ |

## Usage

```powershell
# OmniRoute must not be running while files are patched (apply while stopped).
# Patch (auto-detects the global omniroute install, idempotent, creates backups):
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\patch-dupfix.ps1

# Roll everything back to the pristine copies in backups\:
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\patch-dupfix.ps1 -Restore
```

Then restart OmniRoute normally (e.g. `omniroute` in a terminal).

> ⚠️ Runtime is the **compiled webpack bundles** (`dist/.build/next/server/chunks/*_*.js`), **not** the `open-sse/**/*.ts` sources — editing the TypeScript sources does **not** change behavior. That is why the patch targets the bundles directly.

> ⚠️ **Updating omniroute via npm will wipe this patch.** Re-apply with the script afterwards (or file an upstream issue; the same logic exists in `open-sse/translator/response/openai-responses/synthesizeTextSnapshots.ts` → `reconcile()` and a proper source fix should live there — return `""` from `reconcile()` when the part has no recorded fragments but the tracker holds recorded deltas elsewhere).

## Verification

```bash
BASE=http://localhost:20128/v1
KEY=sk-your-omniroute-key

curl -sN -X POST $BASE/chat/completions \
  -H "Content-Type: application/json" -H "Authorization: Bearer $KEY" \
  -d '{"model":"gh/auto","stream":true,"messages":[{"role":"user","content":"say exactly: Greeting"}]}'
```

Before / after excerpts are in [`examples/`](examples/) (`before-stream.txt`, `after-stream.txt`): 4x duplication before the patch, clean single-payload stream after, for chat streaming, non-streaming chat, and the `/v1/responses` passthrough.

## Compatibility

- Tested against **omniroute v3.8.53** (Windows, npm global install).
- The regex patch is identifier-name-agnostic, so it should survive minor minifier naming changes; the script reports exactly which files it patched and refuses to double-patch.

## Files

| Path | Purpose |
| --- | --- |
| `scripts/patch-dupfix.ps1` | apply / restore the guard to the compiled bundles |
| `backups/*.js.bak` | pristine pre-patch copies of the 6 chunk files |
| `examples/before-stream.txt`, `examples/after-stream.txt` | captured streams proving the bug and the fix |

## License

MIT
