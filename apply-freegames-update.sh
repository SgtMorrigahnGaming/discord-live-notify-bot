#!/bin/bash
set -e
echo "Setting up free games files..."
mkdir -p src/services src/commands
cat > src/services/epicClient.js << 'EOF_MARKER_src_services_epicClient_js'
const logger = require('../utils/logger');

const ENDPOINT = 'https://store-site-backend-static.ak.epicgames.com/freeGamesPromotions';

function isCurrentlyFree(offer) {
  const active = offer.promotions?.promotionalOffers;
  if (!active || active.length === 0) return false;
  return active.some(window =>
    window.promotionalOffers?.some(po => po.discountSetting?.discountPercentage === 0)
  );
}

function bestImage(offer) {
  const images = offer.keyImages || [];
  return (
    images.find(i => i.type === 'OfferImageWide')?.url ||
    images.find(i => i.type === 'Thumbnail')?.url ||
    images[0]?.url ||
    null
  );
}

function buildUrl(offer) {
  const slug = offer.productSlug || offer.catalogNs?.mappings?.[0]?.pageSlug || offer.urlSlug;
  return slug ? `https://store.epicgames.com/en-US/p/${slug}` : 'https://store.epicgames.com/en-US/free-games';
}

/** Returns currently-free games as a normalized array: { externalId, title, description, url, image }. */
async function fetchCurrentFreeGames() {
  const res = await fetch(`${ENDPOINT}?locale=en-US&country=US&allowCountries=US`, {
    headers: { 'User-Agent': 'Mozilla/5.0 (compatible; DiscordLiveNotifyBot/1.0)' },
  });
  if (!res.ok) {
    logger.warn(`Epic free games fetch failed: HTTP ${res.status}`);
    return [];
  }
  const body = await res.json();
  const elements = body?.data?.Catalog?.searchStore?.elements;
  if (!Array.isArray(elements)) {
    logger.warn('Epic free games: unexpected response shape, no elements array found');
    return [];
  }

  return elements
    .filter(isCurrentlyFree)
    .map(offer => ({
      externalId: offer.id || `${offer.namespace}-${offer.title}`,
      title: offer.title,
      description: offer.description || null,
      url: buildUrl(offer),
      image: bestImage(offer),
    }));
}

module.exports = { fetchCurrentFreeGames };
EOF_MARKER_src_services_epicClient_js

cat > src/services/gamerPowerClient.js << 'EOF_MARKER_src_services_gamerPowerClient_js'
const logger = require('../utils/logger');

const ENDPOINT = 'https://www.gamerpower.com/api/giveaways';

const PLATFORM_MAP = {
  steam: 'steam',
  gog: 'gog',
};

/** Returns currently-live giveaways for a platform, normalized: { externalId, title, description, url, image }. */
async function fetchGiveaways(source) {
  const platform = PLATFORM_MAP[source];
  if (!platform) throw new Error(`Unknown GamerPower source: ${source}`);

  const res = await fetch(`${ENDPOINT}?platform=${platform}&type=game`, {
    headers: { 'User-Agent': 'Mozilla/5.0 (compatible; DiscordLiveNotifyBot/1.0)' },
  });
  if (!res.ok) {
    logger.warn(`GamerPower fetch failed for ${source}: HTTP ${res.status}`);
    return [];
  }
  const body = await res.json();
  if (!Array.isArray(body)) {
    logger.warn(`GamerPower: unexpected response shape for ${source} (expected an array)`);
    return [];
  }

  return body
    .filter(g => g.status === 'active' || !g.status) // be lenient — field naming has shifted before across API versions
    .map(g => ({
      externalId: String(g.id),
      title: g.title,
      description: g.description || null,
      url: g.open_giveaway_url || g.gamerpower_url || 'https://www.gamerpower.com',
      image: g.image || g.thumbnail || null,
    }));
}

module.exports = { fetchGiveaways };
EOF_MARKER_src_services_gamerPowerClient_js

cat > src/services/freeGamesPoller.js << 'EOF_MARKER_src_services_freeGamesPoller_js'
const db = require('../db');
const epicClient = require('./epicClient');
const gamerPowerClient = require('./gamerPowerClient');
const { announceFreeGame } = require('./announcer');
const logger = require('../utils/logger');
const config = require('../config');

let running = false;

async function fetchForSource(source) {
  try {
    if (source === 'epic') return await epicClient.fetchCurrentFreeGames();
    return await gamerPowerClient.fetchGiveaways(source);
  } catch (err) {
    logger.error(`Free games: failed to fetch source ${source}:`, err.message);
    return [];
  }
}

async function pollOnce(client) {
  if (running) return;
  running = true;
  try {
    const sources = db.listActiveFreeGamesSources();
    if (sources.length === 0) return;

    let announced = 0;

    for (const source of sources) {
      const games = await fetchForSource(source);
      const subs = db.listGuildSubsForFreeGamesSource(source);
      if (subs.length === 0) continue;

      for (const game of games) {
        if (!game.externalId || !game.title) continue;
        if (db.hasAnnouncedFreeGame(source, game.externalId)) continue;

        db.markFreeGameAnnounced(source, game.externalId);
        for (const sub of subs) {
          await announceFreeGame(client, sub, source, game);
        }
        announced++;
      }
    }

    if (announced > 0) {
      logger.info(`Free games: announced ${announced} new giveaway(s) across subscribed guilds`);
    }
  } catch (err) {
    logger.error('Free games poll error:', err);
  } finally {
    running = false;
  }
}

function start(client) {
  logger.info(`Starting free games poller (every ${config.freegames.pollIntervalMs / 1000}s)`);
  pollOnce(client);
  setInterval(() => pollOnce(client), config.freegames.pollIntervalMs);
}

module.exports = { start, pollOnce };
EOF_MARKER_src_services_freeGamesPoller_js

cat > src/commands/freegames.js << 'EOF_MARKER_src_commands_freegames_js'
const { SlashCommandBuilder, PermissionFlagsBits, ChannelType, EmbedBuilder } = require('discord.js');
const db = require('../db');

const SOURCE_LABELS = { steam: 'Steam', gog: 'GOG', epic: 'Epic Games' };

module.exports = {
  data: new SlashCommandBuilder()
    .setName('freegames')
    .setDescription('Get announcements when a game goes permanently free on Steam, GOG, or Epic')
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild)
    .addSubcommand(sub => sub
      .setName('enable')
      .setDescription('Turn on free game announcements for a source')
      .addStringOption(opt => opt.setName('source').setDescription('Which store to track').setRequired(true)
        .addChoices({ name: 'Steam', value: 'steam' }, { name: 'GOG', value: 'gog' }, { name: 'Epic Games', value: 'epic' }))
      .addChannelOption(opt => opt.setName('channel').setDescription('Channel to post announcements in').addChannelTypes(ChannelType.GuildText).setRequired(true)))
    .addSubcommand(sub => sub
      .setName('disable')
      .setDescription('Turn off free game announcements for a source')
      .addStringOption(opt => opt.setName('source').setDescription('Which store to stop tracking').setRequired(true)
        .addChoices({ name: 'Steam', value: 'steam' }, { name: 'GOG', value: 'gog' }, { name: 'Epic Games', value: 'epic' })))
    .addSubcommand(sub => sub
      .setName('list')
      .setDescription('Show which free game sources are enabled for this server')),

  async execute(interaction) {
    const sub = interaction.options.getSubcommand();

    if (sub === 'enable') {
      const source = interaction.options.getString('source');
      const channel = interaction.options.getChannel('channel');
      db.addFreeGamesSub(interaction.guildId, source, channel.id);
      return interaction.reply({ content: `✅ ${SOURCE_LABELS[source]} free game announcements will now post in ${channel}.`, ephemeral: true });
    }

    if (sub === 'disable') {
      const source = interaction.options.getString('source');
      const changes = db.removeFreeGamesSub(interaction.guildId, source);
      if (changes === 0) {
        return interaction.reply({ content: `⚠️ ${SOURCE_LABELS[source]} wasn't enabled in this server.`, ephemeral: true });
      }
      return interaction.reply({ content: `🔕 ${SOURCE_LABELS[source]} free game announcements turned off.`, ephemeral: true });
    }

    if (sub === 'list') {
      const subs = db.listFreeGamesSubsForGuild(interaction.guildId);
      if (subs.length === 0) {
        return interaction.reply({ content: 'No free game sources enabled yet. Use `/freegames enable` to get started.', ephemeral: true });
      }
      const embed = new EmbedBuilder()
        .setColor(0x5865f2)
        .setTitle('Free game sources')
        .setDescription(subs.map(s => `**${SOURCE_LABELS[s.source]}** → <#${s.channel_id}>`).join('\n'));
      return interaction.reply({ embeds: [embed], ephemeral: true });
    }
  },
};
EOF_MARKER_src_commands_freegames_js

echo "Free games files written."
