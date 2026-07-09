#!/bin/bash
set -e
echo "Setting up web dashboard files..."
mkdir -p src/web/public
cat > src/web/discordOAuth.js << 'EOF_MARKER_src_web_discordOAuth_js'
const config = require('../config');

const MANAGE_GUILD = 0x20;

function redirectUri() {
  return `${config.web.publicUrl}/auth/discord/callback`;
}

function getAuthorizeUrl(state) {
  const params = new URLSearchParams({
    client_id: config.discord.clientId,
    redirect_uri: redirectUri(),
    response_type: 'code',
    scope: 'identify guilds',
    state,
    prompt: 'consent',
  });
  return `https://discord.com/api/oauth2/authorize?${params.toString()}`;
}

async function exchangeCode(code) {
  const params = new URLSearchParams({
    client_id: config.discord.clientId,
    client_secret: config.web.clientSecret,
    grant_type: 'authorization_code',
    code,
    redirect_uri: redirectUri(),
  });
  const res = await fetch('https://discord.com/api/oauth2/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: params.toString(),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`Discord token exchange failed: ${JSON.stringify(body)}`);
  return body; // { access_token, refresh_token, expires_in, ... }
}

async function getUser(accessToken) {
  const res = await fetch('https://discord.com/api/users/@me', {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!res.ok) throw new Error(`Failed to fetch Discord user: ${res.status}`);
  return res.json(); // { id, username, avatar, ... }
}

/** Returns guilds the user can manage (owner or has Manage Server), regardless of whether the bot is in them. */
async function getManageableGuilds(accessToken) {
  const res = await fetch('https://discord.com/api/users/@me/guilds', {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!res.ok) throw new Error(`Failed to fetch Discord guilds: ${res.status}`);
  const guilds = await res.json();
  return guilds.filter(g => g.owner || (Number(g.permissions) & MANAGE_GUILD) === MANAGE_GUILD);
}

module.exports = { getAuthorizeUrl, exchangeCode, getUser, getManageableGuilds };
EOF_MARKER_src_web_discordOAuth_js

cat > src/web/authMiddleware.js << 'EOF_MARKER_src_web_authMiddleware_js'
function requireAuth(req, res, next) {
  if (!req.session.user) {
    return res.status(401).json({ error: 'Not logged in' });
  }
  next();
}

/**
 * Verifies the logged-in user can manage :guildId (owner or Manage Server on Discord's side,
 * captured at login time) AND that the bot is actually a member of that guild.
 */
function requireGuildAccess(client) {
  return (req, res, next) => {
    const { guildId } = req.params;
    const manageable = req.session.manageableGuildIds || [];
    if (!manageable.includes(guildId)) {
      return res.status(403).json({ error: "You don't have permission to manage this server" });
    }
    if (!client.guilds.cache.has(guildId)) {
      return res.status(404).json({ error: 'The bot is not a member of this server' });
    }
    next();
  };
}

module.exports = { requireAuth, requireGuildAccess };
EOF_MARKER_src_web_authMiddleware_js

cat > src/web/api.js << 'EOF_MARKER_src_web_api_js'
const express = require('express');
const { PermissionsBitField, ChannelType } = require('discord.js');
const db = require('../db');
const twitchClient = require('../services/twitchClient');
const youtubeClient = require('../services/youtubeClient');
const { requireAuth, requireGuildAccess } = require('./authMiddleware');

function buildRouter(client) {
  const router = express.Router();
  router.use(requireAuth);

  // ---- Guilds the logged-in user can manage AND the bot is present in ----
  router.get('/guilds', (req, res) => {
    const manageable = req.session.manageableGuildIds || [];
    const guilds = manageable
      .map(id => client.guilds.cache.get(id))
      .filter(Boolean)
      .map(g => ({ id: g.id, name: g.name, icon: g.iconURL({ size: 64 }) }));
    res.json(guilds);
  });

  const guildRouter = express.Router({ mergeParams: true });
  guildRouter.use(requireGuildAccess(client));
  router.use('/guilds/:guildId', guildRouter);

  // ---- Text channels + roles for building dropdowns in the UI ----
  guildRouter.get('/channels', (req, res) => {
    const guild = client.guilds.cache.get(req.params.guildId);
    const me = guild.members.me;
    const channels = guild.channels.cache
      .filter(c => c.type === ChannelType.GuildText && c.permissionsFor(me)?.has(PermissionsBitField.Flags.SendMessages))
      .map(c => ({ id: c.id, name: c.name }))
      .sort((a, b) => a.name.localeCompare(b.name));
    res.json(channels);
  });

  guildRouter.get('/roles', (req, res) => {
    const guild = client.guilds.cache.get(req.params.guildId);
    const roles = guild.roles.cache
      .filter(r => r.id !== guild.id) // exclude @everyone
      .map(r => ({ id: r.id, name: r.name }))
      .sort((a, b) => a.name.localeCompare(b.name));
    res.json(roles);
  });

  // ---- Twitch subscriptions ----
  guildRouter.get('/twitch', (req, res) => {
    res.json(db.listTwitchSubsForGuild(req.params.guildId));
  });

  guildRouter.post('/twitch', async (req, res) => {
    const { username, channelId, roleId, message } = req.body;
    if (!username || !channelId) {
      return res.status(400).json({ error: 'username and channelId are required' });
    }
    if (!process.env.TWITCH_CLIENT_ID || !process.env.TWITCH_CLIENT_SECRET) {
      return res.status(400).json({ error: 'Twitch API credentials are not configured on this bot instance' });
    }
    let user;
    try {
      user = await twitchClient.userExists(username.trim().toLowerCase());
    } catch (err) {
      return res.status(502).json({ error: `Couldn't reach Twitch: ${err.message}` });
    }
    if (!user) {
      return res.status(404).json({ error: `No Twitch user found with username "${username}"` });
    }
    db.addTwitchSub(req.params.guildId, username.trim().toLowerCase(), channelId, roleId || null, message || null);
    res.json({ ok: true, displayName: user.display_name });
  });

  guildRouter.delete('/twitch/:username', (req, res) => {
    const changes = db.removeTwitchSub(req.params.guildId, req.params.username);
    if (changes === 0) return res.status(404).json({ error: 'Not tracked' });
    res.json({ ok: true });
  });

  // ---- YouTube subscriptions ----
  guildRouter.get('/youtube', (req, res) => {
    res.json(db.listYoutubeSubsForGuild(req.params.guildId));
  });

  guildRouter.post('/youtube', async (req, res) => {
    const { channelUrl, channelId: announceChannelId, roleId, message } = req.body;
    if (!channelUrl || !announceChannelId) {
      return res.status(400).json({ error: 'channelUrl and channelId are required' });
    }
    let channelId;
    try {
      channelId = await youtubeClient.resolveChannelId(channelUrl.trim());
    } catch (err) {
      return res.status(502).json({ error: `Couldn't reach YouTube: ${err.message}` });
    }
    if (!channelId) {
      return res.status(404).json({ error: `Couldn't find a YouTube channel for "${channelUrl}"` });
    }
    let result;
    try {
      result = await youtubeClient.getLatestVideo(channelId);
    } catch (err) {
      return res.status(502).json({ error: `Found the channel but couldn't read its feed: ${err.message}` });
    }
    const channelName = result?.channelName || channelUrl;
    db.addYoutubeSub(req.params.guildId, channelId, channelName, announceChannelId, roleId || null, message || null);

    const state = db.getYoutubeState(channelId);
    if (result?.latest && (!state || !state.initialized)) {
      db.setYoutubeState(channelId, result.latest.videoId);
    }
    res.json({ ok: true, channelName });
  });

  guildRouter.delete('/youtube/:channelId', (req, res) => {
    const changes = db.removeYoutubeSub(req.params.guildId, req.params.channelId);
    if (changes === 0) return res.status(404).json({ error: 'Not tracked' });
    res.json({ ok: true });
  });

  return router;
}

module.exports = buildRouter;
EOF_MARKER_src_web_api_js

cat > src/web/server.js << 'EOF_MARKER_src_web_server_js'
const path = require('path');
const crypto = require('crypto');
const express = require('express');
const session = require('express-session');
const config = require('../config');
const logger = require('../utils/logger');
const oauth = require('./discordOAuth');
const buildApiRouter = require('./api');

function start(client) {
  if (!config.web.enabled) {
    logger.info('Web dashboard disabled (set WEB_ENABLED=true in .env to enable it).');
    return;
  }
  if (!config.web.publicUrl || !config.web.clientSecret || !config.web.sessionSecret) {
    logger.warn('Web dashboard enabled but WEB_PUBLIC_URL / DISCORD_CLIENT_SECRET / SESSION_SECRET is missing — dashboard NOT started.');
    return;
  }

  const app = express();
  app.set('trust proxy', 1); // we sit behind a reverse proxy (nginx/Caddy) terminating TLS
  app.use(express.json());
  app.use(session({
    secret: config.web.sessionSecret,
    resave: false,
    saveUninitialized: false,
    cookie: {
      httpOnly: true,
      secure: config.web.publicUrl.startsWith('https://'),
      sameSite: 'lax',
      maxAge: 7 * 24 * 60 * 60 * 1000, // 7 days
    },
  }));

  // ---- Auth routes ----
  app.get('/auth/discord/login', (req, res) => {
    const state = crypto.randomBytes(16).toString('hex');
    req.session.oauthState = state;
    res.redirect(oauth.getAuthorizeUrl(state));
  });

  app.get('/auth/discord/callback', async (req, res) => {
    const { code, state } = req.query;
    if (!code || !state || state !== req.session.oauthState) {
      return res.status(400).send('Invalid OAuth state — please try logging in again.');
    }
    delete req.session.oauthState;

    try {
      const tokenData = await oauth.exchangeCode(code);
      const user = await oauth.getUser(tokenData.access_token);
      const manageableGuilds = await oauth.getManageableGuilds(tokenData.access_token);

      req.session.user = { id: user.id, username: user.username, avatar: user.avatar };
      req.session.manageableGuildIds = manageableGuilds.map(g => g.id);

      res.redirect('/');
    } catch (err) {
      logger.error('OAuth callback error:', err);
      res.status(500).send('Login failed — check server logs.');
    }
  });

  app.post('/auth/logout', (req, res) => {
    req.session.destroy(() => res.json({ ok: true }));
  });

  app.get('/api/me', (req, res) => {
    if (!req.session.user) return res.status(401).json({ error: 'Not logged in' });
    res.json(req.session.user);
  });

  // ---- API ----
  app.use('/api', buildApiRouter(client));

  // ---- Static frontend ----
  app.use(express.static(path.join(__dirname, 'public')));
  // Catch-all so client-side routes still load index.html (Express 5 no longer accepts a bare '*' route)
  app.use((req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
  });

  app.listen(config.web.port, () => {
    logger.info(`Web dashboard listening on port ${config.web.port} (public URL: ${config.web.publicUrl})`);
  });
}

module.exports = { start };
EOF_MARKER_src_web_server_js

cat > src/web/public/index.html << 'EOF_MARKER_src_web_public_index_html'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>Live & Upload Notifier</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@500;600;700&family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@500&display=swap" rel="stylesheet">
<style>
  :root {
    --bg: #0e0f13;
    --panel: #16181f;
    --panel-border: #262935;
    --text: #e8e9ee;
    --text-dim: #8a8d9a;
    --twitch: #9146ff;
    --twitch-dim: #9146ff33;
    --youtube: #ff3b3b;
    --youtube-dim: #ff3b3b33;
    --ok: #3ddc97;
    --err: #ff5c5c;
    --radius: 10px;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font-family: 'Inter', sans-serif;
    min-height: 100vh;
  }
  h1, h2, h3, .display { font-family: 'Space Grotesk', sans-serif; }
  .mono { font-family: 'JetBrains Mono', monospace; }

  /* --- Login screen --- */
  #loginScreen {
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-direction: column;
    gap: 28px;
    text-align: center;
    padding: 24px;
  }
  .on-air {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    font-family: 'JetBrains Mono', monospace;
    font-size: 12px;
    letter-spacing: 0.12em;
    color: var(--youtube);
    border: 1px solid var(--youtube-dim);
    background: var(--youtube-dim);
    padding: 6px 12px;
    border-radius: 999px;
  }
  .on-air .dot {
    width: 7px; height: 7px; border-radius: 50%;
    background: var(--youtube);
    animation: pulse 1.6s infinite ease-in-out;
  }
  @keyframes pulse {
    0%, 100% { opacity: 1; box-shadow: 0 0 0 0 var(--youtube-dim); }
    50% { opacity: 0.5; }
  }
  #loginScreen h1 { font-size: 40px; margin: 0; }
  #loginScreen p { color: var(--text-dim); max-width: 420px; margin: 0; }
  .btn-discord {
    display: inline-flex; align-items: center; gap: 10px;
    background: #5865f2; color: white; border: none;
    padding: 14px 26px; border-radius: var(--radius);
    font-family: 'Space Grotesk', sans-serif; font-weight: 600; font-size: 15px;
    cursor: pointer; text-decoration: none;
    transition: transform 0.15s ease, background 0.15s ease;
  }
  .btn-discord:hover { background: #4954c4; transform: translateY(-1px); }

  /* --- App shell --- */
  #app { display: none; max-width: 1000px; margin: 0 auto; padding: 24px; }
  header.topbar {
    display: flex; align-items: center; justify-content: space-between;
    padding: 10px 4px 24px;
    border-bottom: 1px solid var(--panel-border);
    margin-bottom: 28px;
  }
  .brand { display: flex; align-items: center; gap: 10px; }
  .brand .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--ok); }
  .brand span.display { font-size: 18px; font-weight: 600; }
  .user-area { display: flex; align-items: center; gap: 12px; }
  .user-area img { width: 28px; height: 28px; border-radius: 50%; }
  .user-area .name { font-size: 14px; color: var(--text-dim); }
  .btn-ghost {
    background: transparent; border: 1px solid var(--panel-border); color: var(--text-dim);
    padding: 7px 14px; border-radius: 8px; font-family: inherit; font-size: 13px; cursor: pointer;
  }
  .btn-ghost:hover { color: var(--text); border-color: var(--text-dim); }

  select#guildSelect {
    background: var(--panel); color: var(--text); border: 1px solid var(--panel-border);
    padding: 10px 14px; border-radius: var(--radius); font-family: 'Space Grotesk', sans-serif;
    font-size: 14px; margin-bottom: 24px; width: 100%; max-width: 320px;
  }

  .panels { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
  @media (max-width: 800px) { .panels { grid-template-columns: 1fr; } }

  .panel {
    background: var(--panel); border: 1px solid var(--panel-border);
    border-radius: var(--radius); padding: 20px; border-top: 3px solid var(--accent);
  }
  .panel.twitch { --accent: var(--twitch); }
  .panel.youtube { --accent: var(--youtube); }
  .panel h2 {
    display: flex; align-items: center; gap: 8px;
    font-size: 16px; margin: 0 0 16px;
  }
  .panel h2 .swatch { width: 10px; height: 10px; border-radius: 3px; background: var(--accent); }

  .sub-item {
    display: flex; align-items: center; justify-content: space-between;
    padding: 10px 12px; background: #1c1f28; border-radius: 8px; margin-bottom: 8px;
    font-size: 13px;
  }
  .sub-item .meta { color: var(--text-dim); font-size: 12px; margin-top: 2px; }
  .sub-item button {
    background: transparent; border: none; color: var(--err); cursor: pointer; font-size: 12px;
    padding: 4px 8px;
  }
  .empty-state { color: var(--text-dim); font-size: 13px; padding: 12px 0; }

  form.add-form { margin-top: 16px; display: flex; flex-direction: column; gap: 10px; }
  form.add-form input, form.add-form select {
    background: #1c1f28; border: 1px solid var(--panel-border); color: var(--text);
    padding: 9px 12px; border-radius: 8px; font-family: inherit; font-size: 13px; width: 100%;
  }
  form.add-form button {
    background: var(--accent); border: none; color: #0e0f13; font-weight: 600;
    padding: 10px; border-radius: 8px; cursor: pointer; font-family: 'Space Grotesk', sans-serif;
    font-size: 13px; margin-top: 4px;
  }
  form.add-form button:hover { opacity: 0.9; }
  form.add-form button:disabled { opacity: 0.5; cursor: not-allowed; }

  #toast {
    position: fixed; bottom: 20px; left: 50%; transform: translateX(-50%);
    background: var(--panel); border: 1px solid var(--panel-border); color: var(--text);
    padding: 12px 18px; border-radius: 8px; font-size: 13px; display: none; max-width: 90vw;
  }
  #toast.ok { border-color: var(--ok); color: var(--ok); }
  #toast.err { border-color: var(--err); color: var(--err); }
</style>
</head>
<body>

  <div id="loginScreen">
    <div class="on-air"><span class="dot"></span> WAITING FOR SIGNAL</div>
    <h1>Live & Upload Notifier</h1>
    <p>Manage which Twitch streamers and YouTube channels announce to your server — no command line required.</p>
    <a class="btn-discord" href="/auth/discord/login">Continue with Discord</a>
  </div>

  <div id="app">
    <header class="topbar">
      <div class="brand"><span class="dot"></span><span class="display">Live & Upload Notifier</span></div>
      <div class="user-area">
        <img id="userAvatar" src="" alt="" />
        <span class="name" id="userName"></span>
        <button class="btn-ghost" id="logoutBtn">Log out</button>
      </div>
    </header>

    <select id="guildSelect"></select>

    <div class="panels">
      <section class="panel twitch">
        <h2><span class="swatch"></span>Twitch streamers</h2>
        <div id="twitchList"></div>
        <form class="add-form" id="twitchForm">
          <input type="text" id="twitchUsername" placeholder="Twitch username" required />
          <select id="twitchChannel" required></select>
          <select id="twitchRole"><option value="">No role ping</option></select>
          <input type="text" id="twitchMessage" placeholder="Custom message (optional) — {streamer} {title} {game} {url}" />
          <button type="submit">Track streamer</button>
        </form>
      </section>

      <section class="panel youtube">
        <h2><span class="swatch"></span>YouTube channels</h2>
        <div id="youtubeList"></div>
        <form class="add-form" id="youtubeForm">
          <input type="text" id="youtubeUrl" placeholder="Channel @handle or URL" required />
          <select id="youtubeChannel" required></select>
          <select id="youtubeRole"><option value="">No role ping</option></select>
          <input type="text" id="youtubeMessage" placeholder="Custom message (optional) — {channel} {title} {url}" />
          <button type="submit">Track channel</button>
        </form>
      </section>
    </div>
  </div>

  <div id="toast"></div>

<script>
  const state = { guildId: null };

  function toast(msg, kind) {
    const el = document.getElementById('toast');
    el.textContent = msg;
    el.className = kind || '';
    el.style.display = 'block';
    setTimeout(() => { el.style.display = 'none'; }, 4000);
  }

  async function api(path, opts) {
    const res = await fetch('/api' + path, {
      headers: { 'Content-Type': 'application/json' },
      ...opts,
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(body.error || 'Request failed');
    return body;
  }

  async function init() {
    let me;
    try {
      me = await fetch('/api/me').then(r => r.ok ? r.json() : Promise.reject());
    } catch {
      document.getElementById('loginScreen').style.display = 'flex';
      return;
    }
    document.getElementById('loginScreen').style.display = 'none';
    document.getElementById('app').style.display = 'block';
    document.getElementById('userName').textContent = me.username;
    document.getElementById('userAvatar').src = me.avatar
      ? `https://cdn.discordapp.com/avatars/${me.id}/${me.avatar}.png?size=64`
      : `https://cdn.discordapp.com/embed/avatars/0.png`;

    const guilds = await api('/guilds');
    const select = document.getElementById('guildSelect');
    if (guilds.length === 0) {
      select.innerHTML = '<option>No manageable servers with this bot installed</option>';
      return;
    }
    select.innerHTML = guilds.map(g => `<option value="${g.id}">${g.name}</option>`).join('');
    select.addEventListener('change', () => loadGuild(select.value));
    state.guildId = guilds[0].id;
    await loadGuild(state.guildId);
  }

  async function loadGuild(guildId) {
    state.guildId = guildId;
    const [channels, roles, twitchSubs, youtubeSubs] = await Promise.all([
      api(`/guilds/${guildId}/channels`),
      api(`/guilds/${guildId}/roles`),
      api(`/guilds/${guildId}/twitch`),
      api(`/guilds/${guildId}/youtube`),
    ]);

    const chanOpts = channels.map(c => `<option value="${c.id}">#${c.name}</option>`).join('');
    document.getElementById('twitchChannel').innerHTML = chanOpts;
    document.getElementById('youtubeChannel').innerHTML = chanOpts;

    const roleOpts = '<option value="">No role ping</option>' + roles.map(r => `<option value="${r.id}">@${r.name}</option>`).join('');
    document.getElementById('twitchRole').innerHTML = roleOpts;
    document.getElementById('youtubeRole').innerHTML = roleOpts;

    renderTwitchList(twitchSubs, channels, roles);
    renderYoutubeList(youtubeSubs, channels, roles);
  }

  function channelName(channels, id) { return channels.find(c => c.id === id)?.name || id; }
  function roleName(roles, id) { return id ? (roles.find(r => r.id === id)?.name || id) : null; }

  function renderTwitchList(subs, channels, roles) {
    const el = document.getElementById('twitchList');
    if (subs.length === 0) { el.innerHTML = '<div class="empty-state">No streamers tracked yet.</div>'; return; }
    el.innerHTML = subs.map(s => `
      <div class="sub-item">
        <div>
          <div>${s.streamer_login}</div>
          <div class="meta">#${channelName(channels, s.announce_channel_id)}${s.role_id ? ' • @' + roleName(roles, s.role_id) : ''}</div>
        </div>
        <button data-username="${s.streamer_login}">Remove</button>
      </div>
    `).join('');
    el.querySelectorAll('button').forEach(btn => {
      btn.addEventListener('click', async () => {
        try {
          await api(`/guilds/${state.guildId}/twitch/${btn.dataset.username}`, { method: 'DELETE' });
          toast(`Stopped tracking ${btn.dataset.username}`, 'ok');
          loadGuild(state.guildId);
        } catch (err) { toast(err.message, 'err'); }
      });
    });
  }

  function renderYoutubeList(subs, channels, roles) {
    const el = document.getElementById('youtubeList');
    if (subs.length === 0) { el.innerHTML = '<div class="empty-state">No channels tracked yet.</div>'; return; }
    el.innerHTML = subs.map(s => `
      <div class="sub-item">
        <div>
          <div>${s.channel_name || s.channel_id}</div>
          <div class="meta">#${channelName(channels, s.announce_channel_id)}${s.role_id ? ' • @' + roleName(roles, s.role_id) : ''}</div>
        </div>
        <button data-id="${s.channel_id}">Remove</button>
      </div>
    `).join('');
    el.querySelectorAll('button').forEach(btn => {
      btn.addEventListener('click', async () => {
        try {
          await api(`/guilds/${state.guildId}/youtube/${btn.dataset.id}`, { method: 'DELETE' });
          toast('Stopped tracking channel', 'ok');
          loadGuild(state.guildId);
        } catch (err) { toast(err.message, 'err'); }
      });
    });
  }

  document.getElementById('twitchForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const btn = e.target.querySelector('button');
    btn.disabled = true;
    try {
      const body = {
        username: document.getElementById('twitchUsername').value,
        channelId: document.getElementById('twitchChannel').value,
        roleId: document.getElementById('twitchRole').value || null,
        message: document.getElementById('twitchMessage').value || null,
      };
      const result = await api(`/guilds/${state.guildId}/twitch`, { method: 'POST', body: JSON.stringify(body) });
      toast(`Now tracking ${result.displayName}`, 'ok');
      e.target.reset();
      loadGuild(state.guildId);
    } catch (err) { toast(err.message, 'err'); }
    btn.disabled = false;
  });

  document.getElementById('youtubeForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const btn = e.target.querySelector('button');
    btn.disabled = true;
    try {
      const body = {
        channelUrl: document.getElementById('youtubeUrl').value,
        channelId: document.getElementById('youtubeChannel').value,
        roleId: document.getElementById('youtubeRole').value || null,
        message: document.getElementById('youtubeMessage').value || null,
      };
      const result = await api(`/guilds/${state.guildId}/youtube`, { method: 'POST', body: JSON.stringify(body) });
      toast(`Now tracking ${result.channelName}`, 'ok');
      e.target.reset();
      loadGuild(state.guildId);
    } catch (err) { toast(err.message, 'err'); }
    btn.disabled = false;
  });

  document.getElementById('logoutBtn').addEventListener('click', async () => {
    await fetch('/auth/logout', { method: 'POST' });
    location.reload();
  });

  init();
</script>
</body>
</html>
EOF_MARKER_src_web_public_index_html

echo "Files written. Run: npm install express express-session"
