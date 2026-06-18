#!/usr/bin/env node
import { spawn } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const candidates = [
  process.env.MEEE2_MCP_SERVER,
  // Self-contained copy shipped inside this plugin package (see workspace
  // release workflow: Bridge/mcp-meee2 is bundled into <plugin>/mcp-meee2 so the
  // marketplace tarball works without meee2.app installed). Preferred over the
  // app-staged / app-bundle paths below when present.
  path.resolve(here, '..', 'mcp-meee2', 'server.js'),
  path.join(os.homedir(), '.meee2', 'mcp-meee2', 'server.js'),
  path.resolve(here, '..', '..', '..', 'meee2', 'Bridge', 'mcp-meee2', 'server.js'),
  '/Applications/meee2.app/Contents/Resources/Bridge/mcp-meee2/server.js',
].filter(Boolean)

const server = candidates.find((candidate) => fs.existsSync(candidate))

if (!server) {
  console.error([
    'Meee2 MCP server.js was not found.',
    'Open the Meee2 app once, or set MEEE2_MCP_SERVER to the server.js path.',
    'Checked:',
    ...candidates.map((candidate) => `- ${candidate}`),
  ].join('\n'))
  process.exit(127)
}

const child = spawn('node', [server], {
  stdio: ['inherit', 'inherit', 'inherit'],
  env: process.env,
})

child.on('exit', (code, signal) => {
  if (signal) process.kill(process.pid, signal)
  process.exit(code ?? 0)
})

child.on('error', (error) => {
  console.error(`Failed to launch Meee2 MCP server: ${error.message}`)
  process.exit(127)
})
