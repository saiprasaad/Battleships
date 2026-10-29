#!/usr/bin/env bash
# Lints the iOS app's motion code. Runs in CI on Linux (no Xcode needed) and locally:
#
#     iOSApp/Tools/lint_motion.sh
#
# Fails on:
#   - `.repeatForever(`: every loop must run on a capped clock that pauses;
#   - `UIScreen.main`: deprecated; the screen comes from the window scene;
#   - inline spring literals (`.spring(duration:` / `Animation.spring(`) outside MotionTokens.swift:
#     feature code names a `Motion.Curve` token;
#   - `TimelineView(.animation)` or `.animation(minimumInterval: nil`: every timeline is capped;
#   - more inline ease/linear-with-duration literals in a file than its baseline below allows, so
#     legacy call sites stay green until they are migrated and no new ones appear.
set -u
cd "$(dirname "$0")/../Battleships" || exit 1

status=0
fail() { echo "lint_motion: $1"; status=1; }

# Greps the sources, dropping comment-only lines and trailing comments, so a rule named in a doc
# comment doesn't trip it. Callers grep the result again for the pattern itself.
code() { grep -rn --include='*.swift' "$@" . | grep -v ':[[:space:]]*//' | sed 's|//.*||'; }

if hits=$(code -F '.repeatForever(' | grep -F '.repeatForever('); then
    fail "repeatForever is not allowed; use a LoopClock that pauses:"; echo "$hits"
fi
if hits=$(code -F 'UIScreen.main' | grep -F 'UIScreen.main'); then
    fail "UIScreen.main is deprecated; read the window scene's screen:"; echo "$hits"
fi
if hits=$(code -F '.spring(' | grep -F '.spring(' | grep -v 'Views/Components/MotionTokens.swift' | grep -v 'SpringKeyframe\|spring: \.'); then
    fail "inline springs belong in Motion.Curve (Views/Components/MotionTokens.swift):"; echo "$hits"
fi
if hits=$(code -F 'TimelineView(.animation' | grep -E 'TimelineView\(\.animation\)|TimelineView\(\.animation\(paused|minimumInterval: nil'); then
    fail "every TimelineView must be capped with a minimumInterval:"; echo "$hits"
fi

# Inline ease literals: a per-file baseline. Lower a number when a file is migrated; never raise one.
declare -A baseline=(
    ["Services/TiltSensor.swift"]=1
    ["Views/Board/BoardView.swift"]=6
    ["Views/Board/Effects.swift"]=2
    ["Views/Components/Toast.swift"]=1
)
while IFS=: read -r file count; do
    [ -z "$file" ] && continue
    allowed=${baseline[$file]:-0}
    if [ "$count" -gt "$allowed" ]; then
        fail "$file has $count inline ease/linear(duration:) literals, baseline $allowed; name a Motion.Curve token"
    fi
done < <(code -e 'easeInOut(duration:' -e 'easeIn(duration:' -e 'easeOut(duration:' -e 'linear(duration:' \
    | grep -E 'ease(InOut|In|Out)\(duration:|linear\(duration:' \
    | grep -v 'Views/Components/MotionTokens.swift' \
    | cut -d: -f1 | sed 's|^\./||' | sort | uniq -c | awk '{print $2 ":" $1}')

if [ "$status" -eq 0 ]; then
    echo "lint_motion: clean"
fi
exit "$status"
