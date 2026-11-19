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
| `/iwt version` | the addon version |

The minimap button opens the window (right-click opens the settings), and there's a **Tissues** button on the guild window.

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

1. Foundation: window, settings, guild comms, sync, bug report, profiler (this release)
2. Roster: roster tab, inactive filters, alt links, professions
3. Groups: LFG board, crafters board, layer hop
4. Guild life: calendar, polls, donations
5. Loot notes, self-test, CurseForge release
