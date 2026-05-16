#!/usr/bin/env bash
# Fix Japanese (CJK) character mojibake in Collaborator.app's xterm.js terminals.
#
# Symptom: Japanese characters overlap / clip in terminal panes.
# Root cause: hardcoded fontFamily 'Menlo, Monaco, ...' in the renderer JS
# bundle has no CJK font, so the browser silently falls back to a glyph
# that doesn't match xterm.js's pre-calculated cell width.
# Fix: inject Hiragino Sans + Yu Gothic into the stack(s), repack asar,
# update Info.plist hash, ad-hoc re-sign. Does NOT depend on exact
# ORIGINAL font string — discovers any Menlo-prefixed fontFamily and
# patches it idempotently. Survives Collaborator minor-version bumps that
# tweak the stack.
#
# Usage:  ./fix.sh              -- apply
#         ./fix.sh --rollback   -- restore from .bak
#         ./fix.sh --check      -- inspect current state without modifying
#         ./fix.sh --restart    -- apply, then quit + relaunch Collaborator
#
# After --apply (without --restart), you MUST quit and reopen Collaborator
# manually. The patch is invisible until the renderer reloads the asar.

set -euo pipefail

APP="${COLLAB_APP:-/Applications/Collaborator.app}"
RES="$APP/Contents/Resources"
ASAR="$RES/app.asar"
INFO="$APP/Contents/Info.plist"
WORK="${TMPDIR:-/tmp}/collab-cjk-fix"
SRC="$WORK/extracted"
NEW_ASAR="$WORK/app.asar.new"

# CJK fonts to inject into any Menlo-prefixed stack we find.
# Order matters: keep Menlo/Monaco first so ASCII cell-width is monospaced,
# then Hiragino/YuGothic so CJK chars fall back to a glyph that fits inside
# the 2-cell (East Asian Wide) box.
CJK_INJECT='"Hiragino Sans", "Yu Gothic"'

die()  { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

[[ -d "$APP" ]] || die "$APP not found (override with COLLAB_APP=...)"
command -v node >/dev/null || die "node not in PATH"
command -v perl >/dev/null || die "perl not in PATH"

ensure_asar_module() {
  mkdir -p "$WORK" && cd "$WORK"
  [[ -f package.json ]] || npm init -y >/dev/null
  [[ -d node_modules/@electron/asar ]] || {
    note "Installing @electron/asar (one-time)"
    npm install @electron/asar >/dev/null 2>&1
  }
}

is_collab_running() {
  # `pgrep -f` with long paths is unreliable on macOS BSD pgrep; use ps instead.
  # Avoid `grep -q` here: under `set -o pipefail` it closes the pipe early on
  # match, ps receives SIGPIPE (141), and the function would falsely return
  # non-zero. Buffer to a tmpfile, then grep without -q.
  local tmp
  tmp=$(mktemp -t collab-running.XXXXXX) || return 1
  ps -ax -o command= 2>/dev/null > "$tmp" || true
  local hit
  hit=$(grep -c "Collaborator.app/Contents/" "$tmp" || true)
  rm -f "$tmp"
  [[ "${hit:-0}" -gt 0 ]]
}

quit_collab() {
  if ! is_collab_running; then
    note "Collaborator not running — skip quit"
    return 0
  fi
  note "Quitting Collaborator (osascript)"
  osascript -e 'tell application "Collaborator" to quit' >/dev/null 2>&1 || true
  for i in {1..20}; do
    is_collab_running || { note "Quit OK"; return 0; }
    sleep 0.5
  done
  warn "Collaborator did not quit gracefully — sending SIGTERM"
  ps -ax -o pid=,command= | awk '/Collaborator.app\/Contents\// {print $1}' | xargs -r kill -TERM 2>/dev/null || true
  sleep 1
  if is_collab_running; then
    warn "Still running — sending SIGKILL"
    ps -ax -o pid=,command= | awk '/Collaborator.app\/Contents\// {print $1}' | xargs -r kill -KILL 2>/dev/null || true
    sleep 1
  fi
}

launch_collab() {
  note "Launching Collaborator"
  open -a "$APP"
}

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
    ensure_asar_module
    node -e "
const a=require('@electron/asar');
const list=a.listPackage('$ASAR').filter(p=>p.endsWith('.js'));
const found=[];
for(const p of list){
  let data;
  try { data=a.extractFile('$ASAR',p.replace(/^\//,'')).toString(); }
  catch(e){ continue; }
  // Match any single-quoted string starting with 'Menlo', honoring JS escape syntax (\\\\ , \\').
  const re=/'Menlo(?:[^'\\\\]|\\\\.)*'/g;
  let m;
  while((m=re.exec(data))!==null) found.push([p,m[0]]);
}
const patched = found.filter(([,f])=>/Hiragino|Yu Gothic/.test(f));
const unpatched = found.filter(([,f])=>!/Hiragino|Yu Gothic/.test(f));
console.log('--- patched stacks (Hiragino/Yu Gothic present) ---');
patched.forEach(([p,f])=>console.log('  '+p+'\n    '+f));
console.log('--- unpatched stacks (need fixing) ---');
unpatched.forEach(([p,f])=>console.log('  '+p+'\n    '+f));
console.log('Summary: '+patched.length+' patched, '+unpatched.length+' unpatched.');
process.exit(unpatched.length>0?2:0);
"
    ec=$?
    echo "---"
    [[ -f "$ASAR.bak" ]] && note ".bak exists ($(stat -f '%Sm' "$ASAR.bak"))" || note "no .bak yet"
    if is_collab_running; then
      warn "Collaborator IS RUNNING — patches won't apply until you quit & reopen it."
    else
      note "Collaborator not running — next launch will pick up patched asar."
    fi
    exit $ec
    ;;
  --restart)
    DO_RESTART=1
    ;;
  "")
    DO_RESTART=0
    ;;
  *)
    die "unknown flag: $1 (use --check / --rollback / --restart)"
    ;;
esac

ensure_asar_module

note "Backing up app.asar + Info.plist"
[[ -f "$ASAR.bak" ]] || cp -p "$ASAR" "$ASAR.bak"
[[ -f "$INFO.bak" ]] || cp -p "$INFO" "$INFO.bak"

note "Extracting asar"
rm -rf "$SRC"
node -e "require('@electron/asar').extractAll('$ASAR','$SRC')"

note "Discovering Menlo-prefixed fontFamily stacks (any variant)"
# Search BOTH renderer assets (TerminalTab) and node_modules (monaco-editor default).
# Bash 3.x compatible: feed via tmpfile rather than mapfile.
TARGET_LIST="$WORK/targets.txt"
{ grep -rlE "'Menlo" "$SRC/out/renderer/" 2>/dev/null || true;
  grep -rlE "'Menlo" "$SRC/node_modules/monaco-editor/" 2>/dev/null || true;
} | sort -u > "$TARGET_LIST"
if [[ ! -s "$TARGET_LIST" ]]; then
  die "no 'Menlo...' fontFamily found. Bundle layout may have changed; run --check to inspect."
fi

PATCHED_COUNT=0
SKIPPED_COUNT=0
while IFS= read -r f; do
  rel="${f#$SRC/}"
  # Extract first matching stack (with proper escape handling) for diagnostics + patch decision
  stack=$(perl -0777 -ne 'while(/('"'"'Menlo(?:[^'"'"'\\]|\\.)*'"'"')/g){print "$1\n"; last}' "$f")
  if [[ -z "$stack" ]]; then
    note "  [skip] $rel — Menlo present but not as a single-quoted string literal"
    continue
  fi
  if [[ "$stack" == *"Hiragino"* || "$stack" == *"Yu Gothic"* ]]; then
    note "  [skip] $rel — already has CJK fonts"
    SKIPPED_COUNT=$((SKIPPED_COUNT+1))
    continue
  fi
  note "  [patch] $rel"
  note "    before: $stack"
  # Replace EVERY 'Menlo...' single-quoted string (escape-aware) by injecting
  # CJK_INJECT right after the leading "Menlo, " prefix.
  CJK_INJECT="$CJK_INJECT" perl -0777 -i -pe '
    s{('"'"')Menlo,\s*((?:[^'"'"'\\]|\\.)*?)('"'"')}{
      my ($q1,$mid,$q2)=($1,$2,$3);
      if ($mid =~ /Hiragino|Yu Gothic/) {
        $&;
      } else {
        "${q1}Menlo, $ENV{CJK_INJECT}, ${mid}${q2}";
      }
    }ge;
  ' "$f"
  newstack=$(perl -0777 -ne 'while(/('"'"'Menlo(?:[^'"'"'\\]|\\.)*'"'"')/g){print "$1\n"; last}' "$f")
  note "    after:  $newstack"
  if [[ "$newstack" != *"Hiragino"* ]]; then
    die "perl rewrite failed on $rel — bundle structure unexpected"
  fi
  PATCHED_COUNT=$((PATCHED_COUNT+1))
done < "$TARGET_LIST"

if [[ $PATCHED_COUNT -eq 0 && $SKIPPED_COUNT -gt 0 ]]; then
  note "All targets already patched. Nothing to do."
  # Still re-pack if user wants? No — exit early to avoid needless re-sign churn.
  exit 0
fi

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
[[ "$ORIG_UP" == "$NEW_UP" ]] || warn "unpacked dir count differs — investigate if app misbehaves"

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
  - Patched $PATCHED_COUNT file(s); skipped $SKIPPED_COUNT already-patched.
  - Rollback: $0 --rollback
  - Inspect:  $0 --check
MSG

if [[ "${DO_RESTART:-0}" -eq 1 ]]; then
  echo
  quit_collab
  launch_collab
  note "Done. Collaborator relaunched with patched asar."
elif is_collab_running; then
  cat <<MSG

>>> Collaborator IS CURRENTLY RUNNING. <<<
The patched asar is on disk, but the running renderer still has the OLD
font in memory. You MUST quit and reopen Collaborator (or run this script
with --restart) for the fix to actually take effect.

Quit + reopen:    osascript -e 'tell application "Collaborator" to quit' && sleep 2 && open -a Collaborator
Or:               $0 --restart
MSG
fi
