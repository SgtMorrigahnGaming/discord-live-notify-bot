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

CREATE TABLE IF NOT EXISTS reaction_role_panels (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  guild_id TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  message_id TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

CREATE TABLE IF NOT EXISTS guild_welcome_config (
  guild_id TEXT PRIMARY KEY,
  channel_id TEXT NOT NULL,
  dm_message TEXT,
  enabled INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS freegames_subscriptions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  guild_id TEXT NOT NULL,
  source TEXT NOT NULL CHECK(source IN ('steam','gog','epic')),
  channel_id TEXT NOT NULL,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
  UNIQUE(guild_id, source)
);

CREATE TABLE IF NOT EXISTS freegames_announced (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source TEXT NOT NULL,
  external_id TEXT NOT NULL,
  announced_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
  UNIQUE(source, external_id)
);

-- One in-progress poll builder session per admin at a time (cleared once posted)
CREATE TABLE IF NOT EXISTS poll_drafts (
  admin_id TEXT PRIMARY KEY,
  guild_id TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  question TEXT,
  duration_hours REAL NOT NULL,
  tallies_visible INTEGER NOT NULL DEFAULT 0,
  choices_json TEXT NOT NULL DEFAULT '[]',
  updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

CREATE TABLE IF NOT EXISTS polls (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  guild_id TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  message_id TEXT,
  question TEXT NOT NULL,
  choices_json TEXT NOT NULL,
  tallies_visible INTEGER NOT NULL DEFAULT 0,
  created_by TEXT NOT NULL,
  closes_at INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','closed')),
  created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

CREATE TABLE IF NOT EXISTS poll_votes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  poll_id INTEGER NOT NULL,
  user_id TEXT NOT NULL,
  choice_index INTEGER NOT NULL,
  voted_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
  UNIQUE(poll_id, user_id)
);

-- One in-progress giveaway builder session per admin at a time (cleared once posted).
-- Holds the slash-command options (channel/role/toggles) picked before the 5-field modal is shown.
CREATE TABLE IF NOT EXISTS giveaway_drafts (
  admin_id TEXT PRIMARY KEY,
  guild_id TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  entry_role_id TEXT NOT NULL,
  booster_bonus_enabled INTEGER NOT NULL DEFAULT 0,
  auto_reroll_enabled INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

CREATE TABLE IF NOT EXISTS giveaways (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  guild_id TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  message_id TEXT,
  title TEXT NOT NULL,
  prize TEXT NOT NULL,
  description TEXT,
  winner_count INTEGER NOT NULL DEFAULT 1,
  entry_role_id TEXT NOT NULL,
  booster_bonus_enabled INTEGER NOT NULL DEFAULT 0,
  auto_reroll_enabled INTEGER NOT NULL DEFAULT 0,
  created_by TEXT NOT NULL,
  ends_at INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','closed')),
  entrant_count INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

-- Each row is one winner "slot". A reroll doesn't edit the row in place — it marks
-- the old slot as replaced and inserts a fresh row with is_reroll=1, so a rerolled
-- slot can never reroll again (single-reroll-per-slot, enforced structurally).
CREATE TABLE IF NOT EXISTS giveaway_winners (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  giveaway_id INTEGER NOT NULL,
  user_id TEXT NOT NULL,
  is_reroll INTEGER NOT NULL DEFAULT 0,
  replaced INTEGER NOT NULL DEFAULT 0,
  claimed INTEGER NOT NULL DEFAULT 0,
  unclaimed_final INTEGER NOT NULL DEFAULT 0,
  claim_deadline INTEGER NOT NULL,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

-- Who clicked "Enter Giveaway". Entry is opt-in and requires holding the giveaway's entry_role_id
-- at click time (checked in the button handler, not enforced here).
CREATE TABLE IF NOT EXISTS giveaway_entries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  giveaway_id INTEGER NOT NULL,
  user_id TEXT NOT NULL,
  entered_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
  UNIQUE(giveaway_id, user_id)
);

-- Mod Action Logging. One row per guild. Each *_channel_id is independently nullable/admin-set —
-- no hardcoded defaults, since channel layout varies a lot between servers. spam_* columns
-- configure the cross-channel spam detector, which is a distinct feature folded into this module.
CREATE TABLE IF NOT EXISTS modlog_config (
  guild_id TEXT PRIMARY KEY,
  ban_channel_id TEXT,
  kick_channel_id TEXT,
  timeout_channel_id TEXT,
  roleremove_channel_id TEXT,
  spam_channel_id TEXT,
  spam_enabled INTEGER NOT NULL DEFAULT 0,
  spam_channel_threshold INTEGER NOT NULL DEFAULT 3,
  spam_timeout_minutes INTEGER NOT NULL DEFAULT 10,
  spam_exempt_role_ids TEXT NOT NULL DEFAULT '[]',
  updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);
`);

// Backfill reaction_role_panels from pre-existing reaction_roles rows -- migration for
// installs made before panels got their own table. Safe to run on every startup
// (INSERT OR IGNORE + UNIQUE message_id makes it idempotent).
db.exec(`
  INSERT OR IGNORE INTO reaction_role_panels (guild_id, channel_id, message_id)
  SELECT DISTINCT guild_id, channel_id, message_id FROM reaction_roles
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
  createReactionRolePanel(guildId, channelId, messageId) {
    db.prepare(`
      INSERT OR IGNORE INTO reaction_role_panels (guild_id, channel_id, message_id)
      VALUES (@guildId, @channelId, @messageId)
    `).run({ guildId, channelId, messageId });
  },
  deleteReactionRolePanel(messageId) {
    const tx = db.transaction((id) => {
      db.prepare(`DELETE FROM reaction_roles WHERE message_id = ?`).run(id);
      db.prepare(`DELETE FROM reaction_role_panels WHERE message_id = ?`).run(id);
    });
    tx(messageId);
  },
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
    return db.prepare(`SELECT message_id, channel_id FROM reaction_role_panels WHERE guild_id = ? ORDER BY created_at`).all(guildId);
  },
  movePanel(oldMessageId, newMessageId, newChannelId) {
    const tx = db.transaction(() => {
      db.prepare(`
        UPDATE reaction_roles SET message_id = @newMessageId, channel_id = @newChannelId
        WHERE message_id = @oldMessageId
      `).run({ oldMessageId, newMessageId, newChannelId });
      db.prepare(`
        UPDATE reaction_role_panels SET message_id = @newMessageId, channel_id = @newChannelId
        WHERE message_id = @oldMessageId
      `).run({ oldMessageId, newMessageId, newChannelId });
    });
    tx();
  },

  // ---- Welcome config ----
  setWelcomeConfig(guildId, channelId, dmMessage) {
    db.prepare(`
      INSERT INTO guild_welcome_config (guild_id, channel_id, dm_message, enabled)
      VALUES (@guildId, @channelId, @dmMessage, 1)
      ON CONFLICT(guild_id) DO UPDATE SET
        channel_id = excluded.channel_id,
        dm_message = excluded.dm_message,
        enabled = 1
    `).run({ guildId, channelId, dmMessage });
  },
  getWelcomeConfig(guildId) {
    return db.prepare(`SELECT * FROM guild_welcome_config WHERE guild_id = ?`).get(guildId);
  },
setWelcomeEnabled(guildId, enabled) {
    return db.prepare(`UPDATE guild_welcome_config SET enabled = ? WHERE guild_id = ?`)
      .run(enabled ? 1 : 0, guildId).changes;
  },

  // ---- Free games ----
  addFreeGamesSub(guildId, source, channelId) {
    db.prepare(`
      INSERT INTO freegames_subscriptions (guild_id, source, channel_id)
      VALUES (@guildId, @source, @channelId)
      ON CONFLICT(guild_id, source) DO UPDATE SET channel_id = excluded.channel_id
    `).run({ guildId, source, channelId });
  },
  removeFreeGamesSub(guildId, source) {
    return db.prepare(`DELETE FROM freegames_subscriptions WHERE guild_id = ? AND source = ?`)
      .run(guildId, source).changes;
  },
  listFreeGamesSubsForGuild(guildId) {
    return db.prepare(`SELECT * FROM freegames_subscriptions WHERE guild_id = ?`).all(guildId);
  },
  listGuildSubsForFreeGamesSource(source) {
    return db.prepare(`SELECT * FROM freegames_subscriptions WHERE source = ?`).all(source);
  },
  listActiveFreeGamesSources() {
    return db.prepare(`SELECT DISTINCT source FROM freegames_subscriptions`).all().map(r => r.source);
  },
  hasAnnouncedFreeGame(source, externalId) {
    return !!db.prepare(`SELECT 1 FROM freegames_announced WHERE source = ? AND external_id = ?`).get(source, externalId);
  },
markFreeGameAnnounced(source, externalId) {
    db.prepare(`INSERT OR IGNORE INTO freegames_announced (source, external_id) VALUES (?, ?)`).run(source, externalId);
  },

  // ---- Polls ----
  savePollDraft(adminId, guildId, channelId, durationHours, talliesVisible) {
    db.prepare(`
      INSERT INTO poll_drafts (admin_id, guild_id, channel_id, duration_hours, tallies_visible, choices_json, question)
      VALUES (@adminId, @guildId, @channelId, @durationHours, @talliesVisible, '[]', NULL)
      ON CONFLICT(admin_id) DO UPDATE SET
        guild_id = excluded.guild_id,
        channel_id = excluded.channel_id,
        duration_hours = excluded.duration_hours,
        tallies_visible = excluded.tallies_visible,
        choices_json = '[]',
        question = NULL,
        updated_at = strftime('%s','now')
    `).run({ adminId, guildId, channelId, durationHours, talliesVisible: talliesVisible ? 1 : 0 });
  },
  getPollDraft(adminId) {
    const row = db.prepare(`SELECT * FROM poll_drafts WHERE admin_id = ?`).get(adminId);
    if (!row) return null;
    return { ...row, choices: JSON.parse(row.choices_json) };
  },
  setPollDraftQuestionAndChoices(adminId, question, choices) {
    db.prepare(`UPDATE poll_drafts SET question = ?, choices_json = ?, updated_at = strftime('%s','now') WHERE admin_id = ?`)
      .run(question, JSON.stringify(choices), adminId);
  },
  addPollDraftChoice(adminId, choiceText) {
    const draft = this.getPollDraft(adminId);
    if (!draft) return null;
    const choices = [...draft.choices, choiceText];
    db.prepare(`UPDATE poll_drafts SET choices_json = ?, updated_at = strftime('%s','now') WHERE admin_id = ?`)
      .run(JSON.stringify(choices), adminId);
    return choices;
  },
  deletePollDraft(adminId) {
    db.prepare(`DELETE FROM poll_drafts WHERE admin_id = ?`).run(adminId);
  },
  createPoll({ guildId, channelId, question, choices, talliesVisible, createdBy, closesAt }) {
    const info = db.prepare(`
      INSERT INTO polls (guild_id, channel_id, question, choices_json, tallies_visible, created_by, closes_at)
      VALUES (@guildId, @channelId, @question, @choicesJson, @talliesVisible, @createdBy, @closesAt)
    `).run({ guildId, channelId, question, choicesJson: JSON.stringify(choices), talliesVisible: talliesVisible ? 1 : 0, createdBy, closesAt });
    return info.lastInsertRowid;
  },
  setPollMessage(pollId, messageId) {
    db.prepare(`UPDATE polls SET message_id = ? WHERE id = ?`).run(messageId, pollId);
  },
  getPoll(pollId) {
    const row = db.prepare(`SELECT * FROM polls WHERE id = ?`).get(pollId);
    if (!row) return null;
    return { ...row, choices: JSON.parse(row.choices_json) };
  },
  getPollByMessageId(messageId) {
    const row = db.prepare(`SELECT * FROM polls WHERE message_id = ?`).get(messageId);
    if (!row) return null;
    return { ...row, choices: JSON.parse(row.choices_json) };
  },
  listOpenPollsPastClose(nowTs) {
    return db.prepare(`SELECT id FROM polls WHERE status = 'open' AND closes_at <= ?`).all(nowTs).map(r => r.id);
  },
  listOpenPollsForGuild(guildId) {
    const rows = db.prepare(`SELECT * FROM polls WHERE guild_id = ? AND status = 'open' ORDER BY closes_at`).all(guildId);
    return rows.map(r => ({ ...r, choices: JSON.parse(r.choices_json) }));
  },
  closePoll(pollId) {
    db.prepare(`UPDATE polls SET status = 'closed' WHERE id = ?`).run(pollId);
  },
  listPollsForGuild(guildId, limit = 50) {
    const rows = db.prepare(`SELECT * FROM polls WHERE guild_id = ? ORDER BY created_at DESC LIMIT ?`).all(guildId, limit);
    return rows.map(r => ({ ...r, choices: JSON.parse(r.choices_json) }));
  },
  deletePoll(pollId) {
    // Used when a poll fails to post (e.g. permission error) so it doesn't linger as a phantom open poll
    db.prepare(`DELETE FROM poll_votes WHERE poll_id = ?`).run(pollId);
    db.prepare(`DELETE FROM polls WHERE id = ?`).run(pollId);
  },
  castVote(pollId, userId, choiceIndex) {
    try {
      db.prepare(`INSERT INTO poll_votes (poll_id, user_id, choice_index) VALUES (?, ?, ?)`).run(pollId, userId, choiceIndex);
      return true;
    } catch (err) {
      if (err.code === 'SQLITE_CONSTRAINT_UNIQUE' || err.code === 'SQLITE_CONSTRAINT' || /UNIQUE/.test(err.message)) return false;
      throw err;
    }
  },
  getVoteCounts(pollId, numChoices) {
    const rows = db.prepare(`SELECT choice_index, COUNT(*) as cnt FROM poll_votes WHERE poll_id = ? GROUP BY choice_index`).all(pollId);
    const counts = new Array(numChoices).fill(0);
    for (const r of rows) counts[r.choice_index] = r.cnt;
    return counts;
  },

  // ---- Giveaways ----
  saveGiveawayDraft(adminId, guildId, channelId, entryRoleId, boosterEnabled, autoRerollEnabled) {
    db.prepare(`
      INSERT INTO giveaway_drafts (admin_id, guild_id, channel_id, entry_role_id, booster_bonus_enabled, auto_reroll_enabled)
      VALUES (@adminId, @guildId, @channelId, @entryRoleId, @boosterEnabled, @autoRerollEnabled)
      ON CONFLICT(admin_id) DO UPDATE SET
        guild_id = excluded.guild_id,
        channel_id = excluded.channel_id,
        entry_role_id = excluded.entry_role_id,
        booster_bonus_enabled = excluded.booster_bonus_enabled,
        auto_reroll_enabled = excluded.auto_reroll_enabled,
        updated_at = strftime('%s','now')
    `).run({
      adminId, guildId, channelId, entryRoleId,
      boosterEnabled: boosterEnabled ? 1 : 0,
      autoRerollEnabled: autoRerollEnabled ? 1 : 0,
    });
  },
  getGiveawayDraft(adminId) {
    return db.prepare(`SELECT * FROM giveaway_drafts WHERE admin_id = ?`).get(adminId);
  },
  deleteGiveawayDraft(adminId) {
    db.prepare(`DELETE FROM giveaway_drafts WHERE admin_id = ?`).run(adminId);
  },
  createGiveaway({ guildId, channelId, title, prize, description, winnerCount, entryRoleId, boosterEnabled, autoRerollEnabled, createdBy, endsAt }) {
    const info = db.prepare(`
      INSERT INTO giveaways (guild_id, channel_id, title, prize, description, winner_count, entry_role_id, booster_bonus_enabled, auto_reroll_enabled, created_by, ends_at)
      VALUES (@guildId, @channelId, @title, @prize, @description, @winnerCount, @entryRoleId, @boosterEnabled, @autoRerollEnabled, @createdBy, @endsAt)
    `).run({
      guildId, channelId, title, prize, description: description || null, winnerCount, entryRoleId,
      boosterEnabled: boosterEnabled ? 1 : 0,
      autoRerollEnabled: autoRerollEnabled ? 1 : 0,
      createdBy, endsAt,
    });
    return info.lastInsertRowid;
  },
  setGiveawayMessage(giveawayId, messageId) {
    db.prepare(`UPDATE giveaways SET message_id = ? WHERE id = ?`).run(messageId, giveawayId);
  },
  setGiveawayEntrantCount(giveawayId, entrantCount) {
    db.prepare(`UPDATE giveaways SET entrant_count = ? WHERE id = ?`).run(entrantCount, giveawayId);
  },
  // Opt-in entry (click "Enter Giveaway"). Returns true if this click added a new entry,
  // false if the user wasn't entered (e.g. they'd already left, nothing to add here).
  addGiveawayEntry(giveawayId, userId) {
    const info = db.prepare(`INSERT OR IGNORE INTO giveaway_entries (giveaway_id, user_id) VALUES (?, ?)`).run(giveawayId, userId);
    return info.changes > 0;
  },
  removeGiveawayEntry(giveawayId, userId) {
    return db.prepare(`DELETE FROM giveaway_entries WHERE giveaway_id = ? AND user_id = ?`).run(giveawayId, userId).changes > 0;
  },
  hasGiveawayEntry(giveawayId, userId) {
    return !!db.prepare(`SELECT 1 FROM giveaway_entries WHERE giveaway_id = ? AND user_id = ?`).get(giveawayId, userId);
  },
  getGiveawayEntryCount(giveawayId) {
    return db.prepare(`SELECT COUNT(*) AS cnt FROM giveaway_entries WHERE giveaway_id = ?`).get(giveawayId).cnt;
  },
  listGiveawayEntrantIds(giveawayId) {
    return db.prepare(`SELECT user_id FROM giveaway_entries WHERE giveaway_id = ?`).all(giveawayId).map(r => r.user_id);
  },
  getGiveaway(giveawayId) {
    return db.prepare(`SELECT * FROM giveaways WHERE id = ?`).get(giveawayId);
  },
  getGiveawayByMessageId(messageId) {
    return db.prepare(`SELECT * FROM giveaways WHERE message_id = ?`).get(messageId);
  },
  listOpenGiveawaysPastEnd(nowTs) {
    return db.prepare(`SELECT id FROM giveaways WHERE status = 'open' AND ends_at <= ?`).all(nowTs).map(r => r.id);
  },
  listOpenGiveawaysForGuild(guildId) {
    return db.prepare(`SELECT * FROM giveaways WHERE guild_id = ? AND status = 'open' ORDER BY ends_at`).all(guildId);
  },
  listGiveawaysForGuild(guildId, limit = 50) {
    return db.prepare(`SELECT * FROM giveaways WHERE guild_id = ? ORDER BY created_at DESC LIMIT ?`).all(guildId, limit);
  },
  closeGiveaway(giveawayId) {
    db.prepare(`UPDATE giveaways SET status = 'closed' WHERE id = ?`).run(giveawayId);
  },
  deleteGiveaway(giveawayId) {
    // Used when a giveaway fails to post (e.g. permission error) so it doesn't linger as a phantom open giveaway
    db.prepare(`DELETE FROM giveaway_winners WHERE giveaway_id = ?`).run(giveawayId);
    db.prepare(`DELETE FROM giveaway_entries WHERE giveaway_id = ?`).run(giveawayId);
    db.prepare(`DELETE FROM giveaways WHERE id = ?`).run(giveawayId);
  },
  addGiveawayWinner(giveawayId, userId, claimDeadline, isReroll = false) {
    const info = db.prepare(`
      INSERT INTO giveaway_winners (giveaway_id, user_id, is_reroll, claim_deadline)
      VALUES (@giveawayId, @userId, @isReroll, @claimDeadline)
    `).run({ giveawayId, userId, isReroll: isReroll ? 1 : 0, claimDeadline });
    return info.lastInsertRowid;
  },
  getGiveawayWinners(giveawayId) {
    return db.prepare(`SELECT * FROM giveaway_winners WHERE giveaway_id = ? ORDER BY created_at`).all(giveawayId);
  },
  getGiveawayWinner(winnerId) {
    return db.prepare(`SELECT * FROM giveaway_winners WHERE id = ?`).get(winnerId);
  },
  markGiveawayWinnerClaimed(winnerId) {
    return db.prepare(`UPDATE giveaway_winners SET claimed = 1 WHERE id = ? AND claimed = 0 AND replaced = 0`).run(winnerId).changes;
  },
  markGiveawayWinnerReplaced(winnerId) {
    db.prepare(`UPDATE giveaway_winners SET replaced = 1 WHERE id = ?`).run(winnerId);
  },
  markGiveawayWinnerUnclaimedFinal(winnerId) {
    db.prepare(`UPDATE giveaway_winners SET unclaimed_final = 1 WHERE id = ?`).run(winnerId);
  },
  // Slots eligible for a single reroll: not yet claimed, not already replaced/finalized,
  // deadline has passed, and this slot hasn't already been through a reroll itself.
  listRerollableExpiredWinners(nowTs) {
    return db.prepare(`
      SELECT gw.* FROM giveaway_winners gw
      JOIN giveaways g ON g.id = gw.giveaway_id
      WHERE gw.claimed = 0 AND gw.replaced = 0 AND gw.unclaimed_final = 0 AND gw.is_reroll = 0
        AND gw.claim_deadline <= ? AND g.status = 'closed' AND g.auto_reroll_enabled = 1
    `).all(nowTs);
  },
  // Slots past deadline that can no longer be rerolled (either already a reroll, or auto-reroll is off) —
  // these just get flagged unclaimed for the record.
  listFinalizableExpiredWinners(nowTs) {
    return db.prepare(`
      SELECT gw.* FROM giveaway_winners gw
      JOIN giveaways g ON g.id = gw.giveaway_id
      WHERE gw.claimed = 0 AND gw.replaced = 0 AND gw.unclaimed_final = 0
        AND gw.claim_deadline <= ? AND g.status = 'closed'
        AND (gw.is_reroll = 1 OR g.auto_reroll_enabled = 0)
    `).all(nowTs);
  },

  // ---- Mod Action Logging ----
  getModlogConfig(guildId) {
    const row = db.prepare(`SELECT * FROM modlog_config WHERE guild_id = ?`).get(guildId);
    if (!row) return null;
    return { ...row, spam_exempt_role_ids: JSON.parse(row.spam_exempt_role_ids) };
  },
  // Ensures a row exists so partial updates (channels-only, spam-only) always have something to UPDATE.
  ensureModlogConfig(guildId) {
    db.prepare(`INSERT OR IGNORE INTO modlog_config (guild_id) VALUES (?)`).run(guildId);
  },
  setModlogChannels(guildId, { banChannelId, kickChannelId, timeoutChannelId, roleremoveChannelId, spamChannelId }) {
    this.ensureModlogConfig(guildId);
    db.prepare(`
      UPDATE modlog_config SET
        ban_channel_id = @banChannelId,
        kick_channel_id = @kickChannelId,
        timeout_channel_id = @timeoutChannelId,
        roleremove_channel_id = @roleremoveChannelId,
        spam_channel_id = @spamChannelId,
        updated_at = strftime('%s','now')
      WHERE guild_id = @guildId
    `).run({
      guildId,
      banChannelId: banChannelId || null,
      kickChannelId: kickChannelId || null,
      timeoutChannelId: timeoutChannelId || null,
      roleremoveChannelId: roleremoveChannelId || null,
      spamChannelId: spamChannelId || null,
    });
  },
  setModlogSpamSettings(guildId, { enabled, channelThreshold, timeoutMinutes, exemptRoleIds }) {
    this.ensureModlogConfig(guildId);
    db.prepare(`
      UPDATE modlog_config SET
        spam_enabled = @enabled,
        spam_channel_threshold = @channelThreshold,
        spam_timeout_minutes = @timeoutMinutes,
        spam_exempt_role_ids = @exemptRoleIds,
        updated_at = strftime('%s','now')
      WHERE guild_id = @guildId
    `).run({
      guildId,
      enabled: enabled ? 1 : 0,
      channelThreshold,
      timeoutMinutes,
      exemptRoleIds: JSON.stringify(exemptRoleIds || []),
    });
  },
  // Fast lookup for the spam detector's hot path (every message) — avoids the JSON.parse
  // of the full config getter and only fires for guilds that have it enabled.
  listGuildsWithSpamDetectionEnabled() {
    return db.prepare(`SELECT guild_id FROM modlog_config WHERE spam_enabled = 1`).all().map(r => r.guild_id);
  },

  // ---- Full data purge (called when the bot is removed from a server) ----
  purgeGuildData(guildId) {
    const tx = db.transaction((id) => {
      db.prepare(`DELETE FROM twitch_subscriptions WHERE guild_id = ?`).run(id);
      db.prepare(`DELETE FROM youtube_subscriptions WHERE guild_id = ?`).run(id);
      db.prepare(`DELETE FROM reaction_roles WHERE guild_id = ?`).run(id);
      db.prepare(`DELETE FROM reaction_role_panels WHERE guild_id = ?`).run(id);
      db.prepare(`DELETE FROM guild_welcome_config WHERE guild_id = ?`).run(id);
      db.prepare(`DELETE FROM freegames_subscriptions WHERE guild_id = ?`).run(id);
      db.prepare(`DELETE FROM poll_drafts WHERE guild_id = ?`).run(id);
      db.prepare(`DELETE FROM poll_votes WHERE poll_id IN (SELECT id FROM polls WHERE guild_id = ?)`).run(id);
      db.prepare(`DELETE FROM polls WHERE guild_id = ?`).run(id);
      db.prepare(`DELETE FROM giveaway_drafts WHERE guild_id = ?`).run(id);
      db.prepare(`DELETE FROM giveaway_winners WHERE giveaway_id IN (SELECT id FROM giveaways WHERE guild_id = ?)`).run(id);
      db.prepare(`DELETE FROM giveaway_entries WHERE giveaway_id IN (SELECT id FROM giveaways WHERE guild_id = ?)`).run(id);
      db.prepare(`DELETE FROM giveaways WHERE guild_id = ?`).run(id);
      db.prepare(`DELETE FROM modlog_config WHERE guild_id = ?`).run(id);
    });
    tx(guildId);
    this.pruneOrphanTwitchState();
    this.pruneOrphanYoutubeState();
  },
};
