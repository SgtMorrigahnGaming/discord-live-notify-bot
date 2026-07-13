const fs = require('fs');
const path = require('path');
const { Client, GatewayIntentBits, Partials, Collection } = require('discord.js');
const config = require('./config');
const logger = require('./utils/logger');
const twitchPoller = require('./services/twitchPoller');
const youtubePoller = require('./services/youtubePoller');
const freeGamesPoller = require('./services/freeGamesPoller');
const webServer = require('./web/server');
const reactionRoleHandler = require('./services/reactionRoleHandler');
const welcomeHandler = require('./services/welcomeHandler');
const guildCleanupHandler = require('./services/guildCleanupHandler');
const pollCloser = require('./services/pollCloser');
const pollInteractions = require('./services/pollInteractions');
const client = new Client({
  intents: [
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessageReactions,
    GatewayIntentBits.GuildMembers,
  ],
  partials: [Partials.Message, Partials.Channel, Partials.Reaction, Partials.User, Partials.GuildMember],
});

client.commands = new Collection();

const commandsPath = path.join(__dirname, 'commands');
for (const file of fs.readdirSync(commandsPath).filter(f => f.endsWith('.js'))) {
  const command = require(path.join(commandsPath, file));
  client.commands.set(command.data.name, command);
}

client.once('clientReady', () => {
  logger.info(`Logged in as ${client.user.tag}`);
  logger.info(`Serving ${client.guilds.cache.size} guild(s)`);
  twitchPoller.start(client);
  youtubePoller.start(client);
  freeGamesPoller.start(client);
  webServer.start(client);
  reactionRoleHandler.register(client);
  welcomeHandler.register(client);
  guildCleanupHandler.register(client);
  pollCloser.start(client);
});

client.on('interactionCreate', async (interaction) => {
  try {
    if (interaction.isChatInputCommand()) {
      const command = client.commands.get(interaction.commandName);
      if (!command) return;
      await command.execute(interaction);
      return;
    }

    if (interaction.isButton() && interaction.customId.startsWith('poll_')) {
      await pollInteractions.handleButton(interaction);
      return;
    }

    if (interaction.isModalSubmit() && interaction.customId.startsWith('poll_')) {
      await pollInteractions.handleModal(interaction);
      return;
    }
  } catch (err) {
    logger.error('Error handling interaction:', err);
    const payload = { content: '❌ Something went wrong running that command.', ephemeral: true };
    if (interaction.deferred || interaction.replied) {
      await interaction.editReply(payload).catch(() => {});
    } else {
      await interaction.reply(payload).catch(() => {});
    }
  }
});

process.on('unhandledRejection', (err) => logger.error('Unhandled rejection:', err));

client.login(config.discord.token);
