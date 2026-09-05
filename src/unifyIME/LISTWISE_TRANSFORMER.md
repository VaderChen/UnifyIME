# ANE Listwise Transformer

## 目標

`char_listwise_transformer_v1` 一次評估完整候選集合，不再逐候選呼叫 Core ML。
模型輸出 bounded residual，由既有 heuristic 保留基本順序，再由 NN 只修正高信心案例。

正式 IME runtime 固定使用 `MLComputeUnits.cpuAndNeuralEngine`，不允許 GPU 進入按鍵 hot path。

## 模型結構

- 參數量：10,208,001（10.21M）
- 字元 hash vocabulary：16,384
- 候選上限：20
- 每個候選序列長度：48
- hidden dimension：256
- attention heads：8
- feed-forward dimension：768
- candidate 內 sequence Transformer：6 layers
- candidate 集合 Transformer：3 layers
- residual bound：120 points
- runtime residual scale：0.5

序列內容依序包含：左側已選文字、候選 surface、注音 reading、右側 reading。
訓練資料另以英文詞組擴增部分左側 context，讓 encoder 能接受中英混合上下文。

## Core ML Contract

Inputs：

- `token_ids`: Int32 `[1, 20, 48]`
- `token_types`: Int32 `[1, 20, 48]`
- `numeric_features`: Float32 `[1, 20, 8]`
- `candidate_mask`: Float32 `[1, 20]`

Output：

- `residual_scores`: Float `[1, 20]`

模型以 ML Program／FP16 weights 匯出，minimum deployment target 為 macOS 13。

## ANE 驗證（Apple M4）

`MLComputePlan`、`cpuAndNeuralEngine`：

- ANE estimated cost ratio：92.765%
- CPU estimated cost ratio：7.235%
- GPU estimated cost ratio：0%
- heavy operations：57 / 57 偏好 ANE
- CPU 部分主要是 embedding `gather`

100 次固定 shape 推論：

- CPU only mean：5.135 ms
- CPU + ANE mean：2.222 ms
- CPU + ANE P95：2.283 ms
- 約為 CPU only 的 2.31 倍速度

完整報告：

- `artifacts/training/listwise_ane_10m_v1/compute_plan.txt`
- `artifacts/training/listwise_ane_10m_v1/benchmark.txt`

## 訓練與選模

資料以 `case_id` 為 split unit，同一句的不同 segment 不可跨 train / valid / test。
新的 v2 建置器進一步以完整 `all_tokens` 產生 `sentence_family_id`，即使同一句
來自網路語料與真實選字紀錄，也會被分到同一側，避免跨來源洩漏。

選模採 `first_safe_positive_checkpoint`：第一個同時達成 valid 淨改善為正、傷害率不超過
1% 的 checkpoint 立即鎖定。後續 epoch 僅作診斷，避免小型 valid set 讓過擬合模型覆蓋安全模型。

目前 v1 選到 epoch 1：

- valid：改善 3、傷害 0
- test：改善 3、傷害 0
- test Top-1：80.00% → 84.62%

訓練命令：

```bash
python3 src/unifyIME/scripts/train_listwise_transformer.py \
  --train artifacts/datasets/candidate_natural_v1/train.jsonl \
  --valid artifacts/datasets/candidate_natural_v1/valid.jsonl \
  --test artifacts/datasets/candidate_natural_v1/test.jsonl \
  --output artifacts/training/listwise_ane_10m_v1 \
  --epochs 3 \
  --batch-size 4 \
  --eval-batch-size 8 \
  --learning-rate 0.0003 \
  --hard-weight 8 \
  --evaluation-residual-scale 0.5 \
  --max-valid-harm-rate 0.01 \
  --mixed-augment-probability 0.15
```

## 真實選字與多組 sentence-safe split

Runtime 選字紀錄 schema v2 保留舊欄位，並新增：

- `event_id` / `session_id` / `sentence_id` / `selection_sequence`
- `language_id` / `token_languages` / `candidate_languages`
- `composition_text` / `segments`
- `following_readings` / `following_values`
- `mixed_context`

紀錄只儲存本次未送出的組字與候選上下文，不讀取應用程式內其他文件內容。

建立 5 組 repeated holdout：

```bash
python3 src/unifyIME/scripts/build_listwise_sentence_splits.py \
  --output artifacts/datasets/listwise_selection_sentence_v2 \
  --split-seeds 77,113,149,181,223
```

建置器會：

- 納入 `natural_web_v1/raw.jsonl`。
- 納入 `user_selection_log.jsonl` 與 `regression_backlog.jsonl`。
- 以 `event_id` 或 legacy event fingerprint 去除 backlog 重複事件。
- 以 hard / mixed / real-selection 進行 sentence-family 分層。
- 對每組 split 驗證 sentence family 與 case 的 overlap 都為 0。

訓練並彙整多組結果：

```bash
python3 src/unifyIME/scripts/run_listwise_sentence_cv.py \
  --dataset-root artifacts/datasets/listwise_selection_sentence_v2 \
  --output-root artifacts/training/listwise_selection_sentence_cv_v2 \
  --epochs 3 \
  --batch-size 4 \
  --eval-batch-size 8
```

Cross-validation 預設不重複匯出 Core ML，只保留各 split checkpoint、metrics 與
`cv_summary.json`。待穩定性通過後，再對最終全量訓練單獨匯出與重做 ANE Compute Plan。

## 開放授權中英文章擴充 v3

來源與授權：

- MDN zh-TW：CC-BY-SA 2.5，固定 repository commit，保留文章 URL 與 attribution。
- 中文 Wikipedia：CC-BY-SA 4.0 / GFDL，透過 MediaWiki API 擷取並保留 page URL。

擷取器會排除程式碼區塊、Markdown 表格、網址與格式殘片；Wikipedia 每篇最多取 25 句，
避免少數長文壟斷資料。原始句與來源 metadata 位於：

- `artifacts/corpora/open_mixed_articles_v1/sentences.jsonl`
- `artifacts/corpora/open_mixed_articles_v1/summary.json`

建立語料、候選與五組 sentence-safe split：

```bash
python3 src/unifyIME/scripts/fetch_open_mixed_corpus.py \
  --output-jsonl artifacts/corpora/open_mixed_articles_v1/sentences.jsonl \
  --output-text artifacts/corpora/open_mixed_articles_v1/sentences.txt \
  --summary artifacts/corpora/open_mixed_articles_v1/summary.json

python3 src/unifyIME/scripts/build_mixed_article_candidate_dataset.py \
  --input artifacts/corpora/open_mixed_articles_v1/sentences.jsonl \
  --output artifacts/datasets/open_mixed_articles_v1/candidates.jsonl \
  --summary artifacts/datasets/open_mixed_articles_v1/summary.json

python3 src/unifyIME/scripts/build_listwise_sentence_splits.py \
  --output artifacts/datasets/listwise_open_articles_sentence_v3 \
  --candidate-source artifacts/datasets/natural_web_v1/raw.jsonl \
  --candidate-source artifacts/datasets/open_mixed_articles_v1/candidates.jsonl \
  --split-seeds 77,113,149,181,223
```

2026-07-18 資料統計：

- 4,005 句中英文章句，3,912 句可轉為候選上下文。
- 7,503 個文章候選群組，其中 2,503 個 hard groups。
- 合併真實選字後共 8,698 groups、92,684 rows、3,985 個獨立 sentence families。
- 每個 split 約 2,789 個訓練 sentence families，原 v2 為 518，增加約 5.4 倍。
- 五組 split 的 sentence-family overlap、case overlap、invalid groups 都為 0。

文章標籤屬於真實文章中的弱監督訊號，訓練預設使用 `--weak-article-weight 0.1`。
評估分開回報 `real_selection`、`open_article`、`mixed_context` cohorts，checkpoint 與
1% harm gate 以 `real_selection` 為優先，避免文章數量掩蓋真實輸入退步。

2-fold / 1-epoch MPS smoke：

- real-selection test：270 groups，改善 5、傷害 0、net +5。
- real-selection Top-1：70.02% → 71.93%，平均 lift +1.90 個百分點。
- open-article test：2,222 groups，改善 180、傷害 10、net +170。
- 2/2 folds harm rate 為 0，2/2 folds net lift 為正。

Smoke 只證明擴充方向可行，不能直接部署；仍須完成 5-fold / 3-epoch、ANE Compute Plan、
mixed/raw/web/長句延遲回歸後才能替換已安裝權重。

## Runtime 策略

模型位置：

1. `UNIFYIME_LISTWISE_RANKER_MODEL_PATH`
2. `~/Library/Application Support/UnifyIME/Models/ListwiseCandidateRanker.mlmodelc`
3. `~/.fastchime/Models/ListwiseCandidateRanker.mlmodelc`
4. app bundle `Contents/Resources/Models/ListwiseCandidateRanker.mlmodelc`

控制項：

- `UNIFYIME_DISABLE_COREML_LISTWISE_RANKER=1`
- `UNIFYIME_LISTWISE_RESIDUAL_SCALE=0.5`

為避免長句效能與錯誤自動替換：

- 候選視窗：整組候選一次 listwise 推論。
- ReadingWalker：heuristic 先完成動態分詞；只對最終 exact multi-syllable phrase 做 listwise。
- 單字同音候選只顯示排序，不自動覆蓋 committed text。
- residual prediction 有 2,048 組 LRU cache。

## v1 Runtime A/B

- default：改善 0、傷害 0
- dynamic 2,336 segments：改善 0、傷害 0
- article 517 groups：改善 14、傷害 0
- sentence-safe article test 92 groups：改善 3、傷害 0
- test Top-1：85.87% → 89.13%

回歸：

- mixed continuous input：21 / 21
- raw：400 / 400
- web mixed article：21 PASS / 11 FAIL / 8 exploratory gap，與關閉模型相同
- raw elapsed：47.28 秒，控制組同為 47.28 秒
- web elapsed：46.50 秒，控制組 44.05 秒

## 部署狀態

`listwise_ane_10m_v1` 已安裝於本機輸入法，並使用 notarized Developer ID bundle。
模型仍是實驗性候選排序器；v3 開放文章擴充已通過 2-fold smoke，但完整 5-fold 與
runtime/ANE 回歸尚未完成，因此目前不取代現行安裝權重。
