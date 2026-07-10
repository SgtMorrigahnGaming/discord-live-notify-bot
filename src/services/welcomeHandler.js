const { AttachmentBuilder } = require('discord.js');
const db = require('../db');
const { generateWelcomeCard } = require('../utils/welcomeCard');
const logger = require('../utils/logger');

function fillTemplate(template, vars) {
  if (!template) return null;
  let out = template;
  for (const [key, val] of Object.entries(vars)) {
    out = out.replaceAll(`{${key}}`, val ?? '');
  }
  return out;
}

function register(client) {
  client.on('guildMemberAdd', async (member) => {
    try {
      const config = db.getWelcomeConfig(member.guild.id);
      if (!config || !config.enabled) return;

      const channel = await member.guild.channels.fetch(config.channel_id).catch(() => null);
      if (!channel) {
        logger.warn(`Welcome: configured channel ${config.channel_id} not found in guild ${member.guild.name}`);
      } else {
        try {
          const buffer = await generateWelcomeCard({
            avatarUrl: member.displayAvatarURL({ extension: 'png', size: 256 }),
            username: member.user.username,
            guildName: member.guild.name,
            memberCount: member.guild.memberCount,
          });
          const attachment = new AttachmentBuilder(buffer, { name: 'welcome.png' });
          await channel.send({ content: `Welcome ${member}! 🎉`, files: [attachment] });
        } catch (err) {
          logger.error(`Welcome: failed to post card in ${member.guild.name}:`, err);
        }
      }

      if (config.dm_message) {
        const content = fillTemplate(config.dm_message, { user: member.displayName, server: member.guild.name });
        await member.send(content).catch(() => {
          logger.warn(`Welcome: couldn't DM ${member.user.tag} (DMs likely disabled).`);
        });
      }
    } catch (err) {
      logger.error('guildMemberAdd handler error:', err);
    }
  });

  logger.info('Welcome handler registered');
}

module.exports = { register };
