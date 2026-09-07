# Core ML CandidateRanker Contract

這份文件定義 `UnifyIME` 候選排序模型目前生效的 contract。

目標：
- 服務 IME 候選重排，不做生成
- 先支援 `zh-Hant`
- 介面保留多語欄位，後續可擴到 `en` / `ja`
- 在 Apple Silicon（包含 M1）上維持低延遲

## 模型型態

目前建議：
- `ML Program` 或 `NeuralNetwork`
- 輸入固定長度向量
- 輸出單一 `score`
- 對每個 candidate 個別推論

目前狀態：
- 推論端是 Core ML runtime
- 訓練端目前可直接執行的是 `tree` backend
- 若要更明確吃 Apple Neural Engine，訓練端要改成真正的 neural backend
  例如 PyTorch 小型 MLP 再匯出 Core ML

建議網路：
- Dense(128) + ReLU
- Dense(64) + ReLU
- Dense(32) + ReLU
- Dense(1)

## Runtime 模型位置

執行時優先讀外部模型，沒有外部模型時才回退到 app bundle。

載入順序：
1. `UNIFYIME_RANKER_MODEL_PATH`
2. `~/Library/Application Support/UnifyIME/Models/CandidateRanker.mlmodelc`
3. `~/.fastchime/Models/CandidateRanker.mlmodelc`
4. app bundle 的 `Contents/Resources/Models/CandidateRanker.mlmodelc`

建議預設安裝位置：
- `~/Library/Application Support/UnifyIME/Models/CandidateRanker.mlmodelc`

## 目前狀態

目前也已提供：

- `ranker-status`
  - 驗證 app 是否真的載到外部模型
- `ab-ranker-check`
  - 比較 `CoreML on` 與 `UNIFYIME_DISABLE_COREML_RANKER=1` 的排序差異
- `fastChIME/scripts/install_ranker_model.py`
  - 外部安裝或替換權重
- `fastChIME/scripts/retrain_ranker.py`
  - 外部重訓並可選擇自動安裝

空權重 baseline 開關：

- `UNIFYIME_DISABLE_COREML_RANKER=1`

## Input

模型輸入 feature name：
- `features`

型別：
- `MLMultiArray`

shape：
- `[1, 88]`

data type：
- `Float32`

## Output

優先輸出欄位名：
- `score`

相容備援輸出欄位名：
- `target`

型別：
- scalar `Double` / `Float` 或 `[1,1]` `MLMultiArray`

## Feature Schema

固定 88 維，順序如下：

1. `base_rank`
2. `provider_score`
3. `span_length`
4. `candidate_length`
5. `token_length`
6. `preceding_count`
7. `following_count`
8. `exact_token_match`
9. `same_language`
10. `is_phrase`
11. `has_tone_marks`
12. `normalized_match`
13. `span_start`
14. `focused_token_length`
15. `all_tokens_count`
16. `script_han`
17. `script_latin`
18. `script_kana`
19. `script_mixed`
20. `script_other`
21. `lang_zh_hant`
22. `lang_en`
23. `lang_ja`
24. `lang_other`
25. `preceding_recent_count`
26. `preceding_total_chars`
27. `preceding_han_count`
28. `preceding_mixed_count`
29. `following_recent_count`
30. `following_total_chars`
31. `following_zh_count`
32. `following_latin_count`
33. `preceding_last_length`
34. `preceding_last_han_ratio`
35. `preceding_last_hash`
36. `preceding_second_hash`
37. `following_first_length`
38. `following_first_han_ratio`
39. `following_first_hash`
40. `following_second_hash`
41. `preceding_focused_overlap`
42. `focused_following_overlap`
43. `preceding_focused_hash`
44. `focused_following_hash`
45. `left_context_hash`
46. `right_context_hash`
47. `context_asymmetry`
48. `boundary_match_score`
49. `candidate_phrase_log_weight`
50. `preceding_candidate_phrase_log_weight`
51. `preceding_tail_candidate_phrase_log_weight`
52. `reading_candidate_count`
53. `reading_best_phrase_length`
54. `reading_plus_next_candidate_count`
55. `reading_plus_next_best_phrase_length`
56. `preceding_candidate_phrase_exists`
57~64. `candidate_surface_hash_bucket_0...7`
65~72. `preceding_candidate_hash_bucket_0...7`
73~80. `candidate_following_hash_bucket_0...7`
81~88. `preceding_candidate_following_hash_bucket_0...7`

其中 `33~48` 是前後文敏感特徵，`49~56` 是 phrase context 統計，`57~88` 是候選文字與左右文組合的 hashed one-hot identity。新版使用 `dense_mlp_v2`，不再對無空間鄰接意義的特徵向量做 Conv1D 與 pooling。

## 推論原則

- 每次只重排當前候選集，建議最多 `8~16` 個 candidate
- model instance 應常駐，不要每次重建
- 若模型不存在、輸入不符、推論失敗，必須回退 heuristic ranker

## 安裝與替換

安裝 `.mlmodel`：

```bash
python3 fastChIME/scripts/install_ranker_model.py \
  fastChIME/artifacts/x10_iter2/CandidateRanker.mlmodel
```

重訓並安裝：

```bash
python3 fastChIME/scripts/retrain_ranker.py \
  --train data/ranker_x10_iter2/train.jsonl \
  --valid data/ranker_x10_iter2/valid.jsonl \
  --test data/ranker_x10_iter2/test.jsonl \
  --output fastChIME/artifacts/manual_retrain \
  --install
```

若後續補 dummy model，也要保證：
- input name 為 `features`
- output name 為 `score`
- input 維度固定為 `88`
- 即使只是 identity / linear score，也要能被目前 `CoreMLCandidateRanker` 直接載入

## 已完成訓練產物

目前已產出：

- `artifacts/CandidateRanker.mlmodel`
- `artifacts/expanded/CandidateRanker.mlmodel`
- `artifacts/x4/CandidateRanker.mlmodel`

其中 `x10_iter2` 是目前較穩定的 runtime 來源之一；`context_x10_iter2` 為加入前後文特徵的實驗模型，但目前離線指標沒有優於現行 runtime。

## 2026-07-18 residual MLP 實驗結論

這一輪先修正 Core ML `[1,1]` `MLMultiArray` 輸出讀取，再把候選模型改為
`dense_mlp_v2`（128 / 64 / 32），輸入由 56 維擴為 88 維。NN 輸入遮蔽
`base_rank` 與 `provider_score`，新增候選文字及左右文 hashed identity，避免模型只複製
傳統候選順序。

第一組 balanced holdout：

- 傳統 hard Top-1：0%
- NN hard Top-1：40%
- NN 整體 Top-1：42.72%

這證明模型有學到部分 hard-case 訊號，但不足以單獨接管排序。實際 residual A/B 中，
scale 40 以上已開始傷害一般短句與動態句，因此未部署。

第二組自然文章資料採 `case_id` 分層切割，保證同一句的不同片段不會跨 train / valid /
test：

- test groups：65（其中 hard 14）
- 傳統整體 Top-1：78.46%
- 傳統 hard Top-1：0%
- NN 整體 Top-1：41.54%
- NN hard Top-1：21.43%

固定文章 holdout 的 heuristic + NN 結果：

- scale 1000：改善 0、傷害 0
- scale 2000：改善 1、傷害 2
- scale 4000：改善 2、傷害 10

文章 mixed regression 的通過數在 scale 1000 與關閉 NN 時相同（21 / 40；另有 8 個
exploratory gap），但 CLI 批次時間由 38.06 秒增加至 69.50 秒。這包含重複啟動與載入
模型的成本，不能直接等同常駐 IME 延遲，但仍顯示目前逐候選推論架構成本偏高。

結論：`candidate_dense_natural_v1` 僅保留為實驗產物，不安裝成正式模型。下一版應改為
候選集合級（pairwise / listwise）模型，讓訓練目標直接最佳化 `heuristic + residual`，並以
一次 batch 推論整組候選，避免逐候選 Core ML 呼叫。

## Listwise Transformer 後續成果

上述方向已實作為 10.21M 參數的 `char_listwise_transformer_v1`。模型一次評估 20 個候選，
在 Apple M4 的 Core ML Compute Plan 中有 92.765% 估算成本偏好 ANE，57 / 57 個重算子
都在 ANE，平均推論為 2.222 ms。sentence-safe article test 改善 3、傷害 0，Top-1
由 85.87% 提升到 89.13%。

完整 contract、訓練方式、ANE 證據與 runtime 限制請見 `LISTWISE_TRANSFORMER.md`。
