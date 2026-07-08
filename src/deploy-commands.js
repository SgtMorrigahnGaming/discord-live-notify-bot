const fs = require('fs');
const path = require('path');
const { REST, Routes } = require('discord.js');
const config = require('./config');

const commands = [];
const commandsPath = path.join(__dirname, 'commands');
for (const file of fs.readdirSync(commandsPath).filter(f => f.endsWith('.js'))) {
  const command = require(path.join(commandsPath, file));
  commands.push(command.data.toJSON());
}

const rest = new REST().setToken(config.discord.token);

(async () => {
  try {
    console.log(`Registering ${commands.length} global slash command(s)...`);
    await rest.put(Routes.applicationCommands(config.discord.clientId), { body: commands });
    console.log('Done. Note: global commands can take up to an hour to propagate to all servers.');
    console.log('For instant testing in one server, set GUILD_ID in .env and use deploy-commands-guild.js instead (see README).');
  } catch (err) {
    console.error('Failed to register commands:', err);
    process.exit(1);
  }
})();
