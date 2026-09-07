#!/bin/zsh
# 共用產物清理：只處理專案根目錄下的 dist。
clear_project_dist() {
  local project_directory="${1:A}"
  local dist_directory="$project_directory/dist"
  if [[ -L "$dist_directory" || ( -e "$dist_directory" && ! -d "$dist_directory" ) ]]; then
    print -u2 "dist 必須是實體目錄：$dist_directory"
    return 1
  fi
  mkdir -p "$dist_directory"
  local entry
  for entry in "$dist_directory"/*(DN); do
    /bin/rm -rf -- "$entry"
  done
  print "已清空：$dist_directory"
}
