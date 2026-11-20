# Changelog

## 0.6.2

- Faster: when a lot of shared data arrives at once (logging in, a guildmate's catch-up), open pages redraw once afterwards instead of once per record. In a 500-member test guild this cut a 2-3 second freeze to a few milliseconds.
- Roster scrolling no longer rebuilds the whole list on every wheel step.

## 0.6.1

- Fixed: macros that target or mark (for example RestedXP's target button, or /tm) were blocked with "IssuesWithTissues has been blocked from an action". The addon tainted the game's slash command list when registering /iwt.

## 0.6.0

- Roster: the Rank and Zone / last on columns make way for Honourable kills, so guildmates can compare. Rank and last online are still in the tooltip, and the away filters still work.
- Home: Elite Soldier, the guildmate with the most honourable kills.
- The Play tab is now Hop, with layer hopping only. The Groups board is gone.
- Guild life: the Calendar is gone (events live on Discord), and so is Next event on Home.
- Loot notes: the Guildmate box suggests names as you type (first name, surname or part of either), like the mailbox. Click one, or use the arrow keys and Tab or Enter.
- Donations: only the officer who set the goal can change it. Another officer's change asks the owner first, and if they allow it the goal becomes theirs.

## 0.5.1

- Fixed: guildmates who installed the addon later could miss older shared data (for example someone's professions) when a newer change reached them first. Catch-up now compares everything each guildmate holds, and each guildmate with different data answers.
- Fixed: an error on mouseover/target in combat (the game hides some unit IDs from addons there); the layer check now skips them.

## 0.5.0

- Guild life > Loot notes: officers note who received which item (shift-click the item in), with a note. Everyone can read and search them. Notes only: no points or priorities.
- `/iwt selftest` (and a Self-test button in Settings): checks the addon works on this client and shows a copyable list.
- Crafters: with no search, professions are a list you open and close, with their crafters underneath.
- Release packaging: a tagged push builds the addon zip and attaches it to a GitHub release.

## 0.4.0

- Four tabs: Home, Members (Roster, Crafters), Play (Groups, Layers), Guild life. Settings moved behind the cog.
- New flat, dark look with gold edges.
- Guild kill totals on Home (Enemy Kills and honorable kills, from everyone running the addon).
- Guild life: Calendar (events and sign-ups), Polls (one vote per player), Donations (officer-set goal, guild bank deposits noted automatically).
- Home: "What's on" box.

## 0.3.0

- Groups board (LFG), Crafters board, layers and layer-hop requests.

## 0.2.0

- Roster tab with filters, alt links, professions and recipe sharing, General (now Home) tab.

## 0.1.0

- Window, settings, guild comms, shared data sync, bug report and profiler.
