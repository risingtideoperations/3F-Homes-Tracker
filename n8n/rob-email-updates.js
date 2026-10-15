import { workflow, node, trigger, ifElse, expr } from '@n8n/workflow-sdk';

const schedule = trigger({
  type: 'n8n-nodes-base.scheduleTrigger',
  version: 1.4,
  config: {
    name: '7 AM and 5 PM Central',
    parameters: { rule: { interval: [{ field: 'cronExpression', expression: '0 7,17 * * *' }] } },
    position: [0, 200]
  }
});

const getMail = node({
  type: 'n8n-nodes-base.gmail',
  version: 2.2,
  config: {
    name: 'Unread 3F UPDATE emails',
    parameters: {
      resource: 'message',
      operation: 'getAll',
      returnAll: true,
      simple: false,
      filters: {
        q: 'is:unread subject:"3F UPDATE" (from:claudemastery@gmail.com OR from:rob3fhome@gmail.com)',
        readStatus: 'unread'
      },
      options: {}
    },
    credentials: { gmailOAuth2: { id: 'svwVm8U3FY0fQIzw', name: 'Gmail account' } },
    position: [240, 0]
  }
});

const parse = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Parse JSON block',
    parameters: {
      mode: 'runOnceForEachItem',
      jsCode: "const html = $json.html || '';\nconst t = $json.text || html.replace(/<br\\s*\\/?>/gi, '\\n').replace(/<[^>]+>/g, ' ').replace(/&quot;/g, '\"').replace(/&amp;/g, '&') || '';\nconst m = t.match(/```json\\s*([\\s\\S]*?)```/i);\nlet parsed = null;\nif (m) {\n  try {\n    const j = JSON.parse(m[1].trim());\n    if (j && Array.isArray(j.houses) && j.houses.length) parsed = j;\n  } catch (e) { /* fall through to Haiku */ }\n}\nreturn { json: {\n  email_id: $json.id,\n  received_at: $json.date || null,\n  raw_text: t.slice(0, 20000),\n  parsed,\n  status: parsed ? 'parsed' : 'needs_ai'\n} };"
    },
    position: [480, 0]
  }
});

const hasJson = ifElse({
  version: 2.2,
  config: {
    name: 'Has valid JSON?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict' },
        conditions: [{ leftValue: expr('{{ $json.status }}'), operator: { type: 'string', operation: 'equals' }, rightValue: 'parsed' }],
        combinator: 'and'
      }
    },
    position: [720, 0]
  }
});

const haiku = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.3,
  config: {
    name: 'Haiku extract (fallback)',
    parameters: {
      method: 'POST',
      url: 'https://api.anthropic.com/v1/messages',
      authentication: 'predefinedCredentialType',
      nodeCredentialType: 'anthropicApi',
      sendHeaders: true,
      headerParameters: { parameters: [{ name: 'anthropic-version', value: '2023-06-01' }] },
      sendBody: true,
      specifyBody: 'json',
      jsonBody: expr('{{ JSON.stringify({ model: "claude-haiku-5-5", max_tokens: 3000, messages: [{ role: "user", content: "Extract every house from this 3F Homes flip update email. Reply with ONLY a JSON object, no other text, shaped exactly like {\\"houses\\":[{\\"address\\":\\"216 Oneal Dr\\",\\"stage\\":\\"Renovating\\",\\"purchase_price\\":95000,\\"purchase_close_date\\":\\"2026-09-15\\",\\"loan_amount\\":76000,\\"lender\\":null,\\"earnest_money_paid\\":2000,\\"est_buy_closing_costs\\":3500,\\"cash_to_close\\":null,\\"funded\\":true,\\"reno_scope\\":30000,\\"reno_start_date\\":\\"2026-09-20\\",\\"reno_end_date\\":\\"2026-11-15\\",\\"target_sale_price\\":185000,\\"list_date\\":null,\\"sale_contract_date\\":null,\\"sale_close_date\\":null,\\"sale_price\\":null,\\"loan_payoff\\":null,\\"est_sell_closing_costs\\":null,\\"other_costs\\":4500,\\"note\\":\\"one line\\"}]}. stage must be one of Under Contract, Closed, Renovating, Listed, Sale Pending, Sold. Use null for anything not stated; never guess numbers. Dates as YYYY-MM-DD. If there are no houses, reply {\\"houses\\":[]}.\\n\\nEMAIL:\\n" + $json.raw_text.slice(0, 12000) }] }) }}'),
      options: {}
    },
    credentials: { anthropicApi: { id: 'UJDL0xdS1vpiJD4O', name: 'Anthropic account' } },
    onError: 'continueRegularOutput',
    position: [960, 160]
  }
});

const readAi = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Read Haiku reply',
    parameters: {
      mode: 'runOnceForEachItem',
      jsCode: "const src = $('Parse JSON block').item.json;\nlet parsed = null, err = '';\ntry {\n  const txt = ($json.content || []).map(c => c.text || '').join('');\n  const m = txt.match(/\\{[\\s\\S]*\\}/);\n  const j = JSON.parse(m[0]);\n  if (j && Array.isArray(j.houses) && j.houses.length) parsed = j;\n  else err = 'no houses found';\n} catch (e) {\n  err = $json.error ? JSON.stringify($json.error).slice(0, 300) : String(e.message || e);\n}\nreturn { json: { ...src, parsed, status: parsed ? 'parsed_ai' : 'unparsed', error: parsed ? null : 'Could not read: ' + err } };"
    },
    position: [1200, 160]
  }
});

const apply = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.7,
  config: {
    name: 'Upsert houses + log update',
    parameters: {
      operation: 'executeQuery',
      query: "select $1::jsonb->>'email_id' as email_id, flips.apply_update($1::jsonb) as result",
      options: { queryReplacement: expr('{{ [JSON.stringify($json)] }}') }
    },
    credentials: { postgres: { id: 'Y5T3QmIihg2OomaL', name: 'Postgres account' } },
    position: [1440, 0]
  }
});

const markRead = node({
  type: 'n8n-nodes-base.gmail',
  version: 2.2,
  config: {
    name: 'Mark email read',
    parameters: { resource: 'message', operation: 'markAsRead', messageId: expr('{{ $json.email_id }}') },
    credentials: { gmailOAuth2: { id: 'svwVm8U3FY0fQIzw', name: 'Gmail account' } },
    position: [1680, 0]
  }
});

const alertsDue = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.7,
  config: {
    name: 'Unfunded closings within 7 days',
    parameters: {
      operation: 'executeQuery',
      query: 'select * from flips.funding_alerts_due()',
      options: {}
    },
    credentials: { postgres: { id: 'Y5T3QmIihg2OomaL', name: 'Postgres account' } },
    position: [240, 400]
  }
});

const sendAlert = node({
  type: 'n8n-nodes-base.gmail',
  version: 2.2,
  config: {
    name: 'Email Ryan + Cullen (once per house)',
    parameters: {
      resource: 'message',
      operation: 'send',
      sendTo: 'rmedo@rtmhouses.com, ccrowe@rtmhouses.com',
      subject: expr('3F: {{ $json.address }} closes {{ DateTime.fromISO($json.purchase_close_date).toFormat("M/d") }} and is NOT funded'),
      emailType: 'text',
      message: expr('{{ $json.address }}\nPurchase closing: {{ DateTime.fromISO($json.purchase_close_date).toFormat("cccc, M/d/yyyy") }} ({{ $json.days_out }} days)\nCash to close: ${{ Math.round(Number($json.cash_to_close)).toLocaleString("en-US") }}\n\nMarked not funded in the 3F Flip Tracker. You will only get this email once for this house.'),
      options: { appendAttribution: false, senderName: '3F Flip Tracker' }
    },
    credentials: { gmailOAuth2: { id: 'svwVm8U3FY0fQIzw', name: 'Gmail account' } },
    position: [480, 400]
  }
});

const markAlert = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.7,
  config: {
    name: 'Mark alert sent',
    parameters: {
      operation: 'executeQuery',
      query: 'select flips.mark_funding_alert($1::bigint)',
      options: { queryReplacement: expr("{{ $('Unfunded closings within 7 days').item.json.id }}") }
    },
    credentials: { postgres: { id: 'Y5T3QmIihg2OomaL', name: 'Postgres account' } },
    position: [720, 400]
  }
});

export default workflow('3f-flips-email', '3F Flips — Rob email updates')
  .add(schedule)
  .to(getMail.to(parse.to(hasJson
    .onTrue(apply.to(markRead))
    .onFalse(haiku.to(readAi.to(apply))))))
  .add(schedule)
  .to(alertsDue.to(sendAlert.to(markAlert)))
  .group('Read Rob\'s emails', [getMail, parse, hasJson, haiku, readAi, apply, markRead], {
    description: 'Unread "3F UPDATE" mail -> JSON block (Haiku only if missing) -> upsert flips.houses, log flips.updates, mark read'
  })
  .group('Funding alert', [alertsDue, sendAlert, markAlert], {
    description: 'One email per house to Ryan + Cullen when a purchase closes within 7 days and is not funded'
  });
