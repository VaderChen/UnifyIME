# AI Agent 個人用語調整

全一提供本機 stdio MCP，讓 Agent 查詢彙整選字詞頻，補充個人注音詞彙並調整候選優先度。第一版採靜態設定：修改寫入個人詞彙檔，**重新啟動輸入法程序後才套用**；切換視窗或單按 Shift 不會重新載入。

## 偏好設定頁面

側欄「MCP」頁提供可複製的本機連線設定與 Agent Prompt。先將設定加入 Agent，再複製 Prompt 交給已接入的 Agent；Prompt 說明詞頻查詢、保留原值、靜態調整及重啟確認流程。頁面不會自行執行調整。

## 接入

安裝含 MCP 功能的版本後，在支援 stdio MCP 的 Agent 設定中加入：

```json
{
  "mcpServers": {
    "unifyime": {
      "command": "/bin/sh",
      "args": ["-c", "exec \"$HOME/Library/Input Methods/全一輸入法.app/Contents/MacOS/UnifyIME\" mcp"]
    }
  }
}
```

MCP 由 Agent 作為子程序啟動，不開放網路連接埠，不需要 Python 或 Node。連接器可讀取本機彙整用語及修改個人詞彙，請由使用者決定接入哪個 Agent。伺服器不讀取完整輸入紀錄，也不自行將用語傳至外部服務；工具回傳內容會提供給接入的 Agent。

## 工具

| 工具 | 用途 |
| --- | --- |
| `ime_restart` | 批次修改後重新啟動輸入法，確認 appliedRevision；會先送出組字、切離並切回，不強制終止 |
| `vocabulary_batch` | 預先驗證或原子寫入最多 100 筆調整，回傳還原操作 rollbackChanges |
| `vocabulary_list` | 查詢個人詞彙及目前 revision，可用 query 篩選、offset 分頁 |
| `vocabulary_upsert` | 新增詞彙或更新 priority，須提供剛讀取的 revision |
| `vocabulary_remove` | 刪除指定個人詞彙偏好，系統詞庫及實際詞頻仍保留 |
| `candidate_preview` | 預覽精確注音的候選召回順序，並非完整上下文選字預測 |
| `usage_list` | 依實際選字次數列出彙整詞頻，可篩選與分頁；最近數秒可能尚未寫入磁碟 |

第一版支援繁體中文注音詞彙，每筆 1–8 個中文字、一字一音節。例如新增偏好：

```json
{
  "revision": 0,
  "syllables": ["ㄅㄨˋ", "ㄕㄨˋ"],
  "surface": "部署",
  "priority": 200
}
```

revision 必須取自 `vocabulary_list`，不可固定使用範例值。音節以標準注音順序填寫，一聲不加調號，其餘聲調（含輕聲）置於音節尾端。以精確讀音生效，不跨聲調改字；Agent 應先確認字詞讀音與使用者意圖。

priority 為 -1000 至 1000 的排序加減分：正值提高、負值降低、0 中立，不代表使用次數，也不保證在所有上下文置頂。系統詞庫不存在的同讀音詞可加入候選及多字組字路徑。負值降低排序，不刪除系統原有詞彙；移除個人項目即可撤銷額外偏好。

每頁最多 100 筆、個人詞彙最多 10000 筆。並行修改會以檔案鎖及 revision 檢查避免覆蓋；revision 不符時重新查詢再決定修改，不應盲目重試舊值。

## 儲存與套用

個人偏好存放於 `~/Library/Application Support/UnifyIME/personal_vocabulary.json`，與實際選字詞頻 `user_freq_v2_zh-Hant.tsv` 分開。MCP 不改寫 NN 模型、系統詞庫或實際選字次數。請先查詢並保留原值，以便透過工具還原。

正式輸入法啟動時讀入靜態快照；MCP 的候選預覽讀取最新檔案，可能與尚未重啟的輸入法不同。開發環境可使用既有本機重新載入流程；Agent 應在批次修改後呼叫 `ime_restart`，傳入最新 revision。修改結果中的 `applied: false` 與 `restartRequired: true` 表示尚未生效；先告知使用者重啟會送出目前組字，再執行重啟工具。僅當 `appliedRevision` 與最新 revision 相符，才能宣告已套用。逾時或無法確認程序身分會回報失敗，不強制結束程序。

## 保留的後續工作

動態套用暫不啟用。後續再處理：輸入閒置時的版本通知、組字快照一致性、即時排序變更與回復，以及使用者可見的套用狀態。

協定依據：[MCP stdio](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports) 與 [Tools](https://modelcontextprotocol.io/specification/2025-06-18/server/tools)，支援協商 2024-11-05、2025-03-26、2025-06-18。

## 對話脈絡與調整策略

MCP 頁面的 Prompt 要求 Agent 結合實際可存取的對話、使用者明確糾正、領域用語及彙整詞頻，成組評估新增、加權、降權及撤銷。明確糾正可採 +500～+800，穩定領域習慣 +250～+500，有用例但較少的詞 +80～+250；這些是起始策略，非效果保證。高度依賴上下文的單字避免全面加權，不從 Agent 自己的措辭推測使用者偏好。

`vocabulary_batch` 的 changes 每筆含 action（upsert／remove）、syllables、surface，upsert 必須含 priority。先以 dryRun=true 驗證整批並保留 rollbackChanges；dryRun=false 才寫入，只增加一次 revision。每批 1–100 筆；任一筆不合法、重複詞彙或 revision 衝突時整批不寫入。還原時先讀取最新 revision，核對後將 rollbackChanges 作為新的 changes 提交，再重啟。dryRun 不模擬完整上下文排序；實際效果需由後續使用回饋確認。
