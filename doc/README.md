# 開發說明

UnifyIME 的正式程式位於 `src/unifyIME`，中文與英文引擎分別位於 `src/phoneticIME` 與 `src/englishIME`。產品能力請參考 [功能特色](FEATURES.md)，建置與本機安裝請參考 [部署說明](DEPLOY.md)。

## 輸入流程

1. macOS 按鍵事件由 `SessionCtl` 接收，轉成組字引擎可處理的輸入。
2. `CompositionLanguageRegistry` 管理語言 target，各 target 使用自己的詞庫與組字行為。
3. `UnifiedCompositionEngine` 統整狀態與候選；中英混打由 `MixedCompositionResolver` 對齊片段。
4. `CandidateListPolicy` 統一合併與去重，`CompositionPresentationBuilder` 及 `PredictionSnapshot` 依候選建立預覽、焦點與游標位置，顯示層據此更新 marked text。
5. 明確選字與提交分開處理，提交後清除原始按鍵及延遲重播狀態。

## 原始碼入口

| 模組 | 職責 |
| --- | --- |
| `Sources/main.swift` | IMKInputController、按鍵路由、marked text 與提交生命週期 |
| `Sources/IME/Models/UnifiedCompositionEngine.swift` | 共用組字狀態與多語言預測 |
| `Sources/IME/Models/CompositionPresentation.swift` | 共用候選合併與去重、預覽、正文與游標位置 |
| `Sources/IME/Models/BopomofoOrderCorrection.swift` | 未完成音節的注音順序容錯與詞庫讀音核對 |
| `Sources/IME/Models/SymbolCandidates.swift` | 標點快捷鍵與同類符號候選 |
| `Sources/IME/Models/LanguageTypes.swift` | 來源按鍵範圍、確認狀態與候選身分 |
| `Sources/IME/Models/MixedMergeSupport.swift` | 中英來源範圍對齊與局部合併 |
| `../phoneticIME/Sources/PhoneticIMEEngine.swift` | 注音音節、選字鎖定與上下文保留 |
| `../englishIME/Sources/EnglishIMEEngine.swift` | 英文單字、未完成前綴與候選 |
| `Sources/IME/Segmentation/ReadingWalker.swift` | 詞庫切分、完整詞與功能字計分 |
| `Sources/IME/Ranking/` | 規則排序、Core ML 輔助與特徵編碼 |
| `Sources/App/PreferencesWindowController.swift` | 設定介面與 Swift／JavaScript 橋接 |

表格路徑以 `src/unifyIME` 為基準。

## 組字與候選原則

- 詞庫查詢保留使用者明確輸入的二、三、四聲及輕聲；指定聲調時只查完整讀音，不去調、不跨調、不補近音，詞彙前綴延伸亦保留聲調條件。
- 候選清單先確定順序，再依同一索引產生預覽；第零項代表目前正文。
- 候選清單未開啟時，游標移動只改變焦點，不能單憑另一份首選排序覆蓋正文；清單開啟時，方向鍵與 Home／End 先確認目前候選。
- 確認候選後，未與鎖定範圍交錯的完整詞保留整句上下文。
- 功能字可能也是完整詞的首字，應比較完整詞與後詞的證據強弱。
- 單字接輕聲助詞的組合若跨越較強的前詞邊界，不重複取得完整詞加分。
- mixed 候選需保留 `languageID` 與 `replacementKey`，不以文字或索引反推替換範圍。
- 個人詞頻只由明確選字累積，讀音使用候選的 `replacementKey.reading`，語言使用候選的 `languageID`；自動提交不建立選字偏好。
- 顯示游標在完整字元邊界轉成 UTF-16 位移後傳入 Cocoa；詞段尾端對應完整顯示文字的末尾。
- `CandidateIdentity` 以文字、語言、`replacementKey` 與 `replacementReadings` 識別候選。來源標記不參與身分比較；同字但替換範圍或重切方式不同的候選保留。
- 音節插入或刪除時同步搬移後方鎖定；與編輯範圍交錯的詞彙重新解碼。
- Delete／Backspace 依標準鍵碼判斷刪除方向，Home／End 使用共用組字邊界移動流程。

## 音節順序容錯

`BopomofoOrderCorrection` 以詞庫中的有效單字讀音為依據。追加按鍵時，若目前順序沒有有效讀音，且每類注音符號至多一個，才嘗試依聲母、介音、韻母與聲調重排；重排結果必須符合詞庫讀音。例如「ㄐㄠㄧ」可還原為「ㄐㄧㄠ」。已完成的音節與原本合法的音節邊界不跨越，不增刪注音或猜測聲調。

`pendingRawInput` 保留實際按鍵順序。修正後按 Backspace，先移除最後一個原始按鍵，再重建未完成讀音，避免刪除排序後的錯誤位置。

## 來源按鍵與確認狀態

`UnifiedCompositionState` 使用 `readingRawInputs` 保存已完成音節的來源按鍵，`pendingRawInput` 保存未完成音節。`CompositionInputSpan` 的 `start`／`end` 是原始按鍵的字元座標，採左閉右開範圍；`CompositionSegmentKey` 使用音節座標，Cocoa 顯示位置使用 UTF-16，三者不能混用。

`ComposedSegment.confirmation` 區分 `inferred`（自動推測）、`preview`（候選預覽）與 `confirmed`（人工確認）。`automaticLockedKeys` 與 `explicitLockedKeys` 分開保存，顯示時可以共同保護已解析詞段；新的注音輸入會解除自動決策，人工鎖定則由明確選字及編輯範圍管理。

`rebaseOverrides` 在插入、刪除或跨語言重切時同步更新來源按鍵與前後鎖定位置，移除與編輯範圍交錯的舊鎖定。候選帶有 `inputSpan` 時，確認前會比對目前來源；已失效的範圍不套用。預覽不提交文字，也不建立人工確認。

## 候選合併

`CandidateListPolicy.merge` 同時供雙側候選與正式介面的跨語言候選使用。流程先固定目前正文，對各來源去重後，依來源內的名次交錯合併。同名次、同起點時優先較完整的替換範圍，平手時保留來源順序，最後套用可見數量上限。原注音候選以文字等於替換讀音且全部由注音符號組成來識別，去重後保留在清單尾端；一般候選使用剩餘名額，避免雙側或跨語言合併截掉原注音選項。

中文與英文引擎保留各自的排序及模型評分，合併層不直接比較或相加不同尺度的原始分數。`SessionCtl` 用 `CandidateIdentity` 追蹤選取焦點，避免僅因來源標記補齊而失去原候選。

## 中英混打

原始按鍵緩衝區供各語言 target 判斷。`MixedCompositionResolver` 使用保存的來源按鍵定位本次輸入範圍；有可信中文內容的片段可作為固定 coverage，其餘區域由混打合併處理。短英文若同時具有中文詞庫證據，保留中文路徑並提供英文替代候選。

合併結果只有在來源範圍可精確對應、替換後按鍵完整保留，且未涵蓋人工鎖定時才套用。替換只作用於本次範圍，保留前後既有內容。自動辨識產生的鎖定仍屬自動決策，不轉成人工確認。

跨語言候選從游標附近的完整詞段取得來源按鍵，並保留 `replacementKey`、`replacementReadings` 與 `inputSpan`。預覽沿用原範圍顯示，確認後才重排音節與後方鎖定；目前不對英文單字內部任意猜測拆分位置。

重播快取集中限制為最近 64 筆檢查點，獨立保留編輯後的基準狀態。復原快照保存基準與組字狀態，不複製整份重播快取；缺少檢查點時可從基準重建。中英合併排程使用停頓辨識設定，重設或重新建立編輯基準時取消舊排程。

目前採用既有 Swift 引擎實作上述來源範圍與狀態管理，尚未連結 librime 核心或載入 Rime schema。

## 詞庫與符號

`scripts/import_lexicons.py`（專案根目錄下）下載教育部／萌典及 Wikidata 快照，將新增詞寫入既有 `phrase_map.tsv`、`english_words.tsv`，沿用目前引擎的載入方式。中文同時對 common／phrase 去重，英文以查詢鍵與顯示文字去重；正式名稱先於別名處理。新增中文權重為 0，英文正式名稱為 200、別名為 150，不改寫既有詞條權重。

逐詞來源位於 `lexicons/imported_entries.jsonl`，來源版本與雜湊位於 `lexicons/import_manifest.json`。重新匯入只移除工具前次產生且未被修改的完整行；若偵測到人工修改或移除，停止處理。原始下載快照保留於本機 `data/lexicon-import/`。操作及授權請參考 [開放詞庫說明](../lexicons/README.md)。

`SymbolCandidates` 統一管理符號候選與同類變體。符號保留在共用組字狀態內，候選沿用既有替換與復原流程；尚未提交前，可移回符號位置重新選取。Shift 符號輸入依鍵盤產生的字元查詢對照表，再透過共用組字流程插入。

## 模型與設定

已訓練模型位於 [models](../models/README.md)。Core ML 模型不可用時，排序會回退至規則式結果。模型輸入維度須與程式的特徵編碼一致。

`Resources/IMEConfig.json` 的 `candidateWindowLength` 控制候選視窗範圍，會隨 app 打包。個人詞頻與偏好設定位於使用者的 Application Support 目錄，與發佈的原始碼及模型分開保存。

## 診斷入口

`UNIFYIME_RUNTIME_TRACE_ENABLED=1` 可開啟 runtime trace，`UNIFYIME_RUNTIME_TRACE` 可指定輸出位置。CLI 提供逐步、批次與逐行重播入口，便於定位原始按鍵、候選與提交問題。

完整選字紀錄另由 `UNIFYIME_SELECTION_LOG_ENABLED=1` 明確啟用，預設關閉；不會因開啟 runtime trace 而一併開啟。啟用後會在使用者 Application Support 目錄寫入 `user_selection_log.jsonl`，選字與首選不同時另寫入 `regression_backlog.jsonl`。這些診斷內容可能包含完整輸入文字，與一般個人詞頻分開保存，不隨原始碼發布。關閉紀錄不會自動移除既有檔案。

CLI 模擬器的左右鍵會先提交組字，與原生 SessionCtl 在組字內移動的行為不同。分析游標與延遲重播問題時，應以原生事件路徑確認，不直接將 CLI 結果視為實際編輯器行為。

## 發布與安裝程式

發布者本機的 `pack.command` 不隨 GitHub 原始碼提供；此工具預設從最新原始碼建置 release，依序簽署、公證輸入法、安裝程式及 DMG，最後產生 SHA-256 校驗檔。安裝程式位於 `scripts/installer/Installer.swift`，只更新目前使用者的輸入法，並處理舊版備份、失敗還原、過期輸入來源快取清除與服務重新載入。

沙盒 App 會在 `DARWIN_USER_CACHE_DIR/<bundle id>/` 各自保存輸入來源快取（`com.apple.IntlDataCache.le*`）。快取若建立於輸入法安裝或搬移之前，該 App 會判定輸入法無法解析，切換後立即跳回 ABC。安裝程式與本機部署腳本（`reload-IME.command`、`build.sh --deploy`、`build-dev.command`、`build-release-notarize.command`）在註冊輸入法後，會清除未記錄目前安裝路徑的快取，並列出需要重新開啟的前景 App。shell 端邏輯位於 `scripts/ime_cache_common.sh`，`clear_stale_input_source_caches` 支援 `--dry-run`；安裝程式可用 `--list-stale-input-source-caches` 只列出、不刪除。原因與排查方式請參考 [踩坑紀錄](踩坑紀錄.md) 第 37 條。

封裝時由 `Resources/Bopomofo.tiff` 產生 ICNS，供安裝程式與 DMG 磁碟使用。所有圖示與資源變更均在簽章前完成。完整參數與操作請參考 [部署說明](DEPLOY.md)。
