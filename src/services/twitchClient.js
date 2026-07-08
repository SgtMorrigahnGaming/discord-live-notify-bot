const config = require('../config');
const logger = require('../utils/logger');

let cachedToken = null; // { access_token, expires_at }

async function getAppAccessToken() {
  if (cachedToken && Date.now() < cachedToken.expires_at - 60_000) {
    return cachedToken.access_token;
  }
  const params = new URLSearchParams({
    client_id: config.twitch.clientId,
    client_secret: config.twitch.clientSecret,
    grant_type: 'client_credentials',
  });
  const res = await fetch(`https://id.twitch.tv/oauth2/token?${params.toString()}`, { method: 'POST' });
  const body = await res.json();
  if (!res.ok) {
    throw new Error(`Failed to get Twitch app token: ${JSON.stringify(body)}`);
  }
  cachedToken = {
    access_token: body.access_token,
    expires_at: Date.now() + body.expires_in * 1000,
  };
  return cachedToken.access_token;
}

function chunk(arr, size) {
  const out = [];
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

/**
 * Given a list of streamer logins, returns a Map of login -> stream data (only for those currently live).
 * Batches requests in groups of 100 (Twitch Helix max per request) regardless of how many
 * Discord servers are tracking each streamer, so cost scales with unique streamers, not with guild count.
 */
async function getLiveStreams(streamerLogins) {
  if (streamerLogins.length === 0) return new Map();
  const token = await getAppAccessToken();
  const results = new Map();

  for (const batch of chunk(streamerLogins, 100)) {
    const params = new URLSearchParams();
    for (const login of batch) params.append('user_login', login);
    const res = await fetch(`https://api.twitch.tv/helix/streams?${params.toString()}`, {
      method: 'GET',
      headers: {
        'Client-Id': config.twitch.clientId,
        Authorization: `Bearer ${token}`,
      },
    });
    const body = await res.json();
    if (!res.ok) {
      logger.error('Twitch getLiveStreams error', res.status, body);
      continue;
    }
    for (const stream of body.data) {
      results.set(stream.user_login.toLowerCase(), stream);
    }
  }
  return results;
}

/** Resolve profile info (avatar, display name) for embeds. Batched the same way. */
async function getUsers(streamerLogins) {
  if (streamerLogins.length === 0) return new Map();
  const token = await getAppAccessToken();
  const results = new Map();

  for (const batch of chunk(streamerLogins, 100)) {
    const params = new URLSearchParams();
    for (const login of batch) params.append('login', login);
    const res = await fetch(`https://api.twitch.tv/helix/users?${params.toString()}`, {
      method: 'GET',
      headers: {
        'Client-Id': config.twitch.clientId,
        Authorization: `Bearer ${token}`,
      },
    });
    const body = await res.json();
    if (!res.ok) {
      logger.error('Twitch getUsers error', res.status, body);
      continue;
    }
    for (const user of body.data) {
      results.set(user.login.toLowerCase(), user);
    }
  }
  return results;
}

/** Validate that a login exists on Twitch (used when a server admin adds a subscription). */
async function userExists(streamerLogin) {
  const users = await getUsers([streamerLogin]);
  return users.get(streamerLogin.toLowerCase()) || null;
}

module.exports = { getLiveStreams, getUsers, userExists };
