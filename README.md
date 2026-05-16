# collaborator-cjk-fix

Patch script that fixes Japanese / CJK character mojibake (overlapping glyphs)
in the xterm.js terminal panes of [Collaborator.app](https://collaborator.dev)
on macOS.

Tested on Collaborator **0.8.0** (`com.collaborator.desktop`, signed by
`Yiliu Shen-Burke (93MDU2WLAD)`, notarized).

## Symptom

Japanese characters in terminal tiles overlap / clip into the next column,
making the output unreadable. Latin/ASCII characters render fine. The bug
appears regardless of which CLI is running inside the terminal (tested with
`claude`, `vim`, `tmux`, plain `cat`).

## Root cause

The renderer JS bundle hardcodes the xterm.js `fontFamily` option as:

```js
fontFamily: 'Menlo, Monaco, "Courier New", monospace'
```

None of those fonts contain CJK glyphs. When xterm.js measures a cell's
width it uses Menlo (an ASCII-only monospace), so each cell is sized for
a half-width Latin char. When the page actually paints a Japanese
character, the browser silently falls back to a system CJK font
(Hiragino Sans on macOS) — but those glyphs are wider than the
calculated cell, so adjacent cells visually collide.

The xterm.js Unicode 11 addon **is already loaded and active** in
Collaborator (`term.unicode.activeVersion = "11"`), so the integer
"this codepoint takes 2 cells" calculation is correct. The mismatch is
purely at the glyph-metrics level.

## Fix

Inject CJK fonts into every Menlo-prefixed family stack in the bundle so
the browser picks a known CJK font with predictable metrics instead of an
arbitrary fallback:

```diff
- fontFamily: 'Menlo, Monaco, "Courier New", monospace'
+ fontFamily: 'Menlo, Monaco, "Hiragino Sans", "Yu Gothic", "Courier New", monospace'
```

This applies to **two** places in the bundle:

| File | Why |
|------|-----|
| `out/renderer/assets/TerminalTab-*.js` | xterm.js terminal panes |
| `node_modules/monaco-editor/esm/vs/editor/common/config/fontInfo.js` | Monaco editor's `DEFAULT_MAC_FONT_FAMILY` — used by the chat panel's code blocks, file diff viewer, etc. |

The patch is non-trivial because the JS bundle lives inside `app.asar`
which is integrity-checked:

1. Extract `app.asar`.
2. Find every `'Menlo...'` single-quoted string (escape-aware regex,
   handles `'Menlo, Monaco, \'Courier New\', monospace'` correctly).
3. Inject `"Hiragino Sans", "Yu Gothic"` after the leading `Menlo,` of
   each stack. Idempotent — already-CJK stacks are skipped.
4. Repack `app.asar`, preserving the original "unpacked" pattern
   (node-pty, sharp, @parcel/watcher, claude-agent-sdk — these contain
   native binaries that must stay outside the asar).
5. Recompute the SHA256 and write it into `Info.plist`'s
   `ElectronAsarIntegrity` dict.
6. Strip the (now-invalid) Developer ID signature and ad-hoc re-sign.

## Usage

```sh
git clone https://github.com/szo444/collaborator-cjk-fix
cd collaborator-cjk-fix

./fix.sh             # apply the patch
./fix.sh --check     # show every Menlo-prefixed stack and its patch state
./fix.sh --restart   # apply, then quit + relaunch Collaborator atomically
./fix.sh --rollback  # restore from .bak files
```

After `./fix.sh` (without `--restart`) you **must** quit and reopen
Collaborator — the running renderer has the OLD font in memory and won't
re-read the asar until launch. `--check` prints a clear warning when it
detects Collaborator is still running.

The patch script keeps `app.asar.bak`, `Info.plist.bak`, and
`app.asar.unpacked.bak` next to the originals so rollback is a single
command.

### Requirements

- macOS (tested on Sequoia)
- `node` (any recent LTS) and `npm`
- `perl` (preinstalled on macOS)
- Write access to `/Applications/Collaborator.app` (no `sudo` needed
  if you installed Collaborator into your own `/Applications`)

To target a different install location:

```sh
COLLAB_APP=/path/to/Collaborator.app ./fix.sh
```

## Caveats

- **Updates wipe the patch.** Each new Collaborator release ships a new
  `app.asar`, so you have to re-run `./fix.sh` after every update.
  The script auto-discovers Menlo-prefixed stacks anywhere in the bundle
  (escape-aware), so it survives minor version bumps and any tweaks
  Collaborator makes to the exact font string. If Collaborator
  switches to a non-Menlo monospace baseline, `./fix.sh --check` will
  report 0 stacks found — at that point inspect the asar manually.
- **Patch is invisible until restart.** The running Collaborator
  renderer keeps the OLD font stack in memory. Quit + reopen, or use
  `--restart`.
- **Signature.** The original Developer ID signature is destroyed by
  the modification. The script ad-hoc re-signs so the app still
  launches. Notarization is gone, but Gatekeeper won't re-check an
  app you already opened. If you ever move the .app between machines,
  you may need to `xattr -cr /Applications/Collaborator.app` on the
  destination.
- **Upstream fix.** This is a workaround. The proper fix is for
  Collaborator to add CJK fonts (or a user-configurable font setting)
  to the bundled font stack. File an issue if you can.

## License

MIT.
