#!/bin/bash
# 对比 meee2 三处凭证存储的 access token exp（所有 Supabase JWT 前缀相同，比前缀无意义）
set -u

decode_exp() {
  local token="$1"
  [ -z "$token" ] || [ "$token" = "null" ] && { echo "(empty)"; return; }
  local payload
  payload=$(echo "$token" | cut -d. -f2 | tr '_-' '/+')
  # base64 padding
  case $(( ${#payload} % 4 )) in 2) payload="${payload}==";; 3) payload="${payload}=";; esac
  local exp
  exp=$(echo "$payload" | base64 -d 2>/dev/null | jq -r '.exp // empty' 2>/dev/null)
  if [ -z "$exp" ]; then echo "(not a JWT / decode failed)"; return; fi
  echo "exp=$exp ($(date -r "$exp" '+%F %T'))"
}

tok_tail() {
  local token="$1"
  [ -z "$token" ] || [ "$token" = "null" ] && { echo "-"; return; }
  echo "...${token: -12}"
}

echo "== 1) ~/.meee2/settings.json (单一真相) =="
AT_FILE=$(jq -r '.meee2.accessToken // empty' ~/.meee2/settings.json 2>/dev/null)
RT_FILE=$(jq -r '.meee2.refreshToken // empty' ~/.meee2/settings.json 2>/dev/null)
AE_FILE=$(jq -r '.meee2.authExpired // false' ~/.meee2/settings.json 2>/dev/null)
echo "  access: $(tok_tail "$AT_FILE")  $(decode_exp "$AT_FILE")"
echo "  refresh tail: $(tok_tail "$RT_FILE")   authExpired: $AE_FILE"

echo "== 2) 偏好域 com.meee2.app (bundled app) =="
AT_APP=$(defaults read com.meee2.app meee2OnlineAccessToken 2>/dev/null || true)
RT_APP=$(defaults read com.meee2.app meee2OnlineRefreshToken 2>/dev/null || true)
echo "  access: $(tok_tail "$AT_APP")  $(decode_exp "$AT_APP")"
echo "  refresh tail: $(tok_tail "$RT_APP")"

echo "== 3) 偏好域 meee2 (SwiftPM debug 二进制) =="
AT_DBG=$(defaults read meee2 meee2OnlineAccessToken 2>/dev/null || true)
RT_DBG=$(defaults read meee2 meee2OnlineRefreshToken 2>/dev/null || true)
echo "  access: $(tok_tail "$AT_DBG")  $(decode_exp "$AT_DBG")"
echo "  refresh tail: $(tok_tail "$RT_DBG")"

echo
echo "== 结论 =="
if [ -n "$AT_FILE" ] && { [ "$AT_APP" = "$AT_FILE" ] || [ -z "$AT_APP" ]; } && { [ "$AT_DBG" = "$AT_FILE" ] || [ -z "$AT_DBG" ]; }; then
  echo "  一致（或偏好域已清空）✓"
else
  echo "  三处不一致 —— 偏好域存有分裂副本 ✗"
fi
