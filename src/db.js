const path = require('path');
const fs = require('fs');
const Database = require('better-sqlite3');
const config = require('./config');

const dbPath = path.resolve(config.db.path);
fs.mkdirSync(path.dirname(dbPath), { recursive: true });

const db = new Database(dbPath);
db.pragma('journal_mode = WAL');

db.exec(`
CREATE TABLE IF NOT EXISTS twitch_subscriptions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  guild_id TEXT NOT NULL,
  streamer_login TEXT NOT NULL,
  announce_channel_id TEXT NOT NULL,
  role_id TEXT,
  custom_message TEXT,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
  UNIQUE(guild_id, streamer_login)
);

CREATE TABLE IF NOT EXISTS youtube_subscriptions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  guild_id TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  channel_name TEXT,
  announce_channel_id TEXT NOT NULL,
  role_id TEXT,
  custom_message TEXT,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
  UNIQUE(guild_id, channel_id)
);

-- Shared state per unique streamer/channel, independent of how many guilds track it
CREATE TABLE IF NOT EXISTS twitch_state (
  streamer_login TEXT PRIMARY KEY,
  is_live INTEGER NOT NULL DEFAULT 0,
  last_stream_id TEXT
);

CREATE TABLE IF NOT EXISTS youtube_state (
  channel_id TEXT PRIMARY KEY,
  last_video_id TEXT,
  initialized INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS reaction_roles (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  guild_id TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  emoji_id TEXT,
  emoji_name TEXT NOT NULL,
  role_id TEXT NOT NULL,
  dm_message TEXT,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
  UNIQUE(message_id, emoji_id, emoji_name)
);

`);

module.exports = {
  raw: db,

  // ---- Twitch ----
  addTwitchSub(guildId, streamerLogin, channelId, roleId, customMessage) {
    const stmt = db.prepare(`
      INSERT INTO twitch_subscriptions (guild_id, streamer_login, announce_channel_id, role_id, custom_message)
      VALUES (@guildId, @streamerLogin, @channelId, @roleId, @customMessage)
      ON CONFLICT(guild_id, streamer_login) DO UPDATE SET
        announce_channel_id = excluded.announce_channel_id,
        role_id = excluded.role_id,
        custom_message = excluded.custom_message
    `);
    stmt.run({ guildId, streamerLogin: streamerLogin.toLowerCase(), channelId, roleId, customMessage });
    db.prepare(`INSERT OR IGNORE INTO twitch_state (streamer_login) VALUES (?)`).run(streamerLogin.toLowerCase());
  },
  removeTwitchSub(guildId, streamerLogin) {
    return db.prepare(`DELETE FROM twitch_subscriptions WHERE guild_id = ? AND streamer_login = ?`)
      .run(guildId, streamerLogin.toLowerCase()).changes;
  },
  listTwitchSubsForGuild(guildId) {
    return db.prepare(`SELECT * FROM twitch_subscriptions WHERE guild_id = ? ORDER BY streamer_login`).all(guildId);
  },
  listAllUniqueTwitchStreamers() {
    return db.prepare(`SELECT DISTINCT streamer_login FROM twitch_subscriptions`).all().map(r => r.streamer_login);
  },
  listGuildSubsForStreamer(streamerLogin) {
    return db.prepare(`SELECT * FROM twitch_subscriptions WHERE streamer_login = ?`).all(streamerLogin.toLowerCase());
  },
  getTwitchState(streamerLogin) {
    return db.prepare(`SELECT * FROM twitch_state WHERE streamer_login = ?`).get(streamerLogin.toLowerCase());
  },
  setTwitchState(streamerLogin, isLive, lastStreamId) {
    db.prepare(`
      INSERT INTO twitch_state (streamer_login, is_live, last_stream_id) VALUES (@login, @isLive, @streamId)
      ON CONFLICT(streamer_login) DO UPDATE SET is_live = excluded.is_live, last_stream_id = excluded.last_stream_id
    `).run({ login: streamerLogin.toLowerCase(), isLive: isLive ? 1 : 0, streamId: lastStreamId });
  },
  pruneOrphanTwitchState() {
    db.prepare(`
      DELETE FROM twitch_state WHERE streamer_login NOT IN (SELECT DISTINCT streamer_login FROM twitch_subscriptions)
    `).run();
  },

  // ---- YouTube ----
  addYoutubeSub(guildId, channelId, channelName, announceChannelId, roleId, customMessage) {
    const stmt = db.prepare(`
      INSERT INTO youtube_subscriptions (guild_id, channel_id, channel_name, announce_channel_id, role_id, custom_message)
      VALUES (@guildId, @channelId, @channelName, @announceChannelId, @roleId, @customMessage)
      ON CONFLICT(guild_id, channel_id) DO UPDATE SET
        channel_name = excluded.channel_name,
        announce_channel_id = excluded.announce_channel_id,
        role_id = excluded.role_id,
        custom_message = excluded.custom_message
    `);
    stmt.run({ guildId, channelId, channelName, announceChannelId, roleId, customMessage });
    db.prepare(`INSERT OR IGNORE INTO youtube_state (channel_id) VALUES (?)`).run(channelId);
  },
  removeYoutubeSub(guildId, channelId) {
    return db.prepare(`DELETE FROM youtube_subscriptions WHERE guild_id = ? AND channel_id = ?`)
      .run(guildId, channelId).changes;
  },
  listYoutubeSubsForGuild(guildId) {
    return db.prepare(`SELECT * FROM youtube_subscriptions WHERE guild_id = ? ORDER BY channel_name`).all(guildId);
  },
  listAllUniqueYoutubeChannels() {
    return db.prepare(`SELECT DISTINCT channel_id FROM youtube_subscriptions`).all().map(r => r.channel_id);
  },
  listGuildSubsForYoutubeChannel(channelId) {
    return db.prepare(`SELECT * FROM youtube_subscriptions WHERE channel_id = ?`).all(channelId);
  },
  getYoutubeState(channelId) {
    return db.prepare(`SELECT * FROM youtube_state WHERE channel_id = ?`).get(channelId);
  },
  setYoutubeState(channelId, lastVideoId) {
    db.prepare(`
      INSERT INTO youtube_state (channel_id, last_video_id, initialized) VALUES (@channelId, @videoId, 1)
      ON CONFLICT(channel_id) DO UPDATE SET last_video_id = excluded.last_video_id, initialized = 1
    `).run({ channelId, videoId: lastVideoId });
  },
  pruneOrphanYoutubeState() {
    db.prepare(`
      DELETE FROM youtube_state WHERE channel_id NOT IN (SELECT DISTINCT channel_id FROM youtube_subscriptions)
    `).run();
  },

  // ---- Reaction roles ----
  addReactionRole(guildId, channelId, messageId, emojiId, emojiName, roleId, dmMessage) {
    db.prepare(`
      INSERT INTO reaction_roles (guild_id, channel_id, message_id, emoji_id, emoji_name, role_id, dm_message)
      VALUES (@guildId, @channelId, @messageId, @emojiId, @emojiName, @roleId, @dmMessage)
      ON CONFLICT(message_id, emoji_id, emoji_name) DO UPDATE SET
        role_id = excluded.role_id,
        dm_message = excluded.dm_message
    `).run({ guildId, channelId, messageId, emojiId, emojiName, roleId, dmMessage });
  },
  removeReactionRole(messageId, emojiId, emojiName) {
    return db.prepare(`
      DELETE FROM reaction_roles
      WHERE message_id = ? AND COALESCE(emoji_id, '') = COALESCE(?, '') AND emoji_name = ?
    `).run(messageId, emojiId, emojiName).changes;
  },
  getReactionRole(messageId, emojiId, emojiName) {
    return db.prepare(`
      SELECT * FROM reaction_roles
      WHERE message_id = ? AND COALESCE(emoji_id, '') = COALESCE(?, '') AND emoji_name = ?
    `).get(messageId, emojiId, emojiName);
  },
  listReactionRolesForMessage(messageId) {
    return db.prepare(`SELECT * FROM reaction_roles WHERE message_id = ?`).all(messageId);
  },
  listReactionRolePanelsForGuild(guildId) {
    return db.prepare(`SELECT DISTINCT message_id, channel_id FROM reaction_roles WHERE guild_id = ?`).all(guildId);
  },
};
