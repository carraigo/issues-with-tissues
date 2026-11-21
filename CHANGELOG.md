# Changelog

## 0.8.1

- **Welcome card:** a new install opens with a short tour of the tabs, the key binding and the minimap button. `/iwt welcome` shows it again.
- **What's new:** the first time a new version loads, a card lists its highlights (and the previous version's, if you skipped one). `/iwt new` shows it again.
- **Newer version notice:** when a guildmate has a newer release than yours, you're told once in chat. `/iwt update` gives the download link to copy. Test versions (betas) only count if you're on one too.
- **Game Options page:** Issues with Tissues now has its own page in the game's Options, under AddOns, with buttons for the addon's settings, the window and What's new.

## 0.8.0

Guild chat comes to the window, so the addon can stand in for the game's guild window. Plus themes.

- **Chat tab:** guild chat and officer chat (officers only) in the window, with class-coloured names, clickable item and player links, the message of the day, and guildmates coming online and going offline. Type in the box and press Enter to send. Up and Down bring back what you sent, and shift-clicking an item links it. `/iwt chat` opens it.
- **Chat history:** opening the Chat tab loads the recent guild and officer chat the game's server keeps for its own guild window, so you see what was said before you logged in, even on a new install or another PC. The addon also keeps the last 300 lines of each channel on your PC, merged with the server's without duplicates. Saved chat is never shared with guildmates or put in the diagnostics report or the guild web page, and Settings can turn saving off.
- **Who's online:** a list beside the chat shows the guildmates online right now, grouped by rank with the Guild Master first. Click a name to whisper, right-click to invite, and hover for level, class and zone.
- **Themes:** pick the window's colours in Settings: Default, Kawaii Night, Kawaii Day, Midnight or High contrast, applied after a reload. Every theme but Default keeps text readable by shading class colours and other text that would be too faint on its panels. The Kawaii themes use their own chat colours.
- **Key bindings:** "Open or close the window" and "Open guild chat" are in the game's Key Bindings, under Issues with Tissues. Bind one to your guild key (J) to use the addon instead of the game's guild window.
- A button next to the cog opens the game's own guild window, for invites, promotions and notes.

Details for the curious: the game often hands chat over as hidden text that only turns into words on screen, so the addon matches a live line with the server's copy by author and time, and shows the server's fresh copy for saved lines from an earlier session. The message of the day is kept once until it changes, and authors the server hasn't looked up yet show as "[Unknown]".

## 0.7.2

- The minimap button now sits on the rim of a bigger or square minimap (from other addons or UI packs), not inside the map.

## 0.7.1

- Professions now reach the guild after a first login. Skills were only shared 12 seconds after logging in, and if the guild roster hadn't loaded by then, sharing was refused and never tried again. They are now shared again whenever the roster loads.
- Guildmates already online now show as addon users. The version check was only sent when someone logged in, so you never heard from people who were online before you. Whoever hears a new guildmate now whispers their version back once.

## 0.7.0

- Diagnostics report: `/iwt report` (or Settings, Diagnostics report) packs version, client, errors, profiler numbers, the last self-test, shared-data counts, settings and usage counts (pages opened, commands used) into one string to copy. Paste it at carraigo.github.io/iwt-stats/#report to check it and send it as a GitHub issue. No chat, log lines or other players' names; your character's name only with `/iwt report name`.
- Errors now remember the addon version they last happened on, so reports can tell old, already-fixed errors from new ones.

## 0.6.3

- Logging out or /reload now saves a copy of the roster (name, level, class, rank, days away; no notes) with the addon's data, for the guild web page export.

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
