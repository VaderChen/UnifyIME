# 開發說明

UnifyIME 的正式程式位於 `src/unifyIME`，中文與英文引擎分別位於 `src/phoneticIME` 與 `src/englishIME`。產品能力請參考 [功能特色](FEATURES.md)，建置與本機安裝請參考 [部署說明](DEPLOY.md)。

## 輸入流程

1. macOS 按鍵事件由 `SessionCtl` 接收，轉成組字引擎可處理的輸入。
2. `CompositionLanguageRegistry` 管理語言 target，各 target 使用自己的詞庫與組字行為。
3. `UnifiedCompositionEngine` 統整狀態與候選；中英混打由 `MixedCompositionResolver` 對齊片段。
4. `CompositionPresentationBuilder` 建立正文、候選、焦點與游標位置，顯示層據此更新 marked text。
5. 明確選字與提交分開處理，提交後清除原始按鍵及延遲重播狀態。

## 原始碼入口

| 模組 | 職責 |
| --- | --- |
| `Sources/main.swift` | IMKInputController、按鍵路由、marked text 與提交生命週期 |
| `Sources/IME/Models/UnifiedCompositionEngine.swift` | 共用組字狀態與多語言預測 |
| `Sources/IME/Models/CompositionPresentation.swift` | 候選順序、預覽、正文與游標位置 |
| `../phoneticIME/Sources/PhoneticIMEEngine.swift` | 注音音節、選字鎖定與上下文保留 |
| `../englishIME/Sources/EnglishIMEEngine.swift` | 英文單字、未完成前綴與候選 |
| `Sources/IME/Segmentation/ReadingWalker.swift` | 詞庫切分、完整詞與功能字計分 |
| `Sources/IME/Ranking/` | 規則排序、Core ML 輔助與特徵編碼 |
| `Sources/App/PreferencesWindowController.swift` | 設定介面與 Swift／JavaScript 橋接 |

表格路徑以 `src/unifyIME` 為基準。

## 組字與候選原則

- 候選清單先確定順序，再依同一索引產生預覽；第零項代表目前正文。
- 游標移動改變選字焦點，不能單憑另一份首選排序覆蓋正文。
- 確認候選後，未與鎖定範圍交錯的完整詞保留整句上下文。
- 功能字可能也是完整詞的首字，應比較完整詞與後詞的證據強弱。
- 單字接輕聲助詞的組合若跨越較強的前詞邊界，不重複取得完整詞加分。
- mixed 候選需保留 `languageID` 與 `replacementKey`，不以文字或索引反推替換範圍。
- 個人詞頻只由明確選字累積，讀音使用候選的 `replacementKey.reading`，語言使用候選的 `languageID`；自動提交不建立選字偏好。
- 顯示游標在完整字元邊界轉成 UTF-16 位移後傳入 Cocoa；詞段尾端對應完整顯示文字的末尾。
- 雙側候選以文字、語言及替換範圍共同識別，預覽與確認均使用同一替換範圍。
- 音節插入或刪除時同步搬移後方鎖定；與編輯範圍交錯的詞彙重新解碼。
- Delete／Backspace 依標準鍵碼判斷刪除方向，Home／End 使用共用組字邊界移動流程。

## 中英混打

raw buffer 會供各語言 target 判斷。已有可信顯示內容的片段可作為固定 coverage，未覆蓋的區域才交由 mixed merge 處理。中文 coverage 以真實 raw key 長度對齊，英文未完成前綴只固定目前尾端，避免吞掉後續中文起始按鍵。

快取必須同時考量 raw buffer 與固定片段；不能只依字串命中就沿用不同狀態的結果。長句保留已穩定前綴，限制局部重算範圍。

重播快取集中限制為最近 64 筆檢查點，獨立保留編輯後的基準狀態。復原快照保存基準與組字狀態，不複製整份重播快取；缺少檢查點時可從基準重建。中英合併排程使用停頓辨識設定，重設或重新建立編輯基準時取消舊排程。

## 模型與設定

已訓練模型位於 [models](../models/README.md)。Core ML 模型不可用時，排序會回退至規則式結果。模型輸入維度須與程式的特徵編碼一致。

`Resources/IMEConfig.json` 的 `candidateWindowLength` 控制候選視窗範圍，會隨 app 打包。個人詞頻與偏好設定位於使用者的 Application Support 目錄，與發佈的原始碼及模型分開保存。

## 診斷入口

`UNIFYIME_RUNTIME_TRACE_ENABLED=1` 可開啟 runtime trace，`UNIFYIME_RUNTIME_TRACE` 可指定輸出位置。CLI 提供逐步、批次與逐行重播入口，便於定位原始按鍵、候選與提交問題。

完整選字紀錄另由 `UNIFYIME_SELECTION_LOG_ENABLED=1` 明確啟用，預設關閉；不會因開啟 runtime trace 而一併開啟。啟用後會在使用者 Application Support 目錄寫入 `user_selection_log.jsonl`，選字與首選不同時另寫入 `regression_backlog.jsonl`。這些診斷內容可能包含完整輸入文字，與一般個人詞頻分開保存，不隨原始碼發布。關閉紀錄不會自動移除既有檔案。

CLI 模擬器的左右鍵會先提交組字，與原生 SessionCtl 在組字內移動的行為不同。分析游標與延遲重播問題時，應以原生事件路徑確認，不直接將 CLI 結果視為實際編輯器行為。

## 發布與安裝程式

發布者本機的 `pack.command` 不隨 GitHub 原始碼提供；此工具預設從最新原始碼建置 release，依序簽署、公證輸入法、安裝程式及 DMG，最後產生 SHA-256 校驗檔。安裝程式位於 `scripts/installer/Installer.swift`，只更新目前使用者的輸入法，並處理舊版備份、失敗還原與服務重新載入。

封裝時由 `Resources/Bopomofo.tiff` 產生 ICNS，供安裝程式與 DMG 磁碟使用。所有圖示與資源變更均在簽章前完成。完整參數與操作請參考 [部署說明](DEPLOY.md)。
