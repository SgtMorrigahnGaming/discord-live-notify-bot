#!/bin/bash
set -e
echo "Adding donation links to dashboard..."
mkdir -p src/web/public
cat > src/web/public/index.html << 'EOF_MARKER_INDEX_HTML'
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
    flex-wrap: wrap; gap: 12px;
  }
  .brand { display: flex; align-items: center; gap: 10px; }
  .brand .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--ok); }
  .brand span.display { font-size: 18px; font-weight: 600; }
  .topbar-right { display: flex; align-items: center; gap: 18px; flex-wrap: wrap; }
  .support-note { display: flex; align-items: center; gap: 8px; }
  .support-note span { font-size: 12px; color: var(--text-dim); }
  @media (max-width: 760px) { .support-note span { display: none; } }
  .support-icon {
    width: 28px; height: 28px; border-radius: 50%; display: flex; align-items: center; justify-content: center;
    background: #1c1f28; border: 1px solid var(--panel-border); color: var(--text-dim);
    transition: color 0.15s ease, border-color 0.15s ease;
  }
  .support-icon:hover { color: var(--text); border-color: var(--text-dim); }
  .support-icon svg { width: 15px; height: 15px; }
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

  .panel.full { grid-column: 1 / -1; }

  .source-cards { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; }
  @media (max-width: 700px) { .source-cards { grid-template-columns: 1fr; } }
  .source-card {
    background: #1c1f28; border: 1px solid var(--panel-border); border-radius: 10px; padding: 14px;
  }
  .source-card .src-name { font-family: 'Space Grotesk', sans-serif; font-weight: 600; font-size: 14px; margin-bottom: 8px; }
  .source-card .meta { color: var(--text-dim); font-size: 12px; margin-bottom: 10px; }
  .source-card select { width: 100%; margin-bottom: 8px; }
  .source-card button { width: 100%; }
  .btn-remove-inline {
    background: transparent; border: 1px solid var(--err); color: var(--err);
    padding: 8px; border-radius: 8px; cursor: pointer; font-size: 12px; width: 100%;
  }
  .btn-enable-inline {
    background: var(--ok); border: none; color: #0e0f13; font-weight: 600;
    padding: 8px; border-radius: 8px; cursor: pointer; font-size: 12px; width: 100%;
  }

  .toggle-row { display: flex; align-items: center; gap: 10px; margin: 12px 0; font-size: 13px; }
  .toggle-switch { position: relative; width: 40px; height: 22px; flex-shrink: 0; }
  .toggle-switch input { opacity: 0; width: 0; height: 0; }
  .toggle-slider {
    position: absolute; cursor: pointer; inset: 0; background: #3a3d4a; border-radius: 22px; transition: 0.2s;
  }
  .toggle-slider::before {
    content: ""; position: absolute; width: 16px; height: 16px; left: 3px; top: 3px;
    background: white; border-radius: 50%; transition: 0.2s;
  }
  .toggle-switch input:checked + .toggle-slider { background: var(--ok); }
  .toggle-switch input:checked + .toggle-slider::before { transform: translateX(18px); }

  textarea.welcome-dm {
    background: #1c1f28; border: 1px solid var(--panel-border); color: var(--text);
    padding: 9px 12px; border-radius: 8px; font-family: inherit; font-size: 13px; width: 100%;
    min-height: 70px; resize: vertical;
  }
  #welcomePreviewImg { width: 100%; border-radius: 10px; margin-top: 12px; display: none; }

  .rr-panel { background: #1c1f28; border-radius: 8px; padding: 12px; margin-bottom: 12px; }
  .rr-panel .rr-panel-title { font-size: 12px; color: var(--text-dim); margin-bottom: 8px; }
  .rr-mapping-row {
    display: flex; align-items: center; justify-content: space-between;
    padding: 6px 0; font-size: 13px; border-top: 1px solid var(--panel-border);
  }
  .rr-mapping-row:first-of-type { border-top: none; }
  .rr-add-mapping { display: flex; gap: 6px; margin-top: 10px; }
  .rr-add-mapping input, .rr-add-mapping select { flex: 1; min-width: 0; }
  .rr-add-mapping button { flex-shrink: 0; width: auto; padding: 9px 14px; }
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
      <div class="topbar-right">
        <div class="support-note">
          <span>If you like the bot, donations are always appreciated</span>
          <a class="support-icon" href="https://paypal.me/MorrigahnGaming" target="_blank" rel="noopener" title="Donate via PayPal">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="M9 8h4a2.5 2.5 0 0 1 0 5H9V8z"/><path d="M9 13v4"/></svg>
          </a>
          <a class="support-icon" href="https://ko-fi.com/sgt_morrigahngaming" target="_blank" rel="noopener" title="Support on Ko-fi">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h13a3 3 0 0 1 0 6h-1"/><path d="M4 8v8a2 2 0 0 0 2 2h7a2 2 0 0 0 2-2v-2"/><path d="M8 3c-.5 1 -1 1.5 0 3"/><path d="M11 3c-.5 1 -1 1.5 0 3"/></svg>
          </a>
        </div>
        <div class="user-area">
          <img id="userAvatar" src="" alt="" />
          <span class="name" id="userName"></span>
          <button class="btn-ghost" id="logoutBtn">Log out</button>
        </div>
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

      <section class="panel full" style="--accent: #66c0f4;">
        <h2><span class="swatch"></span>Free games</h2>
        <div class="source-cards" id="freeGamesCards"></div>
      </section>

      <section class="panel full" style="--accent: #3ddc97;">
        <h2><span class="swatch"></span>Welcome new members</h2>
        <form class="add-form" id="welcomeForm">
          <select id="welcomeChannel" required></select>
          <textarea class="welcome-dm" id="welcomeDm" placeholder="Optional DM message — {user} {server}"></textarea>
          <button type="submit">Save welcome settings</button>
        </form>
        <div class="toggle-row" id="welcomeToggleRow" style="display:none;">
          <label class="toggle-switch">
            <input type="checkbox" id="welcomeEnabledToggle" />
            <span class="toggle-slider"></span>
          </label>
          <span id="welcomeToggleLabel">Welcome messages are on</span>
        </div>
        <button class="btn-ghost" id="welcomePreviewBtn" type="button" style="margin-top: 10px;">Preview card</button>
        <img id="welcomePreviewImg" alt="Welcome card preview" />
      </section>

      <section class="panel full" style="--accent: #9146ff;">
        <h2><span class="swatch"></span>Reaction roles</h2>
        <div id="rrPanelsList"></div>
        <form class="add-form" id="rrCreateForm">
          <select id="rrChannel" required></select>
          <input type="text" id="rrTitle" placeholder="Panel title" required />
          <input type="text" id="rrDescription" placeholder="Panel description" required />
          <button type="submit">Create new panel</button>
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
    const [channels, roles, twitchSubs, youtubeSubs, freeGamesSubs, welcomeConfig, rrPanels] = await Promise.all([
      api(`/guilds/${guildId}/channels`),
      api(`/guilds/${guildId}/roles`),
      api(`/guilds/${guildId}/twitch`),
      api(`/guilds/${guildId}/youtube`),
      api(`/guilds/${guildId}/freegames`),
      api(`/guilds/${guildId}/welcome`),
      api(`/guilds/${guildId}/reactionroles/panels`),
    ]);
    state.channels = channels;
    state.roles = roles;

    const chanOpts = channels.map(c => `<option value="${c.id}">#${c.name}</option>`).join('');
    document.getElementById('twitchChannel').innerHTML = chanOpts;
    document.getElementById('youtubeChannel').innerHTML = chanOpts;
    document.getElementById('welcomeChannel').innerHTML = chanOpts;
    document.getElementById('rrChannel').innerHTML = chanOpts;

    const roleOpts = '<option value="">No role ping</option>' + roles.map(r => `<option value="${r.id}">@${r.name}</option>`).join('');
    document.getElementById('twitchRole').innerHTML = roleOpts;
    document.getElementById('youtubeRole').innerHTML = roleOpts;

    renderTwitchList(twitchSubs, channels, roles);
    renderYoutubeList(youtubeSubs, channels, roles);
    renderFreeGames(freeGamesSubs, channels);
    renderWelcome(welcomeConfig, channels);
    renderReactionRoles(rrPanels, channels, roles);
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

  // ---- Free games ----
  const FREEGAMES_SOURCES = [
    { key: 'steam', label: 'Steam' },
    { key: 'gog', label: 'GOG' },
    { key: 'epic', label: 'Epic Games' },
  ];

  function renderFreeGames(subs, channels) {
    const el = document.getElementById('freeGamesCards');
    const chanOpts = channels.map(c => `<option value="${c.id}">#${c.name}</option>`).join('');

    el.innerHTML = FREEGAMES_SOURCES.map(({ key, label }) => {
      const sub = subs.find(s => s.source === key);
      if (sub) {
        return `
          <div class="source-card">
            <div class="src-name">${label}</div>
            <div class="meta">Posting in #${channelName(channels, sub.channel_id)}</div>
            <button class="btn-remove-inline" data-source="${key}" data-action="disable">Turn off</button>
          </div>
        `;
      }
      return `
        <div class="source-card">
          <div class="src-name">${label}</div>
          <div class="meta">Not enabled</div>
          <select data-source="${key}" class="fg-channel-select">${chanOpts}</select>
          <button class="btn-enable-inline" data-source="${key}" data-action="enable">Turn on</button>
        </div>
      `;
    }).join('');

    el.querySelectorAll('button[data-action="enable"]').forEach(btn => {
      btn.addEventListener('click', async () => {
        const source = btn.dataset.source;
        const select = el.querySelector(`select[data-source="${source}"]`);
        try {
          await api(`/guilds/${state.guildId}/freegames`, { method: 'POST', body: JSON.stringify({ source, channelId: select.value }) });
          toast(`${source} free games turned on`, 'ok');
          loadGuild(state.guildId);
        } catch (err) { toast(err.message, 'err'); }
      });
    });
    el.querySelectorAll('button[data-action="disable"]').forEach(btn => {
      btn.addEventListener('click', async () => {
        const source = btn.dataset.source;
        try {
          await api(`/guilds/${state.guildId}/freegames/${source}`, { method: 'DELETE' });
          toast(`${source} free games turned off`, 'ok');
          loadGuild(state.guildId);
        } catch (err) { toast(err.message, 'err'); }
      });
    });
  }

  // ---- Welcome ----
  function renderWelcome(config, channels) {
    const toggleRow = document.getElementById('welcomeToggleRow');
    const toggle = document.getElementById('welcomeEnabledToggle');
    const toggleLabel = document.getElementById('welcomeToggleLabel');

    if (config) {
      document.getElementById('welcomeChannel').value = config.channel_id;
      document.getElementById('welcomeDm').value = config.dm_message || '';
      toggleRow.style.display = 'flex';
      toggle.checked = !!config.enabled;
      toggleLabel.textContent = config.enabled ? 'Welcome messages are on' : 'Welcome messages are off';
    } else {
      toggleRow.style.display = 'none';
    }
  }

  document.getElementById('welcomeEnabledToggle').addEventListener('change', async (e) => {
    try {
      await api(`/guilds/${state.guildId}/welcome/enabled`, { method: 'POST', body: JSON.stringify({ enabled: e.target.checked }) });
      document.getElementById('welcomeToggleLabel').textContent = e.target.checked ? 'Welcome messages are on' : 'Welcome messages are off';
      toast(e.target.checked ? 'Welcome messages turned on' : 'Welcome messages turned off', 'ok');
    } catch (err) { toast(err.message, 'err'); e.target.checked = !e.target.checked; }
  });

  document.getElementById('welcomePreviewBtn').addEventListener('click', async (e) => {
    const btn = e.target;
    btn.disabled = true;
    btn.textContent = 'Generating...';
    try {
      const res = await fetch(`/api/guilds/${state.guildId}/welcome/preview`, { method: 'POST' });
      if (!res.ok) {
        const body = await res.json().catch(() => ({}));
        throw new Error(body.error || 'Preview failed');
      }
      const blob = await res.blob();
      const img = document.getElementById('welcomePreviewImg');
      img.src = URL.createObjectURL(blob);
      img.style.display = 'block';
    } catch (err) { toast(err.message, 'err'); }
    btn.disabled = false;
    btn.textContent = 'Preview card';
  });

  // ---- Reaction roles ----
  function renderReactionRoles(panels, channels, roles) {
    const el = document.getElementById('rrPanelsList');
    if (panels.length === 0) { el.innerHTML = '<div class="empty-state">No reaction role panels yet — create one below.</div>'; return; }

    el.innerHTML = panels.map(p => `
      <div class="rr-panel" data-message-id="${p.message_id}" data-channel-id="${p.channel_id}">
        <div class="rr-panel-title">Panel in #${channelName(channels, p.channel_id)} — message ID ${p.message_id}</div>
        <div class="rr-mappings">
          ${p.mappings.map(m => `
            <div class="rr-mapping-row">
              <span>${m.emoji_id ? `[custom:${m.emoji_name}]` : m.emoji_name} → @${roleName(roles, m.role_id)}</span>
              <button data-message-id="${p.message_id}" data-emoji-id="${m.emoji_id || ''}" data-emoji-name="${m.emoji_name}">Remove</button>
            </div>
          `).join('') || '<div class="empty-state">No emoji-role pairs yet.</div>'}
        </div>
        <div class="rr-add-mapping">
          <input type="text" placeholder="Emoji" class="rr-emoji-input" />
          <select class="rr-role-select">${roles.map(r => `<option value="${r.id}">@${r.name}</option>`).join('')}</select>
          <button type="button" class="rr-add-btn">Add</button>
        </div>
      </div>
    `).join('');

    el.querySelectorAll('.rr-mapping-row button').forEach(btn => {
      btn.addEventListener('click', async () => {
        try {
          const params = new URLSearchParams({ emojiName: btn.dataset.emojiName });
          if (btn.dataset.emojiId) params.set('emojiId', btn.dataset.emojiId);
          await api(`/guilds/${state.guildId}/reactionroles/panels/${btn.dataset.messageId}/mappings?${params}`, { method: 'DELETE' });
          toast('Mapping removed', 'ok');
          loadGuild(state.guildId);
        } catch (err) { toast(err.message, 'err'); }
      });
    });

    el.querySelectorAll('.rr-add-btn').forEach(btn => {
      btn.addEventListener('click', async () => {
        const panelEl = btn.closest('.rr-panel');
        const emoji = panelEl.querySelector('.rr-emoji-input').value.trim();
        const roleId = panelEl.querySelector('.rr-role-select').value;
        if (!emoji) { toast('Enter an emoji first', 'err'); return; }
        try {
          await api(`/guilds/${state.guildId}/reactionroles/panels/${panelEl.dataset.messageId}/mappings`, {
            method: 'POST',
            body: JSON.stringify({ channelId: panelEl.dataset.channelId, emoji, roleId }),
          });
          toast('Mapping added', 'ok');
          loadGuild(state.guildId);
        } catch (err) { toast(err.message, 'err'); }
      });
    });
  }

  document.getElementById('rrCreateForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const btn = e.target.querySelector('button');
    btn.disabled = true;
    try {
      const body = {
        channelId: document.getElementById('rrChannel').value,
        title: document.getElementById('rrTitle').value,
        description: document.getElementById('rrDescription').value,
      };
      await api(`/guilds/${state.guildId}/reactionroles/panels`, { method: 'POST', body: JSON.stringify(body) });
      toast('Panel created', 'ok');
      e.target.reset();
      loadGuild(state.guildId);
    } catch (err) { toast(err.message, 'err'); }
    btn.disabled = false;
  });

  document.getElementById('welcomeForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const btn = e.target.querySelector('button');
    btn.disabled = true;
    try {
      const body = {
        channelId: document.getElementById('welcomeChannel').value,
        dmMessage: document.getElementById('welcomeDm').value || null,
      };
      await api(`/guilds/${state.guildId}/welcome`, { method: 'POST', body: JSON.stringify(body) });
      toast('Welcome settings saved', 'ok');
      loadGuild(state.guildId);
    } catch (err) { toast(err.message, 'err'); }
    btn.disabled = false;
  });

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
EOF_MARKER_INDEX_HTML

echo "Dashboard updated with donation links."
