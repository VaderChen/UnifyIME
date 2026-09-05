# UnifyIME

UnifyIME（全一輸入法）是 macOS 中英連續輸入法，讓中文注音與英文單字可以在同一段文字中自然輸入，減少頻繁切換輸入法的干擾。

## 產品特色

- 中文注音與英文混打：中文組字、英文單字與未完成英文前綴可連續輸入。
- 智慧組字：根據輸入內容、前後文與片段狀態產生候選字詞。
- 候選排序：支援規則式排序與 Core ML 模型，並保留 fallback 機制。
- 流暢編輯：支援候選切換、左右移動、插入、Backspace、Delete、Escape、Enter 與 Space。
- 連續輸入：保留組字狀態，支援不中斷的長句與多次中英切換。
- 可調整設定：可在偏好設定中調整選字引擎、候選游標與停頓辨識。
- 現代化設定介面：偏好設定採用 HTML、CSS 與 JavaScript，提供清楚的側欄與卡片式內容。
- 多語言架構：中文與英文使用獨立 target 與詞庫，方便後續擴充其他語言。
- CLI 測試工具：提供 selftest、批次輸入模擬、mixed smoke 與長句回歸測試。

## 使用情境

```text
中文：    今天天氣很好
中英混打：今天天氣 very good
產品文字：請確認 input token 是否正常
```

輸入過程中可以直接繼續輸入英文、選字或移動游標，不必為每個語言片段單獨切換輸入法。

## 目前狀態

UnifyIME 已具備完整的中文注音、英文輸入與中英混打主流程。候選 helper 視窗、長句組字、候選排序與不同 macOS 應用程式的實機相容性仍持續改善中。

## 快速開始

需要 macOS 與 Xcode Command Line Tools。建置 app：

```sh
zsh src/unifyIME/build.sh --skip-sign --no-deploy
```

建置結果位於 `bin/app/全一輸入法.app`。完整開發與部署說明請參考 [`doc/DEPLOY.md`](doc/DEPLOY.md)；功能現況請參考 [`doc/FEATURES.md`](doc/FEATURES.md)。

## 專案結構

```text
src/unifyIME/
├── Sources/       輸入法、組字與候選引擎
├── Resources/     字庫、介面與 app 資源
├── scripts/       測試、資料處理與模型工具
└── tests/         回歸與長句測試案例
```

歡迎透過 GitHub issue 回報可重現的輸入案例與功能建議。

## 參考與致謝

本專案在輸入法架構、注音組字、游標行為與中英混打設計上，曾參考以下中文輸入法的公開成果與使用經驗：

- [小麥注音（McBopomofo）](https://github.com/openvanilla/McBopomofo)
- [vChewing 威注音](https://github.com/vChewing/vChewing-macOS)

感謝兩個專案長期累積的設計思考、實作經驗與文件，讓 UnifyIME 的開發少走了許多彎路，也更快釐清 macOS 輸入法在組字、候選與游標互動上的實際問題。
