#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const vm = require('vm')
const { pathToFileURL } = require('url')
const main = fs.readFileSync(root + '/Main.qml', 'utf8')
const panel = fs.readFileSync(root + '/Panel.qml', 'utf8')
const manifest = JSON.parse(fs.readFileSync(root + '/manifest.json', 'utf8'))

function qmlFunction(source, name, context) {
  const match = source.match(new RegExp('  function ' + name + '\\([^]*?\\n  \\}'))
  if (!match) throw new Error('Missing function ' + name)
  return vm.runInNewContext('(' + match[0] + ')', context)
}

const location = '/tmp/plugin with spaces #1/bin/'
const settings = { providers: { fireworks: { enabled: false } } }
const update = qmlFunction(main, 'updateCommand', { settings, root: { updateExecutable: location + 'omarchy-agent-usage-update' } })
assertDeepEqual(update.call({ updateExecutable: location + 'omarchy-agent-usage-update' }, 'force', ['hermes']),
  [location + 'omarchy-agent-usage-update', '--force', '--except', 'fireworks', 'hermes'],
  'refresh invokes the bundled updater and preserves filters')
assertDeepEqual(update.call({ updateExecutable: location + 'omarchy-agent-usage-update' }, 'limits', ['hermes']),
  [location + 'omarchy-agent-usage-update', '--limits-only', '--except', 'fireworks', 'hermes'],
  'retry invokes the bundled updater with limits-only')

function resolvedProperty(source, name) {
  const match = source.match(new RegExp('readonly property string ' + name + ': (.*)'))
  assert(!!match, name + ' has a QML-relative path')
  return vm.runInNewContext(match[1], {
    Qt: { resolvedUrl: relative => pathToFileURL('/tmp/plugin with spaces #1/' + relative) }
  })
}
assertEqual(resolvedProperty(main, 'updateExecutable'), location + 'omarchy-agent-usage-update',
  'updater URL decodes spaces and hash characters')
const meterExecutable = resolvedProperty(panel, 'meterExecutable')
assertEqual(meterExecutable, location + 'omarchy-agent-meter', 'meter URL decodes spaces and hash characters')

for (const [method, verb] of [['useLocalUsage', 'local'], ['useRemoteUsage', 'remote']]) {
  const process = { running: false }
  qmlFunction(panel, method, { provider: { providerId: 'hermes' }, gatewayLoginProcess: process,
    meterExecutable }).call({})
  assertDeepEqual(process.command, [meterExecutable, verb, 'hermes'], method + ' uses the bundled meter')
  assertEqual(process.running, true, method + ' starts its process')
}
const loginProcess = { running: false }
const password = { text: 'test-password-only' }
qmlFunction(panel, 'submitGatewayLogin', {
  provider: { providerId: 'hermes' }, gatewayLoginProcess: loginProcess, meterExecutable,
  gatewayUrl: { text: 'https://example.invalid' }, gatewayUsername: { text: 'test-user' }, gatewayPassword: password
}).call({})
assertDeepEqual(loginProcess.command, [meterExecutable, 'login', 'hermes', '--stdin'], 'login keeps credentials off command-line arguments')
assertEqual(JSON.parse(loginProcess.credentials).password, 'test-password-only', 'login queues credentials for stdin')
assertEqual(password.text, '', 'login clears the password field')
let stdin = ''
const startedContext = { credentials: loginProcess.credentials, write: text => { stdin += text } }
const started = panel.match(/    onStarted: \{([^]*?)\n    \}/)
vm.runInNewContext(started[1], startedContext)
assertEqual(stdin, loginProcess.credentials + '\n', 'login sends credentials on stdin')
assertEqual(startedContext.credentials, '', 'login clears queued credentials after writing')

assertEqual(manifest.id, 'wundrellama.hermes-agents', 'plugin has its own identity')
assertEqual(manifest.omarchy.clonedFrom, 'omarchy.agents', 'clone preserves builtin settings and IPC routing')
assertEqual(manifest.entryPoints.barWidget, 'Panel.qml', 'plugin loads the enhanced panel')
assertEqual(manifest.barWidget.defaults.providers.hermes.enabled, true, 'Hermes enabled by default')
assert(main.includes('modelLabels'), 'provider/model route labels preserved')
assert(main.includes('retryAdvised'), 'ledger-settling retry preserved')
JS
