// Build-time fix for supergateway's stateless gateway (upstream 3.4.3).
//
// stdioToStatelessStreamableHttp spawns one stdio child per POST, but only
// kills it from transport.onclose / transport.onerror — and nothing ever
// closes the transport when a request completes normally. Every request
// therefore leaks a child process: measured 10 requests -> 10 live children,
// all still resident after 60s idle. The MCP SDK's own stateless example
// tears the transport down on the response's 'close' event; this inserts
// that. transport.close() fires the existing onclose handler, which already
// calls child.kill().
//
// The insert asserts on a unique anchor and exits non-zero if upstream moves
// or rewrites it, so a silently-unpatched image can never ship. Drop this
// file (and its Dockerfile COPY/RUN) once fixed upstream. The stateful
// gateway is a separate file and is untouched.

const fs = require('fs')

const target =
  '/usr/local/lib/node_modules/supergateway/dist/gateways/' +
  'stdioToStatelessStreamableHttp.js'

const anchor = '            await transport.handleRequest(req, res, req.body);'

const teardown = [
  "            res.on('close', () => {",
  '                transport.close()',
  '                server.close()',
  '            })',
  '',
].join('\n')

const src = fs.readFileSync(target, 'utf8')

const hits = src.split(anchor).length - 1
if (hits !== 1) {
  console.error(
    `patch-supergateway: expected exactly 1 anchor, found ${hits}. ` +
      'Upstream layout changed — re-verify the fix before shipping.',
  )
  process.exit(1)
}

if (src.includes("res.on('close'")) {
  console.error('patch-supergateway: teardown already present — upstream may have fixed this.')
  process.exit(1)
}

fs.writeFileSync(target, src.replace(anchor, teardown + anchor))

const patched = fs.readFileSync(target, 'utf8')
if (!patched.includes("res.on('close'") || !patched.includes(anchor)) {
  console.error('patch-supergateway: post-write verification failed.')
  process.exit(1)
}

console.log('patch-supergateway: stateless child teardown applied')
