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
