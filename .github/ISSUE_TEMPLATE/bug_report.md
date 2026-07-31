---
name: Bug report
about: Something isn't working the way it should
title: "[Bug] "
labels: bug
assignees: ''
---

**Before filing — quick checklist**

A lot of "it doesn't work" reports for self-hosted bots come down to setup, not code. Please double check:

- [ ] `Server Members Intent` and `Message Content Intent` are both enabled in the [Discord Developer Portal](https://discord.com/developers/applications) (Bot → Privileged Gateway Intents) — not just in `.env`
- [ ] The bot's role sits **above** any role it needs to assign, in Server Settings → Roles
- [ ] The bot has the required permissions in the channel it's acting in (View Channel, Send Messages, etc. — see the README's invite permission list)
- [ ] You've checked the console/container logs for an actual error message
- [ ] You're running the latest `main` (`git pull`) before reporting

If you've been through that and it's still broken, please fill in below.

---

**Describe the bug**
A clear, concise description of what's wrong.

**Steps to reproduce**
1.
2.
3.

**Expected behavior**
What you expected to happen instead.

**Logs / error output**
Paste any relevant console or container logs here (use a code block — please redact your bot token if it appears).

```
paste here
```

**Environment**
- Node.js version:
- Running via: [ Docker / `npm start` ]
- Self-hosted instance, or the public one at `bot.morrigahngaming.no`?
- OS (if self-hosting):

**Additional context**
Anything else that might help — screenshots, dashboard config, when it started happening, etc.
