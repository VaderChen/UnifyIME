# Training Data Design

這份文件定義 `UnifyIME` 候選排序模型的訓練資料設計。

目標：
- 直接沿用目前 `selftest` 的思路
- 不是只看整句最後輸出
- 要保留「逐鍵輸入時，每一步候選長什麼樣」
- 最後轉成可餵 ranking model 的 sample

核心原則：

1. 先有 `句子級 ground truth`
2. 再展開成 `逐鍵 trace`
3. 最後切成 `candidate ranking samples`

這樣資料既能回放，也能訓練。

## 1. 為什麼要沿用 selftest 思路

目前 repo 的經驗已經很清楚：

- 單看整句 `reading -> output` 太樂觀
- 真正會壞的是逐鍵輸入時的：
  - 音節切分
  - focused segment
  - 候選重排
  - 無聲調 / 短句誤選

所以訓練資料不能只記：

- `讀音 = ㄒㄧㄢˋㄗㄞˋ`
- `正解 = 現在`

還必須記：

- 這個 span 出現時，前面已經打了什麼
- 當下候選有哪些
- 排名原本怎麼排
- 使用者最後會選哪個

## 2. 三層資料結構

建議資料拆成三層：

### Layer A: SentenceCase

用途：
- 作為最上游真實語料
- 可直接用於回歸測試與重新生成訓練資料

格式建議：`jsonl`

```json
{
  "case_id": "seed-0001",
  "source": "selftest_default",
  "language_id": "zh-Hant",
  "sentence": "你現在可以正常打字聊天嗎",
  "readings": ["ㄋㄧ", "ㄒㄧㄢˋㄗㄞˋ", "ㄎㄜˇㄧˇ", "ㄓㄥˋㄔㄤˊ", "ㄉㄚˇㄗˋ", "ㄌㄧㄠˊㄊㄧㄢ", "ㄇㄚ"],
  "tags": ["short_sentence", "incremental"],
  "weight": 1.0
}
```

欄位說明：

- `case_id`: 穩定 ID
- `source`: 來源，例如 `selftest_default`、`selftest_dynamic`、`real_user`
- `language_id`: 第一版固定 `zh-Hant`
- `sentence`: 正解句子
- `readings`: ground truth 讀音序列
- `tags`: 類型標籤
- `weight`: 句子權重

### Layer B: IncrementalTrace

用途：
- 把一個句子展開成逐鍵事件序列
- 保留每一步組字與候選狀態

格式建議：每個 case 一個 trace json

```json
{
  "case_id": "seed-0001",
  "steps": [
    {
      "step_id": 1,
      "typed_key": "s",
      "typed_bpmf": "ㄋ",
      "readings": [],
      "current_reading": "ㄋ",
      "composing": "ㄋ",
      "focused_span_start": 0,
      "focused_span_length": 1,
      "candidates": ["你", "尼", "擬"],
      "selected_candidate_index": 0,
      "committed_text": "",
      "target_text_prefix": "你"
    }
  ]
}
```

這層重點不是「最後句子對不對」，而是每一步當下：

- queue 裡有什麼
- readings/currentReading 是什麼
- focused span 是哪段
- 候選列表是什麼
- 正解 prefix 應該是什麼

### Layer C: RankingSample

用途：
- 真正給 MLP 訓練的單筆 sample
- 一筆 sample 對應「某一步、某個 focus span、某個 candidate」

格式建議：`jsonl`

```json
{
  "sample_id": "seed-0001-step-08-cand-01",
  "case_id": "seed-0001",
  "step_id": 8,
  "language_id": "zh-Hant",
  "all_tokens": ["ㄋㄧ", "ㄒㄧㄢˋㄗㄞˋ"],
  "combined_token": "ㄒㄧㄢˋㄗㄞˋ",
  "focused_token": "ㄒㄧㄢˋㄗㄞˋ",
  "preceding_values": ["你"],
  "following_tokens": [],
  "candidate_surface": "現在",
  "candidate_reading_or_token": "ㄒㄧㄢˋㄗㄞˋ",
  "span_start": 1,
  "span_length": 1,
  "provider_score": -1.0,
  "base_rank": 0,
  "label": 1.0,
  "sample_weight": 1.0,
  "source": "selftest_default"
}
```

## 3. 從 selftest 轉資料的生成流程

## Step 1: 取得 sentence cases

第一批資料直接來自：

- [`selftest_sentences.txt`](../../data/min_validation.txt)
- [`defaultSelfTestCases()`](Sources/main.swift#L1537)
- [`generateShortWordTestCases()`](Sources/main.swift#L1673)
- [`generateShortSentenceTestCases()`](Sources/main.swift#L1686)
- [`generateShortArticleCase()`](Sources/main.swift#L1690)

來源分類建議：

- `selftest_default`
- `selftest_short_words`
- `selftest_short_sentences`
- `selftest_short_article`
- `selftest_dynamic`

## Step 2: 反查 readings

直接沿用現有邏輯：

- [`buildReverseLexicon()`](Sources/main.swift#L1554)
- [`reverseReadings()`](Sources/main.swift#L1568)

若反查不到：

- 該 case 先標記 `unresolved_reading`
- 不進第一版訓練集

## Step 3: 展開逐鍵輸入

不能只用 [`simulateIncrementalInput()`](Sources/main.swift#L1608) 的最後結果。

需要額外做一個 trace 生成器，逐鍵記錄：

- 每個按鍵
- `currentReading`
- `readings`
- `displayedSegments`
- `focusedSegment`
- `activeCandidates`
- 當下 top candidate
- 當前 `composingBuffer`

也就是把目前 IME 內部狀態做成可序列化事件。

## Step 4: 從 trace 切 ranking samples

對每個 step：

1. 只有在 `activeCandidates` 非空時才產 sample
2. 以當前 `focusedSegment` 為訓練 span
3. 對 top-k candidates 全部產生 sample
4. 正解 candidate 標 `label=1`
5. 其餘標 `label=0`

## 4. 正解 label 怎麼定

第一版不用猜使用者意圖，直接用句子 ground truth 對齊。

方法：

1. 已知最終句子 `sentence`
2. 已知當前 focused span 的位置與長度
3. 看這個 span 在正解句子裡對應的文字片段是什麼
4. 若 candidate surface 正好等於該片段，標 `1`
5. 否則標 `0`

例：

- 正解句子：`你現在可以正常打字聊天嗎`
- focused span 對應第二段
- 正解片段：`現在`
- candidates：`["現在", "西岸在", "現再"]`
- labels：`[1, 0, 0]`

## 5. 樣本切分策略

資料切分不要只隨機，要避免 leakage。

建議：

- `train / valid / test` 以 `case_id` 切
- 同一句子的不同 step 不能分散到 train 和 valid

建議比例：

- train: 80%
- valid: 10%
- test: 10%

## 6. 資料權重設計

不是所有樣本都同權重。

建議 `sample_weight`：

- 普通樣本：`1.0`
- known hard cases：`2.0 ~ 4.0`
- 真實使用者誤選修正樣本：`3.0 ~ 5.0`

第一批 hard cases 可直接取目前已知錯例：

- `現在 / 西岸在`
- `功能 / 工能`
- `請 / 青`
- `修 / 西歐`
- `要 / 藥`

## 7. 資料集分桶

為了避免模型只學到簡單 case，訓練資料要分桶。

至少分：

- `single_char`
- `short_word`
- `short_sentence`
- `article_span`
- `tone_present`
- `tone_omitted`
- `hard_negative`

每桶都要有最低樣本量。

## 8. 負樣本策略

第一版負樣本就用「同一步 top-k 候選中除正解外全部為負」。

建議：

- `k = 8` 或 `12`

之後再加入：

- hard negatives from confusion pairs
- cross-language negatives

## 9. 第一版最小資料集組成

建議起步：

- `selftest_default`: 全部
- `short_words`: 1,000 筆以上
- `short_sentences`: 2,000 筆以上
- `dynamic`: 5,000 case 以上

若每個 step 平均產 5 到 10 筆 ranking samples，
很快就能得到數萬筆 sample。

## 10. 必要 metadata

每筆 ranking sample 建議保留：

- `sample_id`
- `case_id`
- `step_id`
- `source`
- `tags`
- `language_id`
- `sample_weight`

這樣之後能分析：

- 哪個 source 最有價值
- 哪類 case 最常錯
- 哪種 hard negative 需要加權

## 11. 建議輸出檔

建議資料前處理腳本輸出：

- `data/ranker/sentence_cases.jsonl`
- `data/ranker/incremental_traces/*.json`
- `data/ranker/train.jsonl`
- `data/ranker/valid.jsonl`
- `data/ranker/test.jsonl`
- `data/ranker/confusion_pairs.json`

## 12. 第一版前處理腳本需求

建議下一支腳本做這些事：

1. 讀 selftest cases
2. 反查 readings
3. 逐鍵展開 trace
4. 生成 ranking samples
5. 切 train/valid/test
6. 輸出 jsonl

建議檔名：

- `fastChIME/scripts/build_ranker_dataset.py`

## 13. 跟目前 code 的對齊點

目前最值得重用的現有程式：

- `reverse lexicon`
- 逐鍵切分規則
- `activeCandidates`
- `focusedSegment`
- `displayedSegments`

也就是：

- 盡量不要在 Python 端重寫一套新的 IME 規則
- 最理想是由 Swift 輸出 trace，再由 Python 轉成訓練 sample

## 14. 實務建議

如果只能先做最小版本，我建議這樣排：

1. 先從 `SentenceCase -> RankingSample`
  缺點是沒有完整逐鍵 trace，但先能開訓
2. 再補 `IncrementalTrace`
3. 最後把真實使用者 commit / override 資料併進來

不過正式主線還是應該以 `逐鍵 trace` 為核心。

## 15. 下一步

最合理的下一步是直接補：

- `build_ranker_dataset.py` 規格
- 或者在 Swift 端加一個 `dump-trace` / `dump-ranker-data` 子命令

這樣資料生成就不是紙上談兵，而是能直接落地。

## 目前進度

目前已落地的資料流程：

- `dump-ranker-data`
  - 可直接從 app binary 生成 `jsonl` ranking samples
- `ab-ranker-check`
  - 可輸出 heuristic vs CoreML 的排序差異
- `hard_negatives.json`
  - 已從 A/B 差異中抽出有效 hard negative pairs
- `ranker_x4_hardneg.jsonl`
  - 已將 hard negatives 回灌成可訓練樣本

目前已有這幾層資料集：

- `data/ranker`
  - 第一批最小可用資料
- `data/ranker_expanded`
  - 擴充版資料
- `data/ranker_x4`
  - 約 4 倍級資料集，且已合併 hard negatives

目前主線資料來源仍以自動生成與 reverse lexicon 為主。
下一步高價值來源仍是：

- 真實使用者輸入紀錄
- 真實 commit / override 紀錄
- 更集中的 hard negative mining
