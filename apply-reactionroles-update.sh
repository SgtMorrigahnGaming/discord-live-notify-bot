#!/bin/bash
set -e
echo "Setting up reaction roles files..."
mkdir -p src/utils src/commands src/services
cat > src/utils/emoji.js << 'EOF_MARKER_src_utils_emoji_js'
/**
 * Parses a user-supplied emoji (from a Discord slash command string option, which preserves
 * emoji exactly as typed/picked) into { id, name }.
 * - Custom guild emoji look like <:name:123456789012345678> or <a:name:123...> (animated)
 * - Standard unicode emoji come through as the raw character itself
 * Returns null if the input can't be resolved (e.g. a plain :shortcode: with no ID attached).
 */
function parseEmojiInput(raw) {
  if (!raw) return null;
  const trimmed = raw.trim();

  const customMatch = trimmed.match(/^<a?:(\w+):(\d+)>$/);
  if (customMatch) {
    return { id: customMatch[2], name: customMatch[1] };
  }

  if (trimmed.startsWith(':') && trimmed.endsWith(':')) {
    return null; // bare shortcode with no ID — can't react with this reliably
  }

  return { id: null, name: trimmed };
}

/** Converts a parsed emoji into the string format discord.js's Message#react expects. */
function toReactString(emoji) {
  return emoji.id ? `${emoji.name}:${emoji.id}` : emoji.name;
}

/** Does a discord.js ReactionEmoji/Emoji object match a stored { emoji_id, emoji_name } row? */
function matchesStoredEmoji(row, reactionEmoji) {
  if (row.emoji_id) return row.emoji_id === reactionEmoji.id;
  return !reactionEmoji.id && row.emoji_name === reactionEmoji.name;
}

/** Human-readable display of a parsed emoji, for confirmation messages. */
function displayEmoji(emoji) {
  return emoji.id ? `<:${emoji.name}:${emoji.id}>` : emoji.name;
}

module.exports = { parseEmojiInput, toReactString, matchesStoredEmoji, displayEmoji };
EOF_MARKER_src_utils_emoji_js

cat > src/commands/reactionroles.js << 'EOF_MARKER_src_commands_reactionroles_js'
const { SlashCommandBuilder, PermissionFlagsBits, EmbedBuilder, ChannelType } = require('discord.js');
const db = require('../db');
const emojiUtil = require('../utils/emoji');

module.exports = {
  data: new SlashCommandBuilder()
    .setName('reactionroles')
    .setDescription('Set up self-serve roles via message reactions')
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageGuild)
    .addSubcommand(sub => sub
      .setName('create-panel')
      .setDescription('Post a new panel message that you can attach reaction roles to')
      .addChannelOption(opt => opt.setName('channel').setDescription('Channel to post the panel in').addChannelTypes(ChannelType.GuildText).setRequired(true))
      .addStringOption(opt => opt.setName('title').setDescription('Panel title').setRequired(true))
      .addStringOption(opt => opt.setName('description').setDescription('Panel description').setRequired(true)))
    .addSubcommand(sub => sub
      .setName('add')
      .setDescription('Attach an emoji-role pair to an existing panel message')
      .addStringOption(opt => opt.setName('message_id').setDescription('The panel message ID (right-click it -> Copy Message ID)').setRequired(true))
      .addChannelOption(opt => opt.setName('channel').setDescription('Channel the panel message is in').addChannelTypes(ChannelType.GuildText).setRequired(true))
      .addStringOption(opt => opt.setName('emoji').setDescription('Emoji to react with (pick from the emoji picker)').setRequired(true))
      .addRoleOption(opt => opt.setName('role').setDescription('Role to grant when someone reacts').setRequired(true))
      .addStringOption(opt => opt.setName('welcome_dm').setDescription('Optional DM to send when granted. Use {user} {server}').setRequired(false)))
    .addSubcommand(sub => sub
      .setName('remove')
      .setDescription('Remove an emoji-role pair from a panel')
      .addStringOption(opt => opt.setName('message_id').setDescription('The panel message ID').setRequired(true))
      .addChannelOption(opt => opt.setName('channel').setDescription('Channel the panel message is in').addChannelTypes(ChannelType.GuildText).setRequired(true))
      .addStringOption(opt => opt.setName('emoji').setDescription('Emoji to remove').setRequired(true)))
    .addSubcommand(sub => sub
      .setName('list')
      .setDescription('List emoji-role pairs on a panel')
      .addStringOption(opt => opt.setName('message_id').setDescription('The panel message ID').setRequired(true))),

  async execute(interaction) {
    const sub = interaction.options.getSubcommand();

    if (sub === 'create-panel') {
      const channel = interaction.options.getChannel('channel');
      const title = interaction.options.getString('title');
      const description = interaction.options.getString('description');

      const embed = new EmbedBuilder().setColor(0x5865f2).setTitle(title).setDescription(description);
      const message = await channel.send({ embeds: [embed] }).catch(() => null);
      if (!message) {
        return interaction.reply({ content: `❌ Couldn't post in ${channel} — check I have permission to send messages there.`, ephemeral: true });
      }

      return interaction.reply({
        content: `✅ Panel posted in ${channel}.\nMessage ID: \`${message.id}\`\n\nNow use \`/reactionroles add\` with that message ID to attach emoji-role pairs to it.`,
        ephemeral: true,
      });
    }

    if (sub === 'add') {
      await interaction.deferReply({ ephemeral: true });
      const messageId = interaction.options.getString('message_id').trim();
      const channel = interaction.options.getChannel('channel');
      const rawEmoji = interaction.options.getString('emoji');
      const role = interaction.options.getRole('role');
      const welcomeDm = interaction.options.getString('welcome_dm');

      const parsedEmoji = emojiUtil.parseEmojiInput(rawEmoji);
      if (!parsedEmoji) {
        return interaction.editReply(`❌ Couldn't understand \`${rawEmoji}\` as an emoji. Pick one from Discord's emoji picker rather than typing a shortcode.`);
      }

      if (role.managed || role.id === interaction.guild.id) {
        return interaction.editReply(`❌ Can't use that role — it's managed by an integration or is the default @everyone role.`);
      }
      if (interaction.guild.members.me.roles.highest.position <= role.position) {
        return interaction.editReply(`❌ I can't assign **${role.name}** — it's positioned above my own highest role. Move my role above it in Server Settings → Roles.`);
      }

      const message = await channel.messages.fetch(messageId).catch(() => null);
      if (!message) {
        return interaction.editReply(`❌ Couldn't find a message with ID \`${messageId}\` in ${channel}.`);
      }

      try {
        await message.react(emojiUtil.toReactString(parsedEmoji));
      } catch (err) {
        return interaction.editReply(`❌ Couldn't react with that emoji: ${err.message}. If it's a custom emoji, make sure it's from this server (or one I'm also in).`);
      }

      db.addReactionRole(interaction.guildId, channel.id, messageId, parsedEmoji.id, parsedEmoji.name, role.id, welcomeDm || null);

      return interaction.editReply(`✅ ${emojiUtil.displayEmoji(parsedEmoji)} on that panel now grants **${role.name}**.`);
    }

    if (sub === 'remove') {
      await interaction.deferReply({ ephemeral: true });
      const messageId = interaction.options.getString('message_id').trim();
      const channel = interaction.options.getChannel('channel');
      const rawEmoji = interaction.options.getString('emoji');

      const parsedEmoji = emojiUtil.parseEmojiInput(rawEmoji);
      if (!parsedEmoji) {
        return interaction.editReply(`❌ Couldn't understand \`${rawEmoji}\` as an emoji.`);
      }

      const changes = db.removeReactionRole(messageId, parsedEmoji.id, parsedEmoji.name);
      if (changes === 0) {
        return interaction.editReply(`⚠️ That emoji wasn't attached to that message.`);
      }

      const message = await channel.messages.fetch(messageId).catch(() => null);
      if (message) {
        const reaction = message.reactions.cache.find(r =>
          parsedEmoji.id ? r.emoji.id === parsedEmoji.id : r.emoji.name === parsedEmoji.name
        );
        if (reaction) await reaction.users.remove(interaction.client.user.id).catch(() => {});
      }

      return interaction.editReply(`🗑️ Removed ${emojiUtil.displayEmoji(parsedEmoji)} from that panel.`);
    }

    if (sub === 'list') {
      const messageId = interaction.options.getString('message_id').trim();
      const rows = db.listReactionRolesForMessage(messageId);
      if (rows.length === 0) {
        return interaction.reply({ content: 'No emoji-role pairs are attached to that message yet.', ephemeral: true });
      }
      const embed = new EmbedBuilder()
        .setColor(0x5865f2)
        .setTitle('Reaction roles on this panel')
        .setDescription(rows.map(r => {
          const emoji = emojiUtil.displayEmoji({ id: r.emoji_id, name: r.emoji_name });
          return `${emoji} → <@&${r.role_id}>${r.dm_message ? ' *(sends a DM)*' : ''}`;
        }).join('\n'));
      return interaction.reply({ embeds: [embed], ephemeral: true });
    }
  },
};
EOF_MARKER_src_commands_reactionroles_js

cat > src/services/reactionRoleHandler.js << 'EOF_MARKER_src_services_reactionRoleHandler_js'
const db = require('../db');
const emojiUtil = require('../utils/emoji');
const logger = require('../utils/logger');

function fillTemplate(template, vars) {
  if (!template) return null;
  let out = template;
  for (const [key, val] of Object.entries(vars)) {
    out = out.replaceAll(`{${key}}`, val ?? '');
  }
  return out;
}

async function resolveReactionContext(reaction, user) {
  if (user.bot) return null; // ignore the bot's own setup reaction, and any other bots

  if (reaction.partial) {
    try { await reaction.fetch(); } catch { return null; }
  }
  if (reaction.message.partial) {
    try { await reaction.message.fetch(); } catch { return null; }
  }

  const { message } = reaction;
  if (!message.guild) return null; // DMs have no guild

  const row = db.getReactionRole(message.id, reaction.emoji.id, reaction.emoji.name);
  if (!row) return null;

  const member = await message.guild.members.fetch(user.id).catch(() => null);
  if (!member) return null;

  return { row, member, guild: message.guild };
}

function register(client) {
  client.on('messageReactionAdd', async (reaction, user) => {
    try {
      const ctx = await resolveReactionContext(reaction, user);
      if (!ctx) return;
      const { row, member, guild } = ctx;

      if (member.roles.cache.has(row.role_id)) return; // already has it
      await member.roles.add(row.role_id).catch(err => {
        logger.warn(`Reaction role: couldn't add role ${row.role_id} to ${user.tag} in ${guild.name}: ${err.message}`);
        return null;
      });

      if (row.dm_message) {
        const content = fillTemplate(row.dm_message, { user: member.displayName, server: guild.name });
        await member.send(content).catch(() => {
          logger.warn(`Reaction role: couldn't DM ${user.tag} (DMs likely disabled) — role was still granted.`);
        });
      }
    } catch (err) {
      logger.error('messageReactionAdd handler error:', err);
    }
  });

  client.on('messageReactionRemove', async (reaction, user) => {
    try {
      const ctx = await resolveReactionContext(reaction, user);
      if (!ctx) return;
      const { row, member, guild } = ctx;

      if (!member.roles.cache.has(row.role_id)) return; // doesn't have it anyway
      await member.roles.remove(row.role_id).catch(err => {
        logger.warn(`Reaction role: couldn't remove role ${row.role_id} from ${user.tag} in ${guild.name}: ${err.message}`);
      });
    } catch (err) {
      logger.error('messageReactionRemove handler error:', err);
    }
  });

  logger.info('Reaction role handler registered');
}

module.exports = { register };
EOF_MARKER_src_services_reactionRoleHandler_js

echo "Reaction role files written."
