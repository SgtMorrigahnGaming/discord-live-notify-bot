require('dotenv').config();

function required(name) {
  const v = process.env[name];
  if (!v) {
    console.error(`[config] Missing required environment variable: ${name}`);
  }
  return v;
}

module.exports = {
  discord: {
    token: required('DISCORD_TOKEN'),
    clientId: required('DISCORD_CLIENT_ID'),
  },
  twitch: {
    clientId: process.env.TWITCH_CLIENT_ID || '',
    clientSecret: process.env.TWITCH_CLIENT_SECRET || '',
    pollIntervalMs: Number(process.env.TWITCH_POLL_INTERVAL_MS || 60_000),
    defaultMessage: process.env.TWITCH_DEFAULT_MESSAGE || '🔴 **{streamer}** is now live on Twitch!',
  },
  youtube: {
    pollIntervalMs: Number(process.env.YOUTUBE_POLL_INTERVAL_MS || 300_000),
    defaultMessage: process.env.YOUTUBE_DEFAULT_MESSAGE || '📺 **{channel}** just uploaded a new video!',
  },
  db: {
    path: process.env.DB_PATH || './data/bot.sqlite',
  },
web: {
    enabled: process.env.WEB_ENABLED === 'true',
    port: Number(process.env.WEB_PORT || 3000),
    publicUrl: (process.env.WEB_PUBLIC_URL || '').replace(/\/$/, ''), // e.g. https://bot.yourdomain.com
    clientSecret: process.env.DISCORD_CLIENT_SECRET || '',
    sessionSecret: process.env.SESSION_SECRET || '',
  },

};
