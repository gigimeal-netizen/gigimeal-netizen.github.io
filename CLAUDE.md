# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

This repo currently contains a single deliverable: `baker-calculator.html`, a standalone mobile-web baker's-percentage calculator (Korean UI) built as part of "Mino Phase 1.0" (a planned smart-scaler module for a larger bakery-tooling product). There is no build system, package manager, or test suite — it's plain HTML/CSS/JS in one file with zero external dependencies (no CDN links, no web fonts, no frameworks).

`2026-07-06_제빵계산기_작업기록.md` is a dev log (in Korean) documenting the requirements, design rationale, and known limitations behind `baker-calculator.html`. Read it before making non-trivial changes — it explains *why* things are the way they are, not just what they do.

## Daily work log convention

At the end of each work session where non-trivial work happened (feature work, design decisions, bug fixes — not just Q&A), write or update a dated Korean-language markdown log in the repo root, in the same style as `2026-07-06_제빵계산기_작업기록.md` (background/decisions/what changed/known limitations/next steps, whichever sections are relevant):

- Topic-specific work: `YYYY-MM-DD_주제_작업기록.md` (e.g. `2026-07-06_제빵계산기_작업기록.md`)
- Small/misc work with no single topic: `YYYY-MM-DD_작업기록.md`

If a log for that date already exists and the new work is a continuation of the same topic, update it instead of creating a duplicate for the same day.

## Running / testing

There is no build or test tooling. To work on the calculator, open `baker-calculator.html` directly in a browser (double-click, or a simple static file server if you need to test clipboard APIs that require a secure context). Verify changes manually in-browser — there are no automated tests.

## Architecture (baker-calculator.html)

Everything lives in one file: inline `<style>`, inline `<script>`, no modules. The script is a single IIFE with a plain-object `state` and two render paths (no virtual DOM/diffing either way):
- `render()` — structural rebuild. Clears and rebuilds `#flourList`/`#ingList` from scratch and reattaches listeners. Only called when rows are added/removed (or on first load), since rebuilding destroys and recreates every input, which would steal focus from whatever the user is mid-typing in.
- `updateDisplays()` — lightweight refresh. Recomputes derived numbers and writes them into the *existing* DOM nodes via `.value =`, skipping whichever input is `document.activeElement` so the field the user is actively typing in is never overwritten mid-keystroke. Used for every other input handler (percent/weight edits, mode toggle, base flour/multiplier/target-total changes). Each pct/weight input also refreshes once on `blur`, so mode-B's circular dependency (see below) snaps to the fully consistent number once the user leaves the field.

Core domain logic, all baker's-percentage-based (flour = 100%):
- **Mode A ("배율 조정" / multiplier mode)**: `flourWeight = baseFlour * multiplier`
- **Mode B ("총 반죽량 기준" / target-total mode)**: `flourWeight = targetTotal / ((100 + Σingredient%) / 100)` — reverse-solves flour weight from a desired total dough weight. Note only non-flour `ingredients` feed into this sum — the flour split (below) is internal to the 100% flour bucket and never adds to it.
- Common: `ingredientWeight = flourWeight * (pct / 100)`, and symmetrically `pct = (weight / flourWeight) * 100` — both `pct-input` and `weight-input` are editable and kept in sync in both directions (`pctFromWeight()`), per row.
- Rounding (`roundWeight`/`fmt`): weights ≥10g round to the nearest integer; weights <10g (salt, yeast, etc.) keep one decimal place, matching real scale precision — don't "simplify" this away.

`state.flours` is an array (like `state.ingredients`) supporting multiple flour types in one recipe (e.g. T45 70% + T65 30%), rendered in their own card/list (`#flourList`, separate from `#ingList`). Each flour's own `%` is user-editable and represents its share of the combined 100% flour bucket — it is *not* pinned to 100 the way a single flour row used to be. Because the split is manual, `updateDisplays()` sums `state.flours[].pct` each refresh and flags `#flourCard` + a red warning line (`.warn-hint`, `--accent-stamp`) whenever the sum isn't ~100 (0.05 tolerance for float noise) — this is advisory only, it never blocks calculation. Deleting the last remaining flour row is disallowed (there must always be at least one).

**Editing a flour's `%` vs. its weight are different operations, on purpose:**
- **`%` edit** (2+ flours only — with a single flour type, `.pct-input` is `readonly` and `updateDisplays()` self-heals `state.flours[0].pct = 100` every refresh, since there's nothing else to share the bucket with): redistributes *within the current total* — "make this type X% of however much flour we already have."
- **Weight edit** (any flour count): means "this type weighs X grams," full stop — since the user is describing what's on the scale, not a ratio. So the handler holds every *other* flour's gram amount fixed (`flourWeight * pct/100` at the pre-edit total), substitutes the typed value for the edited row, sums all of them into `newTotal`, recomputes every flour's `%` as its own grams over `newTotal`, and calls `setTotalFlourWeight(newTotal)` to push that new total back into the actual anchor — `state.baseFlour = target / multiplier` in Mode A, or `state.targetTotal = target * (100+Σingredient%)/100` in Mode B (updating the corresponding input's `.value` too).

This is why typing a flour's weight cascades into water/salt/yeast: `computeFlourWeight()` is driven solely by the `baseFlour`/`targetTotal` anchor, never by an individual flour row, so a weight edit has to round-trip through `setTotalFlourWeight()` to actually move that anchor. Two 100g flour entries thus correctly settle at 50/50% on a 200g total, not 100/100%. Deleting back down to one flour row resets its `%` to 100.

**`state.portions`** (Mode B only): lets the target total be built from several dough portions instead of one number — each portion is `{ weight, qty }` (e.g. "200g × 130개" for a batch of identically-sized units), and `portionSubtotal()` is `weight * qty`. Whenever `state.portions.length > 0`, `syncTargetTotalFromPortions()` sums every portion's subtotal into `state.targetTotal` every refresh and puts `targetTotalInput` in `readOnly` (styled via the generic `input[type="number"][readonly]` rule, same treatment as the single-flour `%` case) — editing the plain total field directly only works again once all portions are removed. `buildPortionRows()`/`#portionList` follow the same add/delete/structural-rebuild-vs-`updateDisplays()` split as the flour and ingredient lists; the `.portion-subtotal` span is refreshed live from `updateDisplays()` (matched by `data-idx`, not recreated) since it's a display-only span, not an input that could lose focus. Loading an older `recipe.json` where a portion was saved as a plain number (pre-`qty`) is handled in `applyRecipeToState()` by treating it as `{ weight: <that number>, qty: 1 }`.

**Ingredient reordering**: `#ingList` rows (only — not `#flourList`) get a `.reorder-btns` stack (▲/▼, disabled at the top/bottom of the list) via the `.ing-row.reorderable` grid modifier (5 columns instead of the flour rows' 4). Clicking swaps two entries in `state.ingredients` and calls `render()` (structural — the row-to-index mapping changed, so this can't go through `updateDisplays()`'s in-place update path).

State is in-memory only: no localStorage/persistence, no PWA manifest, no backend, no team sync. A page refresh still resets everything — that remains a known/accepted limitation (see the dev log's "알려진 제한사항" / "다음 단계 제안" sections). The one exception is `recipe.json`: a single file acting as a small multi-recipe library, per the "레시피 저장" / "저장된 레시피 목록" controls.

**`recipe.json` library (save/load)**: `library` (`{ schema, recipes: [...] }`) holds every saved recipe, keyed by `recipeName` (`upsertRecipe()` overwrites on a matching name, else appends). Two code paths, chosen by `hasFSAccess = location.protocol !== 'file:' && !!(window.showSaveFilePicker && window.showOpenFilePicker)`:
- **Served over http(s)/localhost in a Chromium browser (File System Access API)**: "레시피 저장" opens `showSaveFilePicker` *once per session* to get a real `recipeFileHandle`, reads whatever's already in that file first (`readLibraryFromHandle`, so an existing `recipe.json` isn't clobbered), merges the current recipe in, then read-modify-writes the same file (`writeLibraryToHandle`) on every subsequent save/delete — a true single file, edited in place. "저장된 레시피 목록" opens `showOpenFilePicker` to (re)point `recipeFileHandle` at an existing `recipe.json` and list its contents.
- **Everything else — Safari/Firefox/mobile (no File System Access API), or this page opened directly via `file://`**: falls back to `downloadLibrary()` — re-downloading the *entire* library as `recipe.json` on every save/delete. The user has to replace their local copy with each new download (`#fsaHint` explains this in the UI when `!hasFSAccess`). "저장된 레시피 목록" instead triggers the hidden `<input type="file">` to read an existing `recipe.json` into memory for the session.

**Known trap, don't re-enable without a fix**: `window.showSaveFilePicker`/`showOpenFilePicker` *exist* and can even read via `getFile()` when this page is opened directly via `file://` (double-click, no server) — feature-detection alone says they're supported. But `FileSystemFileHandle.createWritable()` throws `NotAllowedError: ... not allowed by the user agent or the current context` for `file://` pages in Chrome, every time, with no permission prompt to fix it. Earlier code that only feature-detected (not protocol-checked) looked like it saved successfully (the picker flow completes, a toast shows) while silently leaving a 0-byte `recipe.json` on disk — the `location.protocol !== 'file:'` check above exists specifically to route around that trap. If you need to test the true in-place-write path, serve the file over `http://localhost` (see Running/testing) rather than opening it directly.

Either way, `applyRecipeToState()` is the single place that takes one library entry and pushes it into `state` + every plain input (`baseFlourInput`/`multInput`/`targetTotalInput`/mode/chips) before calling `render()` — this is the same shape as the old single-recipe load path, just now invoked per-row from the library list instead of from a whole-file picker. There's no schema migration beyond the `schema` string in the saved JSON.

## Design constraints (intentional — preserve these)

- **No external dependencies**: system font stacks only (`--font-display`, `--font-body`, `--font-mono` in `:root`), chosen deliberately for unreliable on-site wifi at bakery production lines. Do not introduce web fonts or CDN assets.
- **Color palette is deliberate, not arbitrary**: flour-linen background (`#E8E1D0`), ink text (`#2A241C`), stamp-red accent (`#B23A2E`), toasted-wheat gold (`#A9791F`) — chosen to reference physical bakery objects (order slips, weighing stamps, flour sacks) and explicitly avoid the generic "AI-generated" cream+terracotta or dark-mode+vivid-accent look. Keep new UI consistent with this palette.
- **Touch accessibility**: large tap targets (≥44px) for flour-dusted hands, `inputmode="decimal"` on numeric inputs to summon the numeric keypad, visible focus outlines. Preserve these when adding inputs/controls.
- **Sticky footer "stamp" badge**: a rotated circular badge showing the running total dough weight, always visible while scrolling — the signature UI element; don't remove or restructure without reason.
