window.renderMCPPage = (container, state, send) => {
  container.innerHTML = `
    <div class="card mcp-card">
      <h2>讓 Agent 調整個人用語</h2>
      <p>結合 Agent 與你的對話、明確糾正與工作領域，成組補充詞彙並調整同音詞優先度。先接入 MCP，再將下方 Prompt 交給 Agent。</p>
      <div class="mcp-notice">靜態設定：修改後需由 Agent 呼叫 ime_restart 才生效。重啟會送出目前組字。</div>
      <p class="mcp-detail">支援 1–8 個中文字與逐字注音。資料存於本機；接入的 Agent 會取得工具回傳內容。</p>
    </div>
    <div class="card mcp-card">
      <div class="mcp-heading"><h2>1. MCP 連線設定</h2><button class="mcp-copy" data-copy="configuration">複製設定</button></div>
      <p>加入支援 stdio MCP 的 Agent 設定，再重新載入連線。設定格式依 Agent 而異。</p>
      <pre id="mcp-config" tabindex="0" aria-label="MCP 連線設定"></pre>
    </div>
    <div class="card mcp-card">
      <div class="mcp-heading"><h2>2. Agent Prompt</h2><button class="mcp-copy" data-copy="prompt">複製 Prompt</button></div>
      <p>可直接貼給已接入的 Agent，包含對話分析、力度分級、批次驗證、重啟確認與還原步驟。</p>
      <textarea id="mcp-prompt" readonly aria-label="Agent Prompt" spellcheck="false"></textarea>
      <small id="mcp-copy-status" role="status" aria-live="polite"></small>
    </div>`;
  document.querySelector('#mcp-config').textContent = state.mcpConfiguration || '';
  document.querySelector('#mcp-prompt').value = state.mcpPrompt || '';
  container.querySelectorAll('[data-copy]').forEach(button => {
    button.onclick = async () => {
      const kind = button.dataset.copy;
      const result = await send({type: 'copyMCP', kind});
      const status = document.querySelector('#mcp-copy-status');
      if (status) status.textContent = result?.copied
        ? (kind === 'prompt' ? 'Prompt 已複製' : '連線設定已複製')
        : '複製失敗，請選取內容後手動複製';
    };
  });
};
