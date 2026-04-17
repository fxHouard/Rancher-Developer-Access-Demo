const http = require('http');
const { Client } = require('pg');
const promClient = require('prom-client');

const PORT = 3000;

// ─────────────────────────────────────────────
// 🎨 Change this color, save, see it update!
const ACCENT_COLOR = "#747dcd"; 
// ─────────────────────────────────────────────

// ─── Keycloak SSO ────────────────────────────
const KEYCLOAK_PUBLIC_URL = process.env.KEYCLOAK_PUBLIC_URL || '';
const KEYCLOAK_REALM = 'message-wall';
const KEYCLOAK_CLIENT_ID = 'message-wall';
// ─────────────────────────────────────────────

// ─── Prometheus metrics ────────────────────────
promClient.collectDefaultMetrics();

const httpDuration = new promClient.Histogram({
  name: 'app_http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'path', 'status'],
  buckets: [0.005, 0.01, 0.05, 0.1, 0.5, 1],
});

const messagesPosted = new promClient.Counter({
  name: 'app_messages_posted_total',
  help: 'Total number of messages posted',
});

const messagesDeleted = new promClient.Counter({
  name: 'app_messages_deleted_total',
  help: 'Total number of bulk deletes',
});

const messagesCurrent = new promClient.Gauge({
  name: 'app_messages_count',
  help: 'Current number of messages in the database',
});
// ────────────────────────────────────────────────

const client = new Client({
  host: process.env.DB_HOST || 'demo-db-postgresql',
  port: parseInt(process.env.DB_PORT || '5432'),
  user: process.env.DB_USER || 'demo',
  password: process.env.DB_PASSWORD || 'demo-password',
  database: process.env.DB_NAME || 'demo',
});

const html = () => `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>K8s Message Wall</title>
  <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>📬</text></svg>">
  ${KEYCLOAK_PUBLIC_URL ? '' : ''}
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }

    :root { --accent: ${ACCENT_COLOR}; }

    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
      background: #0f172a;
      color: #e2e8f0;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
    }

    header {
      width: 100%;
      padding: 2rem;
      text-align: center;
      background: linear-gradient(135deg, #1e293b 0%, #0f172a 100%);
      border-bottom: 1px solid #1e293b;
    }

    header h1 {
      font-size: 1.8rem;
      font-weight: 700;
      color: var(--accent);
    }

    header p {
      color: #64748b;
      margin-top: 0.4rem;
      font-size: 0.9rem;
    }

    .info-bar {
      display: flex;
      gap: 1.5rem;
      justify-content: center;
      margin-top: 1rem;
      flex-wrap: wrap;
    }

    .info-pill {
      display: flex;
      align-items: center;
      gap: 0.4rem;
      background: #1e293b;
      padding: 0.35rem 0.8rem;
      border-radius: 999px;
      font-size: 0.75rem;
      color: #94a3b8;
      border: 1px solid #334155;
    }

    .info-pill .dot {
      width: 6px;
      height: 6px;
      border-radius: 50%;
      background: #22c55e;
      animation: pulse 2s infinite;
    }

    @keyframes pulse {
      0%, 100% { opacity: 1; }
      50% { opacity: 0.4; }
    }

    main {
      width: 100%;
      max-width: 640px;
      padding: 1.5rem;
      flex: 1;
    }

    .compose {
      display: flex;
      gap: 0.5rem;
      margin-bottom: 1.5rem;
    }

    .compose input[type="text"] {
      flex: 1;
      padding: 0.75rem 1rem;
      border-radius: 0.75rem;
      border: 1px solid #334155;
      background: #1e293b;
      color: #e2e8f0;
      font-size: 0.95rem;
      outline: none;
      transition: border-color 0.2s;
    }

    .compose input[type="text"]:focus {
      border-color: var(--accent);
    }

    .compose input[type="text"]::placeholder {
      color: #475569;
    }

    .compose button {
      padding: 0.75rem 1.5rem;
      border-radius: 0.75rem;
      border: none;
      background: var(--accent);
      color: white;
      font-weight: 600;
      font-size: 0.95rem;
      cursor: pointer;
      transition: opacity 0.2s;
      white-space: nowrap;
    }

    .compose button:hover { opacity: 0.85; }
    .compose button:disabled { opacity: 0.4; cursor: not-allowed; }

    .clear-btn {
      padding: 0.75rem;
      border-radius: 0.75rem;
      border: 1px solid #334155;
      background: #1e293b;
      font-size: 1rem;
      cursor: pointer;
      transition: border-color 0.2s;
    }

    .clear-btn:hover { border-color: #ef4444; }

    .messages { display: flex; flex-direction: column; gap: 0.6rem; }

    .msg {
      background: #1e293b;
      border: 1px solid #334155;
      border-radius: 0.75rem;
      padding: 0.85rem 1rem;
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 1rem;
    }

    .msg.new {
      animation: slideIn 0.3s ease-out;
    }

    @keyframes slideIn {
      from { opacity: 0; transform: translateY(-8px); }
      to { opacity: 1; transform: translateY(0); }
    }

    .msg-text {
      font-size: 0.95rem;
      line-height: 1.5;
      word-break: break-word;
    }

    .msg-meta {
      font-size: 0.7rem;
      color: #475569;
      white-space: nowrap;
      padding-top: 0.15rem;
    }

    .empty {
      text-align: center;
      color: #475569;
      padding: 3rem 1rem;
      font-size: 0.95rem;
    }

    footer {
      width: 100%;
      text-align: center;
      padding: 1.5rem;
      color: #334155;
      font-size: 0.75rem;
    }

    footer code {
      color: var(--accent);
    }
  </style>
</head>
<body>
  <header>
    <h1>📮 K8s Message Wall</h1>
    <p>A tiny app running in Kubernetes — powered by Tilt + Rancher Desktop</p>
    <div class="info-bar">
      <div class="info-pill"><span class="dot"></span> <span id="pod">—</span></div>
      <div class="info-pill">⏱ Uptime: <span id="uptime">—</span></div>
      <div class="info-pill">💬 <span id="count">0</span> messages</div>
      ${KEYCLOAK_PUBLIC_URL ? '<div class="info-pill">🔐 <span id="username">…</span> <a id="logout-btn" href="#" style="margin-left:0.4rem;color:#ef4444;text-decoration:none;font-weight:600;display:none" title="Logout">✕</a></div>' : ''}
    </div>
  </header>

  <main>
    <form class="compose" onsubmit="send(event)">
      <input type="text" id="input" placeholder="Say something…" autocomplete="off" maxlength="280" autofocus />
      <button type="submit" id="btn">Post</button>
      <button type="button" onclick="clear_()" class="clear-btn" title="Delete all messages"><span style="display:inline-block;transform:scale(1.8)">🧹</button>
    </form>
    <div class="messages" id="messages"></div>
  </main>

  <footer>
    Change <code>ACCENT_COLOR</code> in server.js → save → see it update here ✨
  </footer>

  <script>
    const msgBox = document.getElementById('messages');
    const input  = document.getElementById('input');
    const btn    = document.getElementById('btn');
    const podEl  = document.getElementById('pod');
    const upEl   = document.getElementById('uptime');
    const cntEl  = document.getElementById('count');

    let knownIds = new Set();

    function timeAgo(ts) {
      const s = Math.floor((Date.now() - new Date(ts).getTime()) / 1000);
      if (s < 60)   return s + 's ago';
      if (s < 3600) return Math.floor(s / 60) + 'm ago';
      if (s < 86400) return Math.floor(s / 3600) + 'h ago';
      return Math.floor(s / 86400) + 'd ago';
    }

    function fmtUptime(s) {
      if (s < 60)   return Math.floor(s) + 's';
      if (s < 3600) return Math.floor(s / 60) + 'm ' + Math.floor(s % 60) + 's';
      return Math.floor(s / 3600) + 'h ' + Math.floor((s % 3600) / 60) + 'm';
    }

    function esc(t) {
      const d = document.createElement('div');
      d.textContent = t;
      return d.innerHTML;
    }

    async function load() {
      try {
        const r = await fetch('/api/messages');
        const d = await r.json();

        podEl.textContent = d.pod;
        upEl.textContent  = fmtUptime(d.uptime);
        cntEl.textContent = d.total;

        if (!d.messages.length) {
          msgBox.innerHTML = '<div class="empty">No messages yet — be the first! 🎉</div>';
          knownIds.clear();
          return;
        }

        const currentIds = d.messages.map(m => m.id).join(',');
        const previousIds = [...msgBox.querySelectorAll('.msg')].map(e => e.dataset.id).join(',');

        if (currentIds !== previousIds) {
          msgBox.innerHTML = d.messages.map(m => {
            const isNew = !knownIds.has(m.id);
            return '<div class="msg' + (isNew ? ' new' : '') + '" data-id="' + m.id + '">' +
              '<span class="msg-text">' + esc(m.body) + '</span>' +
              '<span class="msg-meta">' + timeAgo(m.created_at) + '</span>' +
            '</div>';
          }).join('');
        } else {
          msgBox.querySelectorAll('.msg').forEach((el, i) => {
            el.querySelector('.msg-meta').textContent = timeAgo(d.messages[i].created_at);
          });
        }

        knownIds = new Set(d.messages.map(m => m.id));
      } catch(e) {
        msgBox.innerHTML = '<div class="empty">⚠️ Cannot reach API</div>';
      }
    }

    async function send(e) {
      e.preventDefault();
      const body = input.value.trim();
      if (!body) return;
      btn.disabled = true;
      try {
        await fetch('/api/messages', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ body }),
        });
        input.value = '';
        await load();
      } finally { btn.disabled = false; }
      input.focus();
    }

    async function clear_() {
      if (!confirm('Delete all messages?')) return;
      await fetch('/api/messages', { method: 'DELETE' });
      knownIds.clear();
      await load();
    }

    // Expose for Keycloak module script
    window._appLoad = load;

    ${KEYCLOAK_PUBLIC_URL ? '' : `
    load();
    setInterval(load, 3000);
    `}
  </script>
  ${KEYCLOAK_PUBLIC_URL ? `
  <script type="module">
    // ─── Keycloak SSO (ES module) ────
    function startApp() {
      window._appLoad();
      setInterval(window._appLoad, 3000);
    }
    try {
      const { default: Keycloak } = await import('https://cdn.jsdelivr.net/npm/keycloak-js@26/+esm');
      const keycloak = new Keycloak({
        url: '${KEYCLOAK_PUBLIC_URL}',
        realm: '${KEYCLOAK_REALM}',
        clientId: '${KEYCLOAK_CLIENT_ID}'
      });
      const authenticated = await keycloak.init({ onLoad: 'login-required', checkLoginIframe: false });
      if (authenticated) {
        const user = keycloak.tokenParsed.preferred_username || 'user';
        document.getElementById('username').textContent = user;
        const logoutBtn = document.getElementById('logout-btn');
        if (logoutBtn) {
          logoutBtn.style.display = 'inline';
          logoutBtn.addEventListener('click', (e) => {
            e.preventDefault();
            keycloak.logout({ redirectUri: window.location.origin });
          });
        }
      }
      startApp();
    } catch(err) {
      console.warn('Keycloak not available:', err);
      const el = document.getElementById('username');
      if (el) el.textContent = '(no auth)';
      startApp();
    }
  </script>
  ` : ''}
</body>
</html>`;

const startTime = Date.now();

async function start() {
  await client.connect();
  console.log('✅ Connected to PostgreSQL');

  await client.query(`
    CREATE TABLE IF NOT EXISTS messages (
      id         SERIAL PRIMARY KEY,
      body       TEXT NOT NULL CHECK (char_length(body) <= 280),
      created_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);
  console.log('✅ Table ready');

  // Seed the gauge with current count
  const { rows: [{ count }] } = await client.query('SELECT COUNT(*) FROM messages');
  messagesCurrent.set(parseInt(count));

  const server = http.createServer(async (req, res) => {
    const end = httpDuration.startTimer();
    let status = 200;

    try {
      // --- Serve the UI ---
      if (req.method === 'GET' && req.url === '/') {
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(html());
        end({ method: 'GET', path: '/', status: 200 });
        return;
      }

      // --- Prometheus metrics ---
      if (req.method === 'GET' && req.url === '/metrics') {
        const metrics = await promClient.register.metrics();
        res.writeHead(200, { 'Content-Type': promClient.register.contentType });
        res.end(metrics);
        // Don't record /metrics in the histogram (noise)
        return;
      }

      // --- List messages ---
      if (req.method === 'GET' && req.url === '/api/messages') {
        const { rows } = await client.query(
          'SELECT id, body, created_at FROM messages ORDER BY created_at DESC LIMIT 50'
        );
        const { rows: [{ count }] } = await client.query('SELECT COUNT(*) FROM messages');
        const total = parseInt(count);
        messagesCurrent.set(total);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          messages: rows,
          total,
          pod: process.env.HOSTNAME || 'local',
          uptime: (Date.now() - startTime) / 1000,
        }));
        end({ method: 'GET', path: '/api/messages', status: 200 });
        return;
      }

      // --- Post a message ---
      if (req.method === 'POST' && req.url === '/api/messages') {
        const chunks = [];
        for await (const chunk of req) chunks.push(chunk);
        const { body } = JSON.parse(Buffer.concat(chunks).toString());
        if (!body || !body.trim()) {
          status = 400;
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'body is required' }));
          end({ method: 'POST', path: '/api/messages', status: 400 });
          return;
        }
        const { rows } = await client.query(
          'INSERT INTO messages (body) VALUES ($1) RETURNING id, body, created_at',
          [body.trim().slice(0, 280)]
        );
        messagesPosted.inc();
        messagesCurrent.inc();
        res.writeHead(201, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(rows[0]));
        end({ method: 'POST', path: '/api/messages', status: 201 });
        return;
      }

      // --- Delete all messages ---
      if (req.method === 'DELETE' && req.url === '/api/messages') {
        await client.query('DELETE FROM messages');
        messagesDeleted.inc();
        messagesCurrent.set(0);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ deleted: true }));
        end({ method: 'DELETE', path: '/api/messages', status: 200 });
        return;
      }

      // --- Health ---
      if (req.url === '/health') {
        res.writeHead(200);
        res.end('ok');
        end({ method: req.method, path: '/health', status: 200 });
        return;
      }

      status = 404;
      res.writeHead(404);
      res.end('Not found');
      end({ method: req.method, path: req.url, status: 404 });
    } catch (err) {
      console.error('❌', err.message);
      status = 500;
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: err.message }));
      end({ method: req.method, path: req.url, status: 500 });
    }
  });

  server.listen(PORT, () => {
    console.log('🚀 Server running on http://localhost:' + PORT);
    console.log('📊 Metrics at http://localhost:' + PORT + '/metrics');
  });
}

start().catch(err => {
  console.error('💀 Failed to start:', err.message);
  process.exit(1);
});