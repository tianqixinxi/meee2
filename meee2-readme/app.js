const layerButtons = document.querySelectorAll('.layer-button')
const flowNodes = document.querySelectorAll('.flow-node')

function setActiveLayer(layer) {
  layerButtons.forEach((button) => {
    button.classList.toggle('active', button.dataset.layer === layer)
  })
  flowNodes.forEach((node) => {
    node.classList.toggle('highlight', node.dataset.layerNode === layer)
  })
}

layerButtons.forEach((button) => {
  button.addEventListener('click', () => setActiveLayer(button.dataset.layer))
})
setActiveLayer('tools')

const policyContent = {
  private: {
    title: 'Private',
    copy: '只在本机，不上传到团队或飞书。',
    payload: {
      uploads: [],
    },
  },
  metadata: {
    title: 'Metadata only',
    copy: '团队只看到 owner、repo、branch、provider、status、blocker；不包含 recent messages 或 transcript。',
    payload: {
      sessionId: 'codex-abc123',
      owner: 'local-user',
      provider: 'Codex',
      repo: 'meee2',
      branch: 'codex/personal-ai-cockpit',
      status: 'blocked',
      blocker: 'permission required',
    },
  },
  summary: {
    title: 'Summary',
    copy: '在 metadata 基础上同步 current step、recap 和风险摘要，但仍不上传 transcript。',
    payload: {
      sessionId: 'codex-abc123',
      repo: 'meee2',
      status: 'running',
      currentStep: 'Implement selective sync contract',
      recentSummary: 'Pusher now filters session payloads by policy.',
      risks: [{ type: 'sync_policy', severity: 'medium' }],
    },
  },
  recentContext: {
    title: 'Recent context',
    copy: '允许同步最近几条消息预览，适合需要轻量协作但不需要完整审计的场景。',
    payload: {
      sessionId: 'codex-abc123',
      currentStep: 'Create Feishu handoff doc',
      recentMessages: [
        { role: 'user', text: '继续做完 selective sync' },
        { role: 'assistant', text: '已将 syncPolicy 接入 SessionDTO' },
      ],
    },
  },
  fullTranscript: {
    title: 'Full transcript',
    copy: '完整 transcript 必须显式确认，适合审计或强协作场景。',
    payload: {
      sessionId: 'codex-abc123',
      fullTranscriptAllowed: true,
      transcriptGovernance: 'explicit opt-in required',
    },
  },
  artifactsOnly: {
    title: 'Artifacts only',
    copy: '只同步 PR、diff、test、deploy 等证据，适合安全敏感团队。',
    payload: {
      sessionId: 'codex-abc123',
      artifacts: [
        { type: 'test', title: 'swift test', status: 'passed' },
        { type: 'doc', title: 'Feishu handoff doc', status: 'created' },
      ],
    },
  },
}

const policyTabs = document.querySelectorAll('.policy-tab')
const policyTitle = document.getElementById('policy-title')
const policyCopy = document.getElementById('policy-copy')
const policyPayload = document.getElementById('policy-payload')

function setPolicy(policy) {
  const item = policyContent[policy] ?? policyContent.private
  policyTabs.forEach((tab) => tab.classList.toggle('active', tab.dataset.policy === policy))
  policyTitle.textContent = item.title
  policyCopy.textContent = item.copy
  policyPayload.textContent = JSON.stringify(item.payload, null, 2)
}

policyTabs.forEach((tab) => {
  tab.addEventListener('click', () => setPolicy(tab.dataset.policy))
})
setPolicy('private')

