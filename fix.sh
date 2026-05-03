#!/usr/bin/env bash
# Fix Japanese (CJK) character mojibake in Collaborator.app's xterm.js terminals.
#
# Symptom: Japanese characters overlap / clip in terminal panes.
# Root cause: hardcoded fontFamily 'Menlo, Monaco, "Courier New", monospace'
# in the renderer JS bundle has no CJK font, so the browser silently
# falls back to a non-monospaced glyph that doesn't match xterm.js's
# pre-calculated cell width. (Unicode 11 width calc itself is correct.)
# Fix: inject Hiragino Sans + Yu Gothic into the stack, repack asar,
# update Info.plist hash, ad-hoc re-sign.
#
# Usage:  ./fix.sh              -- apply
#         ./fix.sh --rollback   -- restore from .bak
#         ./fix.sh --check      -- inspect current state without modifying

set -euo pipefail

APP="${COLLAB_APP:-/Applications/Collaborator.app}"
RES="$APP/Contents/Resources"
ASAR="$RES/app.asar"
INFO="$APP/Contents/Info.plist"
WORK="${TMPDIR:-/tmp}/collab-cjk-fix"
SRC="$WORK/extracted"
NEW_ASAR="$WORK/app.asar.new"
ORIG_FONT="'Menlo, Monaco, \"Courier New\", monospace'"
NEW_FONT="'Menlo, Monaco, \"Hiragino Sans\", \"Yu Gothic\", \"Courier New\", monospace'"

die()  { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

[[ -d "$APP" ]] || die "$APP not found (override with COLLAB_APP=...)"
command -v node >/dev/null || die "node not in PATH"
command -v perl >/dev/null || die "perl not in PATH"

case "${1:-}" in
  --rollback)
    note "Rolling back from .bak"
    [[ -f "$ASAR.bak" ]] || die "no $ASAR.bak — nothing to roll back"
    [[ -f "$INFO.bak" ]] || die "no $INFO.bak"
    mv -f "$ASAR.bak" "$ASAR"
    mv -f "$INFO.bak" "$INFO"
    if [[ -d "$RES/app.asar.unpacked.bak" ]]; then
      rm -rf "$RES/app.asar.unpacked"
      mv "$RES/app.asar.unpacked.bak" "$RES/app.asar.unpacked"
    fi
    codesign --force --deep --sign - "$APP" 2>&1 | tail -3
    note "Rollback done. Restart Collaborator."
    exit 0
    ;;
  --check)
    note "Inspecting current asar"
    mkdir -p "$WORK" && cd "$WORK"
    [[ -f package.json ]] || npm init -y >/dev/null
    [[ -d node_modules/@electron/asar ]] || npm install @electron/asar >/dev/null 2>&1
    node -e "
const a=require('@electron/asar');
const list=a.listPackage('$ASAR').filter(p=>p.endsWith('.js')&&p.includes('renderer'));
const found=[];
for(const p of list){
  const data=a.extractFile('$ASAR',p.replace(/^\//,'')).toString();
  const m=data.match(/'Menlo[^']*'/);
  if(m) found.push([p,m[0]]);
}
found.forEach(([p,f])=>console.log('  '+p+'\n    '+f));
console.log('--- '+found.length+' files reference Menlo fontFamily.');
"
    exit 0
    ;;
esac

mkdir -p "$WORK" && cd "$WORK"
[[ -f package.json ]] || npm init -y >/dev/null
[[ -d node_modules/@electron/asar ]] || { note "Installing @electron/asar"; npm install @electron/asar >/dev/null 2>&1; }

note "Backing up app.asar + Info.plist"
[[ -f "$ASAR.bak" ]] || cp -p "$ASAR" "$ASAR.bak"
[[ -f "$INFO.bak" ]] || cp -p "$INFO" "$INFO.bak"

note "Extracting asar"
rm -rf "$SRC"
node -e "require('@electron/asar').extractAll('$ASAR','$SRC')"

note "Locating fontFamily reference (auto-discovers hashed filename)"
JSF=$(grep -rlF "$ORIG_FONT" "$SRC/out/renderer/assets/" 2>/dev/null | head -1 || true)
if [[ -z "$JSF" ]]; then
  if grep -rlF "$NEW_FONT" "$SRC/out/renderer/assets/" >/dev/null 2>&1; then
    die "already patched (found NEW_FONT). use --rollback first to re-apply."
  fi
  die "fontFamily string not found. Collaborator may have changed its font stack — inspect with --check."
fi
note "Patching $(basename "$JSF")"
ORIG="$ORIG_FONT" NEW="$NEW_FONT" perl -i -pe 's/\Q$ENV{ORIG}\E/$ENV{NEW}/g' "$JSF"
grep -qF "$NEW_FONT" "$JSF" || die "perl replace failed"

note "Repacking asar (preserving original unpack pattern)"
node -e "
require('@electron/asar').createPackageWithOptions(
  '$SRC', '$NEW_ASAR',
  { unpackDir: 'node_modules/{node-pty,@parcel/watcher,@parcel/watcher-darwin-arm64,@img/sharp-darwin-arm64,@img/sharp-libvips-darwin-arm64,@anthropic-ai/claude-agent-sdk}' }
).then(()=>console.log('  repack OK')).catch(e=>{console.error(e);process.exit(1)});
"

ORIG_UP=$(node -e "
const a=require('@electron/asar');const j=JSON.parse(a.getRawHeader('$ASAR.bak').headerString);
let n=0;(function w(o){for(const v of Object.values(o.files||{})){if(v.unpacked&&v.files)n++;if(v.files)w(v)}})(j);console.log(n)")
NEW_UP=$(node -e "
const a=require('@electron/asar');const j=JSON.parse(a.getRawHeader('$NEW_ASAR').headerString);
let n=0;(function w(o){for(const v of Object.values(o.files||{})){if(v.unpacked&&v.files)n++;if(v.files)w(v)}})(j);console.log(n)")
note "Unpacked dir count: original=$ORIG_UP  new=$NEW_UP"
[[ "$ORIG_UP" == "$NEW_UP" ]] || echo "  WARN: unpacked dir count differs"

note "Atomic install of new asar"
mv "$NEW_ASAR" "$ASAR"
if [[ -d "$WORK/app.asar.unpacked" ]]; then
  rm -rf "$RES/app.asar.unpacked.bak"
  [[ -d "$RES/app.asar.unpacked" ]] && mv "$RES/app.asar.unpacked" "$RES/app.asar.unpacked.bak"
  mv "$WORK/app.asar.unpacked" "$RES/app.asar.unpacked"
fi

note "Updating ElectronAsarIntegrity SHA256 in Info.plist"
NEW_HASH=$(shasum -a 256 "$ASAR" | awk '{print $1}')
/usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $NEW_HASH" "$INFO"
echo "  $NEW_HASH"

note "Re-signing ad-hoc (Developer ID is invalidated by modification)"
codesign --remove-signature "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP" 2>&1 | tail -2

note "Verifying signature (--strict)"
codesign --verify --strict "$APP" && echo "  OK"

cat <<MSG

DONE.
  - Quit and reopen Collaborator to see the fix take effect.
  - Rollback: $0 --rollback
  - Inspect:  $0 --check
MSG
