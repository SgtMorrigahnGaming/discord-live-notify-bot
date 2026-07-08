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
  },
  youtube: {
    pollIntervalMs: Number(process.env.YOUTUBE_POLL_INTERVAL_MS || 300_000), // 5 min, RSS updates aren't instant anyway
  },
  db: {
    path: process.env.DB_PATH || './data/bot.sqlite',
  },
};
