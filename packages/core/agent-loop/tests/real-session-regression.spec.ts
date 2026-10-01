import { describe, expect, it } from 'vitest'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
import type { ContentBlock } from '@deepseek-ai/dsh-llm'
import { degenerateOutputReason } from '../src/degenerate.ts'

/**
 * Real-session regression fixtures. These are extracted verbatim from the
 * harness-suite session (session-71eb8ff3) that produced the "second wave" of
 * degenerate output on 2026-09-30 — the model streamed the loop as *visible
 * text* instead of reasoning, so the first patch (reasoning-only detection)
 * let it through. Each fixture reproduces the exact block shape observed.
 */

// seq 13568, 13:44:47 — pure visible-text loop (184 lines, 95.1% short,
// "OK." x75 / 40.8%) followed by a pseudo-progress job_output tool call.
const textLoopBlocks: ContentBlock[] = [
  {
    type: 'text',
    text: [
      'The review (round 3) is running. It took ~21 min last time. Let me wait for it.',
      'Let me wait.',
      'Go.',
      'OK.',
      'Let me wait for pwsh-50.',
      'OK.',
      'Issuing.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Let me issue.',
      'OK.',
      'Issuing now.',
      'OK.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Issuing.',
      'OK.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Let me issue.',
      'OK.',
      'I keep looping. Let me just issue the wait.',
      'Let me issue job_output wait for pwsh-50 again.',
      'Go.',
      'OK.',
      'Issuing.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Let me issue.',
      'OK.',
      'Issuing.',
      'OK.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Let me issue.',
      'OK.',
      'I must stop. Issuing the wait now.',
      'OK.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Let me issue.',
      'OK.',
      'Issuing.',
      'OK.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Let me issue.',
      'OK.',
      'Enough. Issuing.',
      'OK.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Let me issue.',
      'OK.',
      'Issuing now.',
      'OK.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Issuing.',
      'OK.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Let me issue.',
      'OK.',
      'Issuing.',
      'OK.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Let me issue.',
      'OK.',
      'I keep looping. Let me just issue the wait.',
      'Let me issue job_output wait for pwsh-50 again.',
      'Go.',
      'OK.',
      'Issuing.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Let me issue.',
      'OK.',
      'Issuing.',
      'OK.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Let me issue.',
      'OK.',
      'I must stop. Issuing the wait now.',
      'OK.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Let me issue.',
      'OK.',
      'Issuing.',
      'OK.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Let me issue.',
      'OK.',
      'Enough. Issuing.',
      'OK.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Let me issue.',
      'OK.',
      'Issuing now.',
      'OK.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Issuing.',
      'OK.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Let me issue.',
      'OK.',
      'Issuing.',
      'OK.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Let me issue.',
      'OK.',
      'I keep looping. Let me just issue the wait.',
      'Let me issue job_output wait for pwsh-50 again.',
      'Go.',
      'OK.',
      'Issuing.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Let me issue.',
      'OK.',
      'Issuing.',
      'OK.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Let me issue.',
      'OK.',
      'I must stop. Issuing the wait now.',
      'OK.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Let me issue.',
      'OK.',
      'Issuing.',
      'OK.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Let me issue.',
      'OK.',
      'Enough. Issuing.',
      'OK.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Let me issue.',
      'OK.',
      'Issuing now.',
      'OK.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Issuing.',
      'OK.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Let me issue.',
      'OK.',
      'Issuing.',
      'OK.',
      'Let me issue.',
      'OK.',
      'Go.',
      'Let me issue.',
      'OK.',
    ].join('\n'),
  },
  { type: 'tool-call', id: ToolCallId('call_1'), name: 'job_output', arguments: '{"job_id":"pwsh-50","timeout_ms":600000,"wait":true}' },
]

// seq 13573, 13:54:58 — reasoning whose head is normal but whose tail enters
// the same OK./Go./Let me issue. loop (real: 2528 chars / 210 lines).
function reasoningTailLoopBlocks(): ContentBlock[] {
  const fragments = ['Go.', 'Issuing.', 'Let me issue.', 'I will wait for pwsh-50.']
  const lines = [
    'The review is running. It\'ll take ~21 min. Let me wait more. But repeated long waits time out. Let me wait again with a long timeout.',
    'Actually, let me check the job first.',
  ]
  // ~200 行退化循环尾巴：偶数行 OK.，奇数行碎片
  for (let i = 0; i < 200; i++) {
    lines.push(i % 2 === 0 ? 'OK.' : fragments[Math.floor(i / 2) % fragments.length]!)
  }
  return [
    { type: 'reasoning', text: lines.join('\n') },
    { type: 'tool-call', id: ToolCallId('call_2'), name: 'job_output', arguments: '{"job_id":"pwsh-50","wait":true}' },
  ]
}

// seq 29, 9/20 — a genuinely normal early message (short, distinct reasoning
// plus a real text answer and two tool calls). Must NOT be flagged.
const normalBlocks: ContentBlock[] = [
  {
    type: 'reasoning',
    text: 'The user wants me to deeply analyze this project. Let me start by exploring the workspace to understand its structure and identify the key components before making any changes.',
  },
  { type: 'text', text: 'I will start by mapping the repository structure and reading the core harness scripts to understand the current architecture.' },
  { type: 'tool-call', id: ToolCallId('call_3'), name: 'read', arguments: '{"path":"identity.yaml"}' },
  { type: 'tool-call', id: ToolCallId('call_4'), name: 'read', arguments: '{"path":"README.md"}' },
]

describe('real-session regression (2026-09-30 second wave)', () => {
  it('flags the visible-text loop even when a pseudo-progress tool call follows', () => {
    // 这是用户看到的"仍然这样输出"的实锤：退化循环在 text 块里 + job_output
    // tool-call，第一版补丁（只扫 reasoning + text 放行）放它入库了。
    const reason = degenerateOutputReason(textLoopBlocks)
    expect(reason).toMatch(/degenerate output/)
    expect(reason).toContain('OK.')
  })

  it('flags reasoning whose tail enters the loop even with a tool call', () => {
    const reason = degenerateOutputReason(reasoningTailLoopBlocks())
    expect(reason).toMatch(/degenerate output/)
  })

  it('does not flag a genuinely normal early message', () => {
    expect(degenerateOutputReason(normalBlocks)).toBeUndefined()
  })
})
