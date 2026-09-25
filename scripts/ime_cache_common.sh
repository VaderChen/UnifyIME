#!/bin/zsh
# 共用輸入法快取清理：清除沙盒 App 各自保存的過期輸入來源快取。
# macOS 會在 DARWIN_USER_CACHE_DIR/<bundle id>/ 為每個沙盒 App 另存 com.apple.IntlDataCache.le(.kbdx)。
# 快取若建立於輸入法安裝或搬移之前，該 App 會回報 "unresolvable input source"，選了輸入法也會跳回 ABC。
# 用法：clear_stale_input_source_caches <已安裝的 .app 路徑> [--dry-run]
clear_stale_input_source_caches() {
  local install_dir="${1:A}"
  local dry_run="${2:-}"
  local cache_root
  cache_root="$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null)" || return 0
  cache_root="${cache_root%/}"
  [[ -d "$cache_root" ]] || return 0

  local kbdx app_cache_dir bundle_id asn
  local -a cleared running
  # 只看各 App 子目錄；最上層的共用快取由系統在註冊輸入法時重建。
  for kbdx in "$cache_root"/*/com.apple.IntlDataCache.le.kbdx(N); do
    if LC_ALL=C grep -aqF -- "$install_dir" "$kbdx"; then
      continue
    fi
    app_cache_dir="${kbdx:h}"
    bundle_id="${app_cache_dir:t}"
    if [[ "$dry_run" != "--dry-run" ]]; then
      /bin/rm -f -- "$app_cache_dir/com.apple.IntlDataCache.le" "$app_cache_dir/com.apple.IntlDataCache.le.kbdx"
    fi
    cleared+=("$bundle_id")
    # 只提示有視窗的前景 App；延伸功能與背景代理程式不需手動重開。
    asn="$(lsappinfo find bundleid="$bundle_id" 2>/dev/null)"
    asn="${asn%% *}"
    if [[ -n "$asn" ]] && lsappinfo info -only ApplicationType "$asn" 2>/dev/null | grep -q '"Foreground"'; then
      running+=("$bundle_id")
    fi
  done

  local action="已清除"
  [[ "$dry_run" == "--dry-run" ]] && action="將清除（dry-run）"
  print "${action}過期輸入法快取：${#cleared} 個 App"
  if (( ${#running} > 0 )); then
    print "以下 App 正在執行，需重新開啟才會看到新的輸入法："
    print -l -- "  "${^running}
  fi
  return 0
}
