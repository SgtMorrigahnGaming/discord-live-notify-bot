const { SlashCommandBuilder, EmbedBuilder } = require('discord.js');
const config = require('../config');

module.exports = {
  data: new SlashCommandBuilder()
    .setName('help')
    .setDescription('Show info about this bot and its commands'),

  async execute(interaction) {
    const embed = new EmbedBuilder()
      .setColor(0x5865f2)
      .setTitle('VVC Skald Bot')
      .setDescription('A free, open-source community bot — Twitch/YouTube alerts, free games, reaction roles, welcome cards, polls, giveaways, and mod tools. Every feature below is also manageable from the web dashboard.')
      .addFields(
        { name: '/twitch add | remove | list', value: 'Track a Twitch streamer (username, channel, optional role/message) — no limit on how many' },
        { name: '/youtube add | remove | list', value: 'Track a YouTube channel (handle, URL, or channel ID, optional role/message)' },
        { name: '/freegames enable | disable | list', value: 'Subscribe this server to free-game alerts, per platform (Epic, Steam, GOG, and more)' },
        { name: '/reactionroles create-panel | edit-panel | add | remove', value: 'Build and manage button-based reaction role panels' },
        { name: '/welcome setup | test | enable | disable', value: 'Configure the welcome card posted when someone joins, with an optional DM' },
        { name: '/poll create | close | results | list', value: 'Native Discord polls with a guided builder and live results' },
        { name: '/giveaway create | close | results | list', value: 'Giveaways with role-gating, booster bonus entries, and auto-close' },
        { name: 'Mod action logging & spam detection', value: 'Dashboard-only — no commands. Every server\'s channel layout is different, so you choose the channels yourself.' },
      )
      .setFooter({ text: 'All commands require the "Manage Server" permission.' });

    if (config.web.enabled && config.web.publicUrl) {
      embed.addFields({ name: 'Dashboard', value: config.web.publicUrl });
    }

    return interaction.reply({ embeds: [embed], ephemeral: true });
  },
};
