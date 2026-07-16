const { SlashCommandBuilder, PermissionFlagsBits, ChannelType, EmbedBuilder } = require('discord.js');
const db = require('../db');

const SOURCE_LABELS = {
  steam: 'Steam',
  gog: 'GOG',
  epic: 'Epic Games',
  'drm-free': 'DRM-Free',
  ps4: 'PlayStation 4',
  ps5: 'PlayStation 5',
  'xbox-series-xs': 'Xbox Series X/S',
  'xbox-one': 'Xbox One',
  switch: 'Nintendo Switch',
  android: 'Android',
  ios: 'iOS',
  itchio: 'itch.io',
};

const SOURCE_CHOICES = Object.entries(SOURCE_LABELS).map(([value, name]) => ({ name, value }));

module.exports = {
  data: new SlashCommandBuilder()
    .setName('freegames')
    .setDescription('Get announcements when a game goes permanently free on a supported store or platform')
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild)
    .addSubcommand(sub => sub
      .setName('enable')
      .setDescription('Turn on free game announcements for a source')
      .addStringOption(opt => opt.setName('source').setDescription('Which store or platform to track').setRequired(true)
        .addChoices(...SOURCE_CHOICES))
      .addChannelOption(opt => opt.setName('channel').setDescription('Channel to post announcements in').addChannelTypes(ChannelType.GuildText).setRequired(true)))
    .addSubcommand(sub => sub
      .setName('disable')
      .setDescription('Turn off free game announcements for a source')
      .addStringOption(opt => opt.setName('source').setDescription('Which store or platform to stop tracking').setRequired(true)
        .addChoices(...SOURCE_CHOICES)))
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
