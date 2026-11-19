# Issues with Tissues

A guild addon for the Issues with Tissues guild on WoW: Forever. It puts the guild's roster, crafters, groups, events and polls in one window, and shares everything between guildmates who run it.

## Install

Copy the `IssuesWithTissues` folder into your game's `Interface\AddOns` folder, then restart the game.

Open it with `/iwt`, the minimap button, or the **Tissues** button on the guild window.

## Features

- **Home**: the guild at a glance (members online, players with alts counted once, guild kill totals), your character and its main, your professions, and a "What's on" box with the next event, open polls and the donation goal.
- **Members**
  - **Roster**: the whole guild with filters (online, away 7, 14 or 30 days) and alts grouped under their main.
  - **Crafters**: search who can make an item, or browse by profession.
- **Play**
  - **Groups**: post what you're looking for (dungeon, raid, quest, PvP) and see who else is looking.
  - **Layers**: see which layer you and guildmates are on, and ask a guildmate for a layer-hop invite.
- **Guild life**
  - **Calendar**: guild events with sign-ups (tank, healer, damage, maybe, can't come).
  - **Polls**: officers ask, everyone votes once.
  - **Donations**: a guild goal with progress. Gold put into the guild bank is noted automatically.
  - **Loot notes**: a shared record of who received which item.
- **Settings** (the cog): alerts, sounds, minimap button, bug report, profiler and self-test.

Officers (Guild Master and Officer ranks) can add events, polls, donation goals and loot notes. Everyone else can read them and take part.

The addon only talks to guildmates, over hidden guild addon messages.

## Commands

| Command | What it does |
| --- | --- |
| `/iwt` | open or close the window |
| `/iwt settings` | open the settings |
| `/iwt roster` | open the roster |
| `/iwt inactive 7\|14\|30` | members away that many days or more |
| `/iwt alt add Name` · `/iwt alt remove Name` · `/iwt alt` | link an alt, unlink it, or list your links |
| `/iwt craft <name>` | who in the guild can make an item |
| `/iwt lfg note` · `/iwt lfg off` | post on the Groups board, or take your post down |
| `/iwt layer` | your layer and guildmates' layers |
| `/iwt hop Name` | ask a guildmate for a layer-hop invite |
| `/iwt bug` | copyable bug report |
| `/iwt selftest` | check the addon works on your client |
| `/iwt version` | the addon version |

## Changes

See [CHANGELOG.md](CHANGELOG.md) for what's new in each version.
