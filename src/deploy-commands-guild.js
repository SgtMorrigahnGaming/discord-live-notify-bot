const fs = require('fs');
const path = require('path');
const { REST, Routes } = require('discord.js');
const config = require('./config');

const guildId = process.env.GUILD_ID;
if (!guildId) {
  console.error('Set GUILD_ID in your .env to use this script (registers commands instantly to one server for testing).');
  process.exit(1);
}

const commands = [];
const commandsPath = path.join(__dirname, 'commands');
for (const file of fs.readdirSync(commandsPath).filter(f => f.endsWith('.js'))) {
  const command = require(path.join(commandsPath, file));
  commands.push(command.data.toJSON());
}

const rest = new REST().setToken(config.discord.token);

(async () => {
  try {
    console.log(`Registering ${commands.length} command(s) to guild ${guildId}...`);
    await rest.put(Routes.applicationGuildCommands(config.discord.clientId, guildId), { body: commands });
    console.log('Done — commands should be available immediately in that server.');
  } catch (err) {
    console.error('Failed to register guild commands:', err);
    process.exit(1);
  }
})();
