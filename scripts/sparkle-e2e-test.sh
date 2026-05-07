#!/bin/bash
# scripts/sparkle-e2e-test.sh
#
# Dev e2e test for the Sparkle silent-update flow. Runs against a *deployed*
# /Applications/meee2.app whose Info.plist version has been forced to 0.3.0
# (so 0.4.1 from the public appcast looks "newer"). Polls /api/version while
# poking the test endpoints and asserts state transitions.
#
# Pre-flight (do these once before running this script):
#
#   ./scripts/sparkle-e2e-test.sh setup
#
# That deploys current source build to /Applications/meee2.app, patches the
# version to 0.3.0, clears the WebDist override, and (re)launches the app.
# Then run individual scenarios:
#
#   ./scripts/sparkle-e2e-test.sh scenario1   # 每小时轮询拿到 latest
#   ./scripts/sparkle-e2e-test.sh scenario2   # 静默后台下载被触发
#   ./scripts/sparkle-e2e-test.sh scenario3   # staged → pill 出现
#   ./scripts/sparkle-e2e-test.sh scenario4   # pill 点击 → 秒重启(不动 binary)
#   ./scripts/sparkle-e2e-test.sh scenario5   # staged 过时 → discard + fresh
#   ./scripts/sparkle-e2e-test.sh all         # 跑 1+2+3+5(4 会真重启,默认跳)

set -e

API="http://127.0.0.1:9876"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── helpers ────────────────────────────────────────────────────────────

c_red() { printf "\033[31m%s\033[0m" "$1"; }
c_grn() { printf "\033[32m%s\033[0m" "$1"; }
c_yel() { printf "\033[33m%s\033[0m" "$1"; }
c_dim() { printf "\033[2m%s\033[0m" "$1"; }

step() { echo; echo "$(c_yel "▶ $*")"; }
ok() { echo "  $(c_grn "✓") $*"; }
fail() { echo "  $(c_red "✗") $*"; exit 1; }
info() { echo "  $(c_dim "$*")"; }

api_get_version() {
    curl -s "$API/api/version"
}

api_field() {
    curl -s "$API/api/version" | python3 -c "import json,sys;print(json.load(sys.stdin).get('$1', ''))" 2>/dev/null
}

assert_field() {
    local field="$1" expect="$2"
    local actual
    actual=$(api_field "$field")
    if [ "$actual" = "$expect" ]; then
        ok "$field == $expect"
    else
        fail "$field expected=$expect actual=$actual (full: $(api_get_version))"
    fi
}

# poll until $1 field equals $2 value, timeout $3 seconds. echoes elapsed time on success.
poll_until() {
    local field="$1" expect="$2" timeout="${3:-90}"
    local started=$SECONDS
    while [ $((SECONDS - started)) -lt "$timeout" ]; do
        local actual
        actual=$(api_field "$field")
        if [ "$actual" = "$expect" ]; then
            echo $((SECONDS - started))
            return 0
        fi
        sleep 2
    done
    fail "timeout($timeout s) waiting for $field == $expect (last: $(api_get_version))"
}

require_meee2_running() {
    if ! curl -sf "$API/api/health" >/dev/null; then
        fail "meee2 not running on $API. Run: $0 setup"
    fi
}

# ── setup ──────────────────────────────────────────────────────────────

cmd_setup() {
    step "Building Swift release..."
    cd "$PROJECT_ROOT"
    swift build -c release | tail -3
    ok "swift build done"

    step "Building web bundle..."
    cd "$PROJECT_ROOT/packages/board-app"
    pnpm build 2>&1 | tail -3
    ok "pnpm build done"
    cd "$PROJECT_ROOT"

    step "Killing old meee2 process..."
    pkill -9 -f "meee2.app/Contents/MacOS/meee2" 2>/dev/null || true
    sleep 2

    step "Deploying to /Applications/meee2.app..."
    bash deploy.sh 2>&1 | tail -3

    step "Replacing WebDist (deploy.sh's flat layout doesn't override Bundle.module nested path)..."
    rm -rf /Applications/meee2.app/Contents/Resources/meee2_meee2Kit.bundle/WebDist
    cp -R "$PROJECT_ROOT/Sources/Board/WebDist" /Applications/meee2.app/Contents/Resources/meee2_meee2Kit.bundle/WebDist

    step "Forcing version to 0.3.0 (so 0.4.1 from real appcast looks newer)..."
    plutil -replace CFBundleShortVersionString -string "0.3.0" /Applications/meee2.app/Contents/Info.plist
    plutil -replace CFBundleVersion -string "0.3.0" /Applications/meee2.app/Contents/Info.plist

    step "Clearing application-support WebDist override..."
    rm -rf "$HOME/Library/Application Support/meee2/WebDist"

    step "Killing any lingering app + launching fresh..."
    pkill -9 -f "meee2.app/Contents/MacOS/meee2" 2>/dev/null || true
    sleep 2
    open /Applications/meee2.app
    sleep 5

    step "Verifying API alive + correct version..."
    require_meee2_running
    assert_field "current" "0.3.0"
    assert_field "latest" "0.4.1"
    assert_field "hasUpdate" "True"
    assert_field "isStaged" "False"
    info "Initial state OK. Now run scenarios."
}

# ── scenarios ──────────────────────────────────────────────────────────

# 每小时轮询拿到 latest version。VersionChecker.shared 在 AppDelegate 启动时
# 会发起一次 immediate check,latestVersion 应该立刻填上。这里只 verify
# 当前状态 — 真"每小时"那个间隔(checkInterval=6h)在测试里不实际等。
cmd_scenario1() {
    step "Scenario 1: 每小时轮询拿到 latest"
    require_meee2_running
    assert_field "current" "0.3.0"
    assert_field "latest" "0.4.1"
    assert_field "hasUpdate" "True"
    info "VersionChecker.shared 已经从 raw.githubusercontent appcast 拿到 0.4.1"
    info "(实际间隔 = VersionChecker.checkInterval=6h + Sparkle SUScheduledCheckInterval=1h)"
    ok "scenario 1 passed"
}

# 测试静默下载被触发。验证 isStaged 在 Sparkle bg cycle 后会翻成 true。
cmd_scenario2() {
    step "Scenario 2: 静默后台下载被触发"
    require_meee2_running
    assert_field "isStaged" "False"
    info "POST /api/update/check-in-background — 触发 Sparkle silent download cycle..."
    curl -s -X POST "$API/api/update/check-in-background" >/dev/null
    info "等待 Sparkle 下载 + 验签 + stage(~10-30s)..."
    elapsed=$(poll_until "isStaged" "True" 90)
    ok "isStaged → True (took ${elapsed}s)"
    info "stagedVersion = $(api_field stagedVersion)"
}

# 验证 staged 后 stagedVersion 字段填上了。
cmd_scenario3() {
    step "Scenario 3: staged 完成 → pill 应该出现"
    require_meee2_running
    if [ "$(api_field isStaged)" != "True" ]; then
        info "isStaged 还不是 True,先跑 scenario2 把包 stage 了..."
        cmd_scenario2
    fi
    local sv
    sv=$(api_field "stagedVersion")
    if [ -z "$sv" ] || [ "$sv" = "None" ]; then
        fail "stagedVersion 应该有值,实际: '$sv' (full: $(api_get_version))"
    fi
    ok "stagedVersion = $sv (前端 UpdatePill 应该已经渲染)"
    info "你可以打开 Board(menubar → Open Board)看 sidebar 顶部的蓝色 Update pill"
}

# **危险**:这个 scenario 会真重启 app 到 0.4.1,导致后续 scenario 跑不了
# (deployed binary 被覆盖回 release 版,/api/_dev/* 端点不存在)。默认不跑
# 在 cmd_all 里,只在显式 `$0 scenario4` 时跑。
cmd_scenario4() {
    step "Scenario 4: pill 点击(staged 包是最新)→ 秒重启"
    echo "  $(c_red '⚠')  这会真重启 app 到 0.4.1,后续 scenario 跑不了!"
    read -p "  继续? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "skipped"; return 0; }
    require_meee2_running
    if [ "$(api_field isStaged)" != "True" ]; then
        info "先 stage..."
        cmd_scenario2
    fi
    local before_pid
    before_pid=$(pgrep -f "meee2.app/Contents/MacOS/meee2" | head -1)
    info "PID 开始: $before_pid"
    info "POST /api/update/install — 触发 confirmPendingInstall..."
    curl -s -X POST "$API/api/update/install" >/dev/null
    info "等待 app 重启..."
    sleep 8
    local after_pid
    after_pid=$(pgrep -f "meee2.app/Contents/MacOS/meee2" | head -1)
    info "PID 结束: $after_pid"
    if [ "$before_pid" = "$after_pid" ]; then
        fail "PID 没变 — Sparkle 没重启 app"
    fi
    ok "PID 变了($before_pid → $after_pid)— Sparkle 重启成功"
    info "现在装的是真正的 0.4.1 release(没 /api/_dev 端点);要继续测试请重跑 setup"
}

# Staged 0.4.1 后,假造 latest=0.4.99(假定 release 出了更新版)。然后
# 调用 /api/update/install。预期:driver 检测 stagedVersion(0.4.1) !=
# latest(0.4.99),discard pending,起 fresh checkForUpdates。Fresh check
# 找不到 0.4.99 的 DMG(假版本,appcast 里没有),所以 cycle 会有错误日志,
# 但关键是 isStaged 翻回 false 表明 discard 生效了。
# Dry-run scenario:用 /api/_dev/pill-click-plan 验证逻辑分支选对,
# 不实际触发 install。
cmd_scenario5() {
    step "Scenario 5: staged 过时 → 应该走 discard_and_recheck 分支(dry-run)"
    require_meee2_running
    if [ "$(api_field isStaged)" != "True" ]; then
        info "先 stage..."
        cmd_scenario2
    fi
    local sv
    sv=$(api_field "stagedVersion")
    info "staged version = $sv,latest = $(api_field latest)"

    info "Plan with staged==latest:"
    local plan
    plan=$(curl -s "$API/api/_dev/pill-click-plan")
    echo "  $plan"
    if echo "$plan" | grep -q '"plan":"instant_install"'; then
        ok "staged 跟 latest 一致 → instant_install ✓"
    else
        fail "expected plan=instant_install when staged==latest, got: $plan"
    fi

    info "POST /api/_dev/override-latest?version=0.4.99(假造远端出了更新版)..."
    curl -s -X POST "$API/api/_dev/override-latest?version=0.4.99" >/dev/null
    sleep 1
    assert_field "latest" "0.4.99"

    info "Plan with staged != latest:"
    plan=$(curl -s "$API/api/_dev/pill-click-plan")
    echo "  $plan"
    if echo "$plan" | grep -q '"plan":"discard_and_recheck"'; then
        ok "staged 跟 latest 不一致 → discard_and_recheck ✓(用户点 pill 会 discard 旧 reply 起 fresh check)"
    else
        fail "expected plan=discard_and_recheck when stale, got: $plan"
    fi

    info "清掉 override..."
    curl -s -X POST "$API/api/_dev/override-latest" >/dev/null
    sleep 1
    assert_field "latest" "0.4.1"
    ok "scenario 5 passed(discard 分支被识别)"
}

cmd_all() {
    cmd_scenario1
    cmd_scenario2
    cmd_scenario3
    info ""
    info "Skip scenario4(会重启 app)。要测请单独跑: $0 scenario4"
    info ""
    cmd_scenario5
    echo
    echo "$(c_grn '✅ All non-destructive scenarios passed.')"
}

cmd_status() {
    step "Current state:"
    api_get_version | python3 -m json.tool
}

# ── main ───────────────────────────────────────────────────────────────

case "${1:-}" in
    setup) cmd_setup ;;
    scenario1) cmd_scenario1 ;;
    scenario2) cmd_scenario2 ;;
    scenario3) cmd_scenario3 ;;
    scenario4) cmd_scenario4 ;;
    scenario5) cmd_scenario5 ;;
    all) cmd_all ;;
    status) cmd_status ;;
    *)
        cat <<EOF
Sparkle silent-update e2e tester.

Usage: $0 <command>

  setup       Build + deploy + force version 0.3.0 + relaunch app
  status      Print current /api/version JSON

Scenarios (run after setup):
  scenario1   每小时轮询拿到 latest version
  scenario2   静默后台下载被触发(POST /api/update/check-in-background)
  scenario3   staged 完成 → stagedVersion 填好(pill 应该渲染)
  scenario4   ⚠️ pill 点击 → 秒重启(会真重启,后续 scenario 跑不了)
  scenario5   staged 过时(假 latest=0.4.99)→ discard + fresh check

  all         跑 scenario1+2+3+5(跳过 4)
EOF
        exit 1
        ;;
esac
