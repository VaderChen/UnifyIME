# 全一輸入法

`全一輸入法（UnifyIME）` 目前的正式開發基線在：

- `src/unifyIME`

共享核心與語言層：

- `src/phoneticIME`
- `src/englishIME`

不要再回頭改舊的 `fastChIME` 基線或其他舊 clone。

## 目前架構

現在的主結構是三層：

1. `unifyIME`
- macOS IME / helper / CLI adapter
- 目前正式 app 與 build/deploy 都從這裡出

2. shared engine
- `Sources/IME/Models/UnifiedCompositionEngine.swift`
- 對外統一：
  - `feedAll(token:state:)`
  - `predictAll(_:)`
- 目前多 target 骨架已存在

3. per-language behavior
- `Sources/IME/Providers/CompositionLanguageBehavior.swift`
- 每個語言各自提供：
  - `feed`
  - `predict`
  - `resolveCandidates`
  - `resolveWalk`
  - `reverseReadings`
  - `keySequence`

目前已接的 target：
- `bopomofo-zh-hant`
- `english-ime`

## 詞庫與資源

詞庫是分語言獨立存放，不共用：

- 中文：
  - `src/unifyIME/Resources/common_map.tsv`
  - `src/unifyIME/Resources/phrase_map.tsv`
- 英文：
  - `src/englishIME/Resources/english_words.tsv`

原則：
- 每個語言各自查自己的詞庫
- 不做跨語言詞庫混查
- 最後只在 multilingual prediction 階段合併 score / 候選

## CLI 入口

目前 CLI 分成三類：

1. multilingual
- `build-raw-input`
- `build-raw-input-batch`
- `ime-action-replay`
- `ime-action-batch-replay`

2. 中文專屬
- `zh-build-raw-input`
- `zh-build-raw-input-batch`
- `zh-ime-action-replay`
- `zh-ime-action-batch-replay`

3. 英文專屬
- `en-build-raw-input`
- `en-build-raw-input-batch`
- `en-ime-action-replay`
- `en-ime-action-batch-replay`
- `english-debug`

回歸目前主要走 batch：
- `build-raw-input-batch`
- `ime-action-batch-replay`

效能原則：
- CLI regression 預設走 batch，不要再退回逐句開 process
- multilingual `predictAll()` 已做 per-target threaded predict
- 後續加語言時，優先維持 batch + thread 這兩層提速
- 像全量 regression、長時間 replay 這種會跑很久的流程，優先直接給 shell 指令，由使用者在本機跑完回報結果

## 測試現況

目前 `src/unifyIME/scripts/raw_selftest.py` 已分成三類案例：

- `zh`
- `en`
- `mix`

現況：
- `zh 100/100 PASS`
- `en 100/100 PASS`
- `mix 200/200 PASS`
- `continuous mixed 21/21 PASS`

`continuous mixed` 覆蓋純中文、純英文、雙向語言切換、英文連字切詞、`everyb` 類未完成英文前綴，以及最長約 80 raw keys、包含多次中英切換的長句。代表性長句會逐鍵執行，其餘長句以單一不中斷 raw token 驗證最終 span materialization。

```bash
python3 src/unifyIME/scripts/mixed_live_smoke.py
```

### 網路文章中英長句語料

`src/unifyIME/tests/web_mixed_sentences.jsonl` 收錄 40 句中英混打案例，主題來自 Microsoft Learn、Apple 支援、MDN Web Docs 與 IBM Think。所有句子都是依主題改寫的測試句，不是整段複製原文；每筆保留來源標題、URL、中英分段、標籤與正確期望輸出。

測試程式會將中文片段反查成注音鍵，與英文串成一條不插入 Enter 的 raw stream。快速模式每篇保留一句逐鍵長句，其餘用單一不中斷 token；完整壓力模式會把所有標示案例逐鍵執行。

```bash
# 列出來源與 40 句期望結果
python3 src/unifyIME/scripts/web_mixed_article_smoke.py --list

# 快速 replay
python3 src/unifyIME/scripts/web_mixed_article_smoke.py

# 完整逐鍵壓力測試，耗時較長
python3 src/unifyIME/scripts/web_mixed_article_smoke.py --full-incremental

# 中英片段 chunk 比對模式
python3 src/unifyIME/scripts/web_mixed_article_smoke.py --segment-batch

# 將 exploratory 縮寫與產品名缺口也視為失敗
python3 src/unifyIME/scripts/web_mixed_article_smoke.py --strict
```

2026-07-18 首次 baseline 為 `40` 句中 `21 PASS / 11 FAIL / 8 EXPLORE_GAP`。已知失敗包含中文候選排序（例如「再/在」、「中/重」）、英文與下一個中文音節的邊界，以及 `LLM`、`NLP`、`HTML`、`CSS`、`JavaScript`、`Siri` 等尚未完整收錄的詞彙。

### 長句效能基線

2026-07-18 已將 mixed 長句的每鍵重算改為增量路徑：

- merge 後保留未合併 raw prefix state，下一鍵只 feed 新 suffix
- Probe 與正式 IME 共用相同的增量重播原則
- 沿用上一鍵離句尾 12 raw keys 以外的穩定 coverages
- 逐鍵模式不再對句中未完成的注音音節執行完整 walk/ranker
- 英文候選 metadata 直接重用 incremental coverage cache
- 40 句測試改為單一 App process，避免重複載入詞庫與模型

同一台機器的 release build 量測：

- 66-key 逐鍵長句：`31.70s → 13.48s`，縮短約 `57%`
- 40 句網路語料：`165.65s → 61.16s`，縮短約 `63%`
- 原有 mixed smoke：`13.35s → 9.72s`，且維持 `21/21 PASS`
- 完整 raw regression 維持 `400/400 PASS`

## 目前已確立的原則

1. live IME / CLI 都只能當 adapter
- 不再各自維護第二套組字邏輯

2. 多語言不是切 `current`
- 而是走 `CompositionLanguageRegistry.targets`

3. 同一串 raw-key 會分別餵給每個 target 的 `feed/predict`

4. 最後決策規則是：
- 有成功組字的 target 才進最後排序
- 如果全部都沒組字，就回退到 primary 語言

5. 詞庫必須分開放
- 各語言各自獨立使用
- 不共用 lexicon

6. preview、candidates、commit 只能有一個 truth source
- 唯一正式輸出是 `presentation`
- `preview` 只能 render `presentation`
- `candidates` 正式真相已往 `presentation.candidateEntries` 收斂
- 顯示文字層才做 `map(\.text)`
- `commit` 只能送出目前正在顯示的 `presentation.markedText`

7. 看到什麼，就 commit 什麼
- 不允許再有第二份正文字串
- 不允許 `Enter` / `Space` 先走另一條 mutate state 的 commit 支線
- 不允許 UI、helper window、cursor lock 之類的狀態覆蓋正文內容

8. 任何輔助欄位都只能是 derived data
- 不能再有和 `presentation` 平行的正文來源
- 不能再有 `preview` 用 A、`commit` 用 B、`candidate panel` 用 C 的情況
- 如果需要 debug / overlay / probe，必須明確標成附加資訊，不能反向改寫正式輸出

9. mixed 候選不能只剩字串
- 中英混合候選必須保留 metadata
- 至少要帶：
  - `text`
  - `languageID`
  - `replacementKey`
- 選字時只能用同一份 metadata 套用，不能再靠 index 或字串回推 span

10. 候選移動要對稱
- `↑` / `↓` 都必須支援頭尾循環
- 不允許只單邊 wrap、另一邊 clamp

11. 啟動第一拍要先暖機
- app 啟動時就先做 prewarm
- 至少要包含：
  - 中文 lexicon
  - CoreML ranker 載入
  - 英文 exact/prefix lookup
  - mixed span merge 熱路徑

12. mixed merge 只重算 preview 沒覆蓋到的 gap
- primary preview 已經成功 materialize 的 span，不要再丟回 `predict`
- `mergeSpanCoverages` 的中文 coverage 生成，只處理 preview 沒覆蓋到的 raw gap
- 已經成功 preview 的 primary span，要直接當成 fixed coverage 參與 merge
- 這條規則是目前 mixed merge 效能改善的主因之一

13. mixed merge 的主瓶頸不在 DP
- 目前 profiling 已確認：
  - `unified.mergeSpanCoverages.dp` 幾乎可以忽略
  - `mixedMerge.englishSpanScan` 幾乎可以忽略
  - 真正成本集中在 `unified.mergeSpanCoverages.spanCoverages`
- 所以後續若再優化 mixed merge，優先看 coverage 生成，不要先去調 DP

14. runtime profiling 要有 UI 開關，而且 release 不露出
- 偏好設定有 `DEBUG` 分頁可切 `UNIFYIME_PROFILE`
- `DEBUG` 分頁只在 debug build 顯示，release build 要完全隱藏
- profiling 關掉時，平均值與每字統計都要一起清空

15. 效能判讀先看這三層
- 全局：
  - `全局平均耗時：xx.xx ms / 字`
- mixed merge 外層：
  - `session.recomputeRawSpanMerge`
- mixed merge 內層：
  - `unified.mergeSpanCoverages.spanCoverages`
- 如果 `dp` 與 english scan 幾乎為零，就不要誤判成 merge 演算法本身太慢

16. mixed merge 的中文 fixed span 必須用真正 raw key 長度對齊
- 不要直接信任 `ComposedSegment.rawLength` 的預設值
- 對中文 fixed coverage，要以 `keySequence(for:[reading])` 重算 raw span 長度
- 否則像 `天氣verygood` 這種 case，`天氣` 會被錯當成只覆蓋 `2` 個 raw units，導致後面的英文 gap 全部錯位

17. 英文 provisional span 要滿足三個條件
- 要能壓過垃圾注音 fallback
- 不能在 `veryg` 這種中間點過早停掉
- 但分數要低於合理的 exact 分詞組合，所以 `very good` 要贏過整段 `verygood`

18. 完整英文 exact match 不得被局部注音 span 綁死
- 若整段 raw buffer 是英文詞庫的 exact match，整段英文 coverage 優先
- 避免 `test` 被拆成「吃 est」、`project` 被拆成局部中文加英文尾段
- live 與 CLI 的 state materialization 必須共用 `MixedCompositionResolver`

19. 未完成英文 provisional span 只能鎖定目前尾端
- `everyb`、`everybo`、`veryg` 在繼續輸入時要維持英文
- provisional span 後方一旦出現新字元，舊 provisional 不得繼續固定
- 否則英文後改打中文時，會把中文起始鍵吃進英文 span

20. 長 mixed buffer 要局部重算
- mixed merge 上限目前為 `120` raw keys
- 保留第一個可信英文 span 之前已穩定的中文 prefix
- 英文 spans 之間與最後方仍變動的中文 gap 才重新組字
- 不要每鍵重算整段中文，也不能沿用被英文按鍵污染的中文預覽

21. mixed merge cache 不能只看 rawBuffer
- `MixedMergeSupport` 的 cache key 必須包含 `fixedPrimaryCoverages`
- 否則同一串 raw buffer 在不同 primary fixed span 下，會誤吃舊 merge 結果

## 協作規則

- 結構改動後先跑 CLI batch regression，再決定是否 deploy
- 全量 batch regression 若明顯會跑很久，直接提供 shell 指令給使用者執行
- live IME、CLI、debug 都不應再把逐鍵 `probe` 當正式概念；正式基線是整段 raw buffer 重播與整段 predict
