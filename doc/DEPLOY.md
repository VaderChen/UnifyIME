# DEPLOY

這份文件只描述 `src/unifyIME` 這條基線的 build / install / reload / notarize 流程。

專案根：
- `src/unifyIME`

安裝位置：
- `~/Library/Input Methods/全一輸入法.app`

保留原始輸入法：
- `~/Library/Input Methods/McBopomofo.app`

## 開發版

直接使用：
- `src/unifyIME/build.sh`

會做：
- build `UnifyIME`
- 覆蓋安裝到 `~/Library/Input Methods/全一輸入法.app`
- reload IME
- 啟動 candidate helper（預設隱藏，只有有內容才顯示）

注意：
- 開發版不 notarize
- 只適合日常功能開發與本機迭代
- `src/unifyIME/build.sh` 可直接 build，也可加 `--deploy` 安裝 / reload
- 若只想本機驗證，建議用 `--skip-sign --no-deploy`

## 正式版

直接使用：
- `build-release-notarize.command`

會做：
- build release
- notarize
- staple
- 覆蓋安裝
- reload

何時要跑：
- 要驗證系統輸入來源清單行為
- 要驗證正式簽章/發佈路徑

## Reload 原則

build 後一定要 reload。

目前做法：
- `src/unifyIME/build.sh` 已內建 reload
- 不要假設安裝後系統自動吃到新 binary

如果看到怪現象，先懷疑：
- 舊 IME 進程還在
- `TextInputMenuAgent` 沒刷新
- 你正在測的不是最新 build

## Candidate Helper

目前可見候選 UI 依賴 helper。

helper 啟動條件：
- 由 `build-dev.command` 啟動 app 的 `basicSelWindow` instance
- helper 自身預設隱藏
- 只有有組字或候選時才顯示

不要做的事：
- 不要在 build 完就主動塞內容讓 helper 顯示
- 不要把 helper 誤當成真正系統原生 candidate window

## 不要動的部署關鍵

除非是正式 identity migration，否則不要改：
- `CFBundleIdentifier`
- `TISInputSourceID`
- mode ID
- executable 名稱
- app 名稱

這些一改，TIS / LS / HIToolbox 快取就可能全部重來。

## 當 UI 怪掉時

先做這些，不要先改 code：

1. 重新跑：
- `src/unifyIME/build.sh`

2. 切到別的輸入法，再切回 `全一輸入法`

3. 若系統輸入來源清單或 TIS 視窗怪掉：
- 先關掉系統設定重開
- 必要時 logout/login

## 參考

- `doc/踩坑紀錄.md`
