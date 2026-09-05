# FEATURES

這份文件列的是 `src/unifyIME` 現在的功能現況，不是理想狀態。

## 已完成

### 1. 系統層
- 可被 macOS 識別為輸入法
- 可安裝到 `~/Library/Input Methods`
- 有 release notarize 流程
- 原始 `McBopomofo` 可共存

### 2. 注音輸入
- 標準注音鍵位映射
- `Shift` 英文直出
- `Ctrl/Command/Option` 組合不應進注音主路徑
- Backspace/Esc/Enter 有基本行為

### 3. 連打與組字
- 可持續連打，不必每字都立即送出
- 可維持未送出的組字狀態
- 左右可移動焦點 segment
- 焦點 segment 會影響目前候選內容

### 4. 候選
- 有 phrase + char 候選
- 候選策略已部分往 `refCode` 靠
- `↑ / ↓` 可用於候選切換，且目前已支援頭尾循環
- 有 queue 過濾避免方向鍵誤 commit
- 已有 `Heuristic` 與 `CoreML` 兩條候選重排路徑
- 可用環境變數保留空權重 baseline 對比
- 權重已改成外部模型載入，不必重編 app 才能換模型
- mixed 中英候選已可進同一個選單
- mixed 候選目前主路徑已改用 metadata entry，不再只靠字串或 index 對位

### 5. 字庫
- 使用 `common_map.tsv`
- 使用 `phrase_map.tsv`
- 有高頻 override 補正

### 6. 自動測試
- 有 selftest 接口
- 可做短詞 / 短句 / 短文測試
- 已支援逐鍵模擬，不只靜態整句比對
- CLI regression 已改成 batch：
  - `build-raw-input-batch`
  - `ime-action-batch-replay`
- 已可 dump ranker training data
- 已可做 ranker A/B 檢查
- 已可由外部腳本重訓與安裝新權重
- 目前正式 baseline：
  - `zh 100`
  - `en 100`
  - `mix 200`
- CLI 目前 `400/400 PASS`
- 擴大後的不間斷 mixed smoke 目前 `21/21 PASS`
- 新增 4 個公開網路來源改寫的 40 句中英長句語料
- 網路語料會自動組成不插入 Enter 的連續 raw stream，並支援逐鍵壓力模式
- 2026-07-18 網路語料首輪：`21 PASS / 11 FAIL / 8 EXPLORE_GAP`，作為後續邊界與排序修正基線
- 長句 mixed merge 已改用 raw prefix state、穩定 coverage 與英文 span 增量快取
- 40 句網路語料 release 測試由 `165.65s` 降為 `61.16s`，結果分佈不變

### 7. 多語骨架
- 已有 `CompositionLanguageRegistry.targets`
- 已有 `bopomofo-zh-hant` 與 `english-ime`
- 新安裝預設同時啟用中文與英文 target，使用者仍可在偏好設定停用英文
- 各語言詞庫分開存放、各自獨立使用
- multilingual `predictAll()` 已做 per-target threaded predict
- live 與 CLI 已共用 `MixedCompositionResolver`，統一 mixed span 判斷與組字狀態 materialization
- mixed 英文 exact 候選已可注入中文主候選選單
- 開選單前已會先 flush pending merge，避免英文候選漏掉
- 完整英文 exact match 會壓過偶然成立的局部注音 span
- `everyb`、`veryg` 等未完成英文前綴在 mixed 句尾不會跳回注音
- mixed raw buffer 支援上限已由 30 提升到 120 keys
- 長句只重算英文 spans 之間與末端中文 gap，保留已穩定的中文 prefix

### 8. 啟動與暖機
- app 啟動時已做 prewarm，不再等第一個 session 才暖機
- 目前會預熱：
  - 中文 lexicon
  - CoreML ranker 載入
  - 英文 `exact/prefix`
  - mixed `spanCoverages/merge` 熱路徑

## 部分完成

### 1. 候選窗
- 現在可用的是 helper 視窗
- 不是原生 candidate window
- 位置、寬度、顯示時機已可控
- 仍屬過渡解

### 2. 切詞/選詞
- 已有 focused segment 候選策略
- 仍會在某些真實輸入出現錯詞
- 無聲調與短句語境仍不足

### 4. 候選排序模型
- `CoreMLCandidateRanker` 已實際接進 app
- 已改為外部模型載入、fallback、A/B 對比路徑
- 已完成第一批訓練資料、expanded 資料與 `x4` 資料集
- 已訓練並匯出第一批 `CandidateRanker.mlmodel`
- 已加入 48 維前後文特徵的實驗路徑
- 仍需要更多真實 hard negatives 與真實輸入資料

### 3. 標點
- 標點曾被改壞過
- 現在仍需要把規則穩定化
- 之後改鍵盤事件路徑時，要先驗證標點不能再次失效

## 尚未完成

### 1. 原生 candidate window
- `CandidateUI` 仍未在目前 IME 執行環境穩定顯示
- 還不能取代 helper 視窗

### 2. 真正語言模型
- 已接上 Core ML 候選排序模型
- 但目前仍不是完整多語語言模型
- 英文 target 已有獨立詞庫與基本 behavior
- 但英文 / 中英夾雜 reverse path 仍未完全打通
- 目前仍有大量規則式基底：
  - 字典
  - phrase map
  - focused segment
  - override
  - walk/candidate cost

### 3. live mixed 實機相容性
- live 與 CLI 的 mixed resolver 核心路徑已對齊
- 仍需持續驗證不同 macOS 應用程式的 marked text、游標定位與候選窗行為
- 核心語言判斷回歸應先跑 `mixed_live_smoke.py`，再做實機輸入驗證

## 開發限制

後續開發請遵守：

1. 不要用 marked text 直接顯示候選列表
2. 不要把 helper 當最終形態，但也不要隨便拆掉
3. 不要因為一兩個句子錯就只補 override，除非是高頻例外
4. 任何鍵盤事件邏輯修改後，都要回測：
- 標點
- Shift 英文
- 方向鍵候選
- Enter/Space commit
- Backspace
5. preview、candidates、commit 只能來自同一份 `presentation`
- 看到什麼，就 commit 什麼
- 不要再引入第二份正文字串或另一條 commit 路徑
6. mixed 候選不得只用 `[String]`
- 正式選字資料必須保留 metadata
- display layer 才能降成文字
7. 全量 batch regression 若明顯耗時，不要在 agent 內長時間空等，直接給使用者 shell 指令在本機執行

## 開發主軸優先順序

1. 逐鍵輸入的音節切分
2. focused segment 候選策略
3. phrase 優先與 context weighting
4. 真實 hard negatives 與 A/B 驗證回灌
5. 再來才是更漂亮的正式候選窗
