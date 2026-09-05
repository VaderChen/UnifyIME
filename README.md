# FastChIME

macOS 中英連續輸入法（全一輸入法 / UnifyIME），包含候選排序、上下文預測與 Core ML listwise Transformer 訓練工具。

## 開發

需要 macOS、Xcode Command Line Tools。從 repository 根目錄執行：

```sh
./src/unifyIME/build.sh --skip-sign --no-deploy
```

輸出位於 `bin/app/全一輸入法.app`。完整架構與測試說明見 [開發文件](doc/README.md)、[部署說明](doc/DEPLOY.md) 與 [Listwise 訓練](src/unifyIME/LISTWISE_TRANSFORMER.md)。

## 私密資料與可攜性

- `cert/`、本機設定、真實選字紀錄、`data/`、`artifacts/`、模型權重、編譯產物與備份不提交。
- 既有本機資料保留，不因 Git 排除而刪除；模型未包含於 repository，需自行訓練或放置，未載入模型時使用規則排序。
- 專案路徑由腳本位置推導；使用者安裝目錄由 `$HOME` 推導。macOS 系統工具的標準路徑維持原樣。
- 外部訓練資料以 `FASTCHIME_IME_DATA_ROOT` 指定。公證用 Keychain profile 以 `FASTCHIME_NOTARY_PROFILE` 指定，不在程式碼放入憑證。
- 本機參考專案 `refCode/` 未納入提交。日後公開前仍應另行完成第三方程式碼及詞庫的授權盤點。
