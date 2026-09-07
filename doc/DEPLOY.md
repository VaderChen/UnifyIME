# DEPLOY

這份文件只描述 `src/unifyIME` 這條基線的 build / install / reload / notarize 流程。

專案根：
- `src/unifyIME`

安裝位置：
- `~/Library/Input Methods/全一輸入法.app`

保留原始輸入法：
- `~/Library/Input Methods/McBopomofo.app`

## 開發版

僅建置，不安裝：

```sh
zsh src/unifyIME/build.sh --skip-sign --no-deploy
```

建置並安裝、重新啟動輸入法及候選 helper：

```sh
zsh src/unifyIME/build.sh --deploy --sign
```

`build.sh` 預設為本機建置，只有 `--deploy` 才部署。開發版可用 ad-hoc 簽章，沒有 notarize。部署前應保存目前 app 備份；完成後核對新建置與安裝檔的雜湊、簽章及執行程序，再移除備份。

根目錄包裝腳本：

```sh
zsh build.command
```

預設建立 `bin/app/全一輸入法.app` 與 `dist/全一輸入法.app`，不更新系統輸入法。可明確加上 `--sign --deploy` 執行簽章及部署。`IMEConfig.json` 會隨 app 打包，目前 `candidateWindowLength` 預設為 6。

## 正式發布與一鍵安裝 DMG

`pack.command` 為發布者本機工具，不納入 GitHub；需自行備妥發布設定後，才可在專案根目錄執行：

```sh
zsh pack.command
```

預設重新建置 release，不部署至本機。腳本會依序完成輸入法、安裝程式與 DMG 的 Developer ID 簽章及 Apple 公證，並為產物附加公證票根。輸出位於 `dist/`，另有對應的 `.dmg.sha256` 校驗檔。

DMG 內含「安裝全一輸入法.app」與安裝說明。安裝程式與掛載後的磁碟皆使用全一輸入法圖示；封裝腳本從既有 `Bopomofo.tiff` 產生 ICNS，並在簽章前完成資源設定。開啟安裝程式後，自動複製至目前使用者的 `~/Library/Input Methods/全一輸入法.app`、重新註冊並啟動輸入法。更新先備份舊版，失敗嘗試還原；個人詞頻與偏好設定不會覆寫。首次使用者仍需在 macOS 鍵盤設定中加入輸入來源。

必要設定：

- Developer ID Application 憑證；預設自動尋找，也可用 `UNIFYIME_CODESIGN_IDENTITY` 指定。
- notarytool 鑰匙圈設定；以 `UNIFYIME_NOTARY_PROFILE` 指定自己的設定名稱。
- `--arch=arm64` 或 `--arch=x86_64` 指定目標架構，預設本機架構。
- `--no-build` 可使用 `dist/全一輸入法.app` 封裝，仍會重新簽署及公證。

`UNIFYIME_SKIP_NOTARIZE=1` 僅用於本機封裝，產物檔名會標示 `LOCAL-ONLY`。舊的 `scripts/build-release-notarize.command` 是本機部署流程；正式 DMG 請使用根目錄 `pack.command`。

## Reload 原則

build 後一定要 reload。

目前做法：
- `src/unifyIME/build.sh --deploy` 已內建 reload
- 不要假設安裝後系統自動吃到新 binary

如果看到怪現象，先懷疑：
- 舊 IME 進程還在
- `TextInputMenuAgent` 沒刷新
- 你正在測的不是最新 build

## Candidate Helper

目前可見候選 UI 依賴 helper。

helper 啟動條件：
- 由 `scripts/build-dev.command` 啟動 app 的 `basicSelWindow` instance
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
- `src/unifyIME/build.sh --deploy --sign`

2. 切到別的輸入法，再切回 `全一輸入法`

3. 若系統輸入來源清單或 TIS 視窗怪掉：
- 先關掉系統設定重開
- 必要時 logout/login

## 參考

- `doc/踩坑紀錄.md`

## 發布版號

版本以建置產生的 `1.YY.MMDD build HHmm` 為準（台北時間）。程式介面、安裝程式與 DMG 共用 app 內的 `UnifyIMEBuildVersion`；封裝不另產生版本。GitHub 標籤使用 `v1.YY.MMDD-build-HHmm`，DMG 使用 `UnifyIME-1.YY.MMDD-build-HHmm-架構.dmg`。`--no-build` 會沿用既有 app 的 BUILD 版號；舊產物若未包含版號欄位，需先重新建置。

## 產物目錄清理

每次執行 BUILD 或 PACK，都會在產生新版前清空 `dist/`，包含舊 app、DMG、校驗檔及隱藏檔。`pack.command --no-build` 會先將既有 app 暫存至 `dist/` 外，再清空目錄並保留本次 app，避免刪除封裝來源。需要保存的歷史版本請先移至其他目錄。
