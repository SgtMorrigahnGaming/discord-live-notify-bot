const {
  SlashCommandBuilder, PermissionFlagsBits, ChannelType,
  ModalBuilder, TextInputBuilder, TextInputStyle, ActionRowBuilder, EmbedBuilder,
} = require('discord.js');
const db = require('../db');
const { buildClosedGiveawayEmbed, buildEntrantPool } = require('../utils/giveawayFormat');

module.exports = {
  data: new SlashCommandBuilder()
    .setName('giveaway')
    .setDescription('Create and manage automatic-entry giveaways')
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild)
    .addSubcommand(sub => sub
      .setName('create')
      .setDescription('Start building a new giveaway (opens a form for title, prize, duration, description, winners)')
      .addChannelOption(opt => opt.setName('channel').setDescription('Channel to post the giveaway in').addChannelTypes(ChannelType.GuildText).setRequired(true))
      .addRoleOption(opt => opt.setName('entry_role').setDescription('Members holding this role are entered automatically').setRequired(true))
      .addStringOption(opt => opt.setName('booster_bonus').setDescription('Give server boosters 2x entries?').setRequired(true)
        .addChoices(
          { name: 'No', value: 'no' },
          { name: 'Yes — boosters get 2x entries', value: 'yes' },
        ))
      .addStringOption(opt => opt.setName('auto_reroll').setDescription("Reroll once if a winner doesn't claim within 24h?").setRequired(true)
        .addChoices(
          { name: 'No', value: 'no' },
          { name: 'Yes — reroll once per unclaimed winner', value: 'yes' },
        )))
    .addSubcommand(sub => sub
      .setName('close')
      .setDescription('End a giveaway early and pick winners now')
      .addStringOption(opt => opt.setName('message_id').setDescription('The giveaway message ID (right-click it -> Copy Message ID)').setRequired(true)))
    .addSubcommand(sub => sub
      .setName('results')
      .setDescription('Peek at a giveaway — entrant count if open, winners/claim status if closed (only visible to you)')
      .addStringOption(opt => opt.setName('message_id').setDescription('The giveaway message ID').setRequired(true)))
    .addSubcommand(sub => sub
      .setName('list')
      .setDescription('List open giveaways in this server')),

  async execute(interaction) {
    const sub = interaction.options.getSubcommand();

    if (sub === 'create') {
      const channel = interaction.options.getChannel('channel');
      const entryRole = interaction.options.getRole('entry_role');
      const boosterEnabled = interaction.options.getString('booster_bonus') === 'yes';
      const autoRerollEnabled = interaction.options.getString('auto_reroll') === 'yes';

      const perms = channel.permissionsFor(interaction.guild.members.me);
      if (!perms || !perms.has(['ViewChannel', 'SendMessages'])) {
        return interaction.reply({ content: `❌ I can't send messages in ${channel} — check my permissions there.`, ephemeral: true });
      }
      if (entryRole.managed || entryRole.id === interaction.guild.id) {
        return interaction.reply({ content: "❌ Can't use that role as the entry role — it's managed by an integration or is @everyone.", ephemeral: true });
      }

      db.saveGiveawayDraft(interaction.user.id, interaction.guildId, channel.id, entryRole.id, boosterEnabled, autoRerollEnabled);

      const modal = new ModalBuilder().setCustomId('giveaway_create_modal').setTitle('New Giveaway');
      const titleInput = new TextInputBuilder().setCustomId('title').setLabel('Title').setStyle(TextInputStyle.Short).setMaxLength(100).setRequired(true);
      const prizeInput = new TextInputBuilder().setCustomId('prize').setLabel('Prize').setStyle(TextInputStyle.Short).setMaxLength(200).setRequired(true);
      const durationInput = new TextInputBuilder().setCustomId('duration_hours').setLabel('Duration (hours)').setStyle(TextInputStyle.Short).setMaxLength(10).setRequired(true);
      const descriptionInput = new TextInputBuilder().setCustomId('description').setLabel('Description').setStyle(TextInputStyle.Paragraph).setMaxLength(1000).setRequired(false);
      const winnerCountInput = new TextInputBuilder().setCustomId('winner_count').setLabel('Winner count').setStyle(TextInputStyle.Short).setMaxLength(3).setRequired(true);

      modal.addComponents(
        new ActionRowBuilder().addComponents(titleInput),
        new ActionRowBuilder().addComponents(prizeInput),
        new ActionRowBuilder().addComponents(durationInput),
        new ActionRowBuilder().addComponents(descriptionInput),
        new ActionRowBuilder().addComponents(winnerCountInput),
      );

      return interaction.showModal(modal);
    }

    if (sub === 'close') {
      await interaction.deferReply({ ephemeral: true });
      const messageId = interaction.options.getString('message_id').trim();
      const giveaway = db.getGiveawayByMessageId(messageId);
      if (!giveaway) return interaction.editReply('❌ No giveaway found with that message ID.');
      if (giveaway.status === 'closed') return interaction.editReply('⚠️ That giveaway is already closed.');

      const giveawayCloser = require('../services/giveawayCloser');
      await giveawayCloser.closeGiveawayNow(interaction.client, giveaway.id);
      return interaction.editReply('✅ Giveaway closed and winners announced.');
    }

    if (sub === 'results') {
      const messageId = interaction.options.getString('message_id').trim();
      const giveaway = db.getGiveawayByMessageId(messageId);
      if (!giveaway) return interaction.reply({ content: '❌ No giveaway found with that message ID.', ephemeral: true });

      if (giveaway.status === 'open') {
        let entrantCount = 0;
        try {
          const tickets = await buildEntrantPool(interaction.guild, giveaway.entry_role_id, !!giveaway.booster_bonus_enabled);
          entrantCount = new Set(tickets).size;
        } catch {}
        const embed = new EmbedBuilder()
          .setColor(0xf2b705)
          .setTitle(`🎉 ${giveaway.title}`)
          .setDescription(`**Prize:** ${giveaway.prize}\n**Entrants:** ${entrantCount}\n**Winners:** ${giveaway.winner_count}\n**Ends:** <t:${giveaway.ends_at}:R>`)
          .setFooter({ text: 'Still open — winners are picked automatically when it closes' });
        return interaction.reply({ embeds: [embed], ephemeral: true });
      }

      const winners = db.getGiveawayWinners(giveaway.id);
      const embed = buildClosedGiveawayEmbed({ title: giveaway.title, prize: giveaway.prize, description: giveaway.description, winners, entrantCount: giveaway.entrant_count });
      return interaction.reply({ embeds: [embed], ephemeral: true });
    }

    if (sub === 'list') {
      const giveaways = db.listOpenGiveawaysForGuild(interaction.guildId);
      if (giveaways.length === 0) return interaction.reply({ content: 'No open giveaways right now.', ephemeral: true });
      const lines = giveaways.map(g => `• **${g.title}** (${g.prize}) in <#${g.channel_id}> — ends <t:${g.ends_at}:R> — \`${g.message_id}\``);
      const embed = new EmbedBuilder().setColor(0xf2b705).setTitle('Open giveaways').setDescription(lines.join('\n'));
      return interaction.reply({ embeds: [embed], ephemeral: true });
    }
  },
};
