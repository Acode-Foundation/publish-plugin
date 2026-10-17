// Stand-in for acode.app's PUT/POST /api/plugin, used by test/run.sh.
// Usage: node mock-server.mjs <port> <scenario> <log-file>
import fs from 'node:fs';
import http from 'node:http';

const [port, scenario, logFile] = process.argv.slice(2);

const responses = {
  published: { PUT: [200, { message: 'Plugin updated successfully' }] },
  review: { PUT: [200, { message: 'Version 1.2.3 was submitted for review.', review: true }] },
  missing: {
    PUT: [403, { error: 'Plugin "test.plugin" doesn\'t exist yet. Submit it with POST /api/plugin first.', code: 'plugin_not_found' }],
    POST: [200, { message: 'Plugin uploaded successfully' }],
  },
  missingFullKey: {
    PUT: [403, { error: 'Plugin "test.plugin" doesn\'t exist yet. Submit it with POST /api/plugin first.', code: 'plugin_not_found' }],
    POST: [200, { message: 'Plugin uploaded successfully', warning: 'This API key already covers 100 plugins. Create a new key that includes it.' }],
  },
  denied: { PUT: [403, { error: 'This API key cannot publish "test.plugin".', code: 'plugin_not_allowed' }] },
  invalid: { PUT: [401, { error: 'Invalid API key.' }] },
};

http
  .createServer((req, res) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const body = Buffer.concat(chunks).toString('latin1');
      fs.appendFileSync(logFile, `${JSON.stringify({ method: req.method, url: req.url, auth: req.headers.authorization, body })}\n`);
      const [status, payload] = responses[scenario]?.[req.method] || [500, { error: 'Unexpected request' }];
      res.writeHead(status, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(payload));
    });
  })
  .listen(Number(port), '127.0.0.1');
