# Issues with Tissues

A guild addon for the Issues with Tissues guild on WoW: Forever.

## Install

Copy the `IssuesWithTissues` folder into your game's `Interface\AddOns` folder, then restart the game or `/reload`.

## Use

| Command | What it does |
| --- | --- |
| `/iwt` (or `/tissues`) | open or close the window |
| `/iwt settings` | open the settings |
| `/iwt bug` | copyable bug report (`/iwt bug clear` empties it) |
| `/iwt perf on`, `off`, `reset` | the profiler; `/iwt perf` shows its report |
| `/iwt roster` | open the roster |
| `/iwt inactive 7\|14\|30` | members away that many days or more (alts counted once) |
| `/iwt alt add Name` · `/iwt alt remove Name` · `/iwt alt` | link an alt (then log on to it and say yes), unlink it, or list your links |
| `/iwt craft <name>` | who in the guild can make an item (the Crafters tab does the same) |
| `/iwt lfg note` · `/iwt lfg off` | post on the Groups board ("need a group", dungeon, 1 hour), or take it down |
| `/iwt layer` | your layer and the guildmates' layers the addon knows |
| `/iwt hop Name` | ask a guildmate for a layer-hop invite |
| `/iwt version` | the addon version |

The minimap button opens the window (right-click opens the settings), and there's a **Tissues** button on the guild window.

The window has four tabs along the bottom, each with sub-tabs at the top, and Settings behind the cog in the title bar (right-clicking the minimap button opens it too). Each tab reopens on the sub-tab you last used.

- **Home**: the guild at a glance (including the guild's total Enemy Kills and honorable kills, added up from everyone running the addon), this character and its main (with a "Set as my main" button), and your professions.
- **Members**: **Roster** (filters, alts grouped under their main) and **Crafters** (search who can make an item).
- **Play**: **Groups** (post what you're looking for; right-click a post to whisper, Shift-click to invite) and **Layers** (your layer from any NPC you target or mouse over, guildmates' layers, click one to ask for a hop invite). Your layer shows at the right of the sub-tabs.
- **Guild life**: **Calendar** (officers add events; everyone signs up as tank, healer, damage, maybe or can't come), **Polls** (officers ask; one vote per player, alts counted once; votes can be changed until the poll closes) and **Donations** (a goal officers set and can edit, starting with the guild bank; gold you put into the guild bank is noted automatically). Home's "What's on" box shows the next event, open polls and the donation goal; click one to jump there.

Professions: your skill levels are shared at login. Recipes are read whenever a profession window is shown. Press "Scan my recipes" on the Home tab, open your professions and click each profession tab on the right of that window; the Home tab ticks them off. The game does not let addons open the profession window themselves.

## How it works

- **Guild only.** Addons talk over hidden guild addon messages (prefix `IWT`), never a custom channel.
- **Officers** are the Guild Master and Officer ranks (rank index 0 and 1). Each client checks the sender's rank in its own copy of the guild roster, so a message can't claim a rank it doesn't have.
- **Shared data** (`Sync.lua`) has a revision for every record. At login the addon asks the guild for anything newer than what it holds, and one guildmate answers. A wiped saved-variables file rebuilds itself this way.
- Saved variables: `IwTDB` (account) and `IwTCharDB` (character).

## Development

Tests run offline against a small stand-in for the WoW API (`tests/wow.lua`), simulating several guildmates' clients:

```sh
luajit tests/run.lua
```

GitHub Actions runs them on every push and pull request.

## Roadmap

1. Foundation: window, settings, guild comms, sync, bug report, profiler
2. Roster: roster tab, inactive filters, alt links, professions, General tab
3. Groups: LFG board, crafters board, layer hop
4. Four-tab layout; Guild life: calendar, polls, donations (this release)
5. Loot notes, self-test, CurseForge release

## Names

Characters are known by first name and surname ("Sara Exe"), so guildmates who share a first name stay apart. The Forever client stamps addon messages with the sender's first name and surname, and that is who the addon believes sent a message. Should a client ever stamp only the first name, each message also carries its sender's full name, believed only when the first names match; then officer data needs every guildmate with that first name to be an officer. A client that sees a record written in its own name that it did not write sends its own version straight back (noted in `/iwt bug`).
