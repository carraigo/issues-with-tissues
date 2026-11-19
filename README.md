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
| `/iwt craft <name>` | who in the guild can make an item |
| `/iwt version` | the addon version |

The minimap button opens the window (right-click opens the settings), and there's a **Tissues** button on the guild window.

The window opens on the General tab: a short overview of the guild, this character and its main (with a "Set as my main" button), and your professions.

Professions: your skill levels are shared at login. Recipes are read whenever a profession window is shown. Press "Scan my recipes" on the General tab, open your professions and click each profession tab on the right of that window; the General tab ticks them off. The game does not let addons open the profession window themselves.

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
2. Roster: roster tab, inactive filters, alt links, professions (this release)
3. Groups: LFG board, crafters board, layer hop
4. Guild life: calendar, polls, donations
5. Loot notes, self-test, CurseForge release

## Names

Characters are known by first name and surname ("Sara Exe"), so guildmates who share a first name stay apart. The Forever client stamps addon messages with the sender's first name and surname, and that is who the addon believes sent a message. Should a client ever stamp only the first name, each message also carries its sender's full name, believed only when the first names match; then officer data needs every guildmate with that first name to be an officer. A client that sees a record written in its own name that it did not write sends its own version straight back (noted in `/iwt bug`).
