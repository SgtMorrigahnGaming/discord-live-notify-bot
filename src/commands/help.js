const { SlashCommandBuilder, EmbedBuilder } = require('discord.js');

module.exports = {
  data: new SlashCommandBuilder()
    .setName('help')
    .setDescription('Show info about this bot and its commands'),

  async execute(interaction) {
    const embed = new EmbedBuilder()
      .setColor(0x5865f2)
      .setTitle('Live & Upload Notifier')
      .setDescription('Get announcements when a Twitch streamer goes live or a YouTube channel uploads. No limit on how many streamers/channels you can track.')
      .addFields(
        { name: '/twitch add', value: 'Track a Twitch streamer (username, channel, optional role/message)' },
        { name: '/twitch remove', value: 'Stop tracking a streamer' },
        { name: '/twitch list', value: 'List tracked streamers' },
        { name: '/youtube add', value: 'Track a YouTube channel (handle/URL, channel, optional role/message)' },
        { name: '/youtube remove', value: 'Stop tracking a channel' },
        { name: '/youtube list', value: 'List tracked channels' },
      )
      .setFooter({ text: 'All commands require the "Manage Server" permission.' });

    return interaction.reply({ embeds: [embed], ephemeral: true });
  },
};
