# Changelog

## 1.4.3

**Fixes**
- **"Version X is out" too early:** guildmates were told to update as soon as one person ran a newer build, even one not released yet. A version now counts as out once two different players run it (a player's alts count once). The message and `/iwt update` now point to CurseForge instead of GitHub.
- **"Arrived in your name" after a /reload:** messages sent just before a /reload can come back just after it, when the addon no longer remembers sending them. For the first 20 seconds these aren't reported as someone posing as you.

**Performance**
- **Fewer refused messages:** the game still refused up to 18 messages in a session, even at a gentle pace. It limits how many messages go out, not just how big they are: about 10 at once, then roughly one a second. The addon now keeps to that, so big catch-ups take a little longer but nothing gets refused.

## 1.4.2

**Fixes**
- **Message of the day blocked:** opening Chat could make the game block the addon reading the message of the day ("ADDON_ACTION_BLOCKED: UNKNOWN()"), most likely in combat. It's now read out of combat only and remembered, and the game's MOTD event keeps the copy fresh.
- **Characters outside the guild:** they no longer try to share kills or catch up with a guild they aren't in, which logged "may not write kills" at every login.

**Performance**
- **A sending pace that fits:** the game refused 5 to 13 messages in some sessions, all while answering big catch-ups. The addon now starts a little gentler (2,000 bytes a second), and a refusal sets the pace this PC keeps to a fifth under the one refused. It's remembered and tried a tenth higher at the next login.
- **Less saved chat:** with online/offline lines hidden in Settings, they're no longer saved either (they were 11 to 14 KB).

**Refactoring**
- **How catch-up ended:** session stats record how the first catch-up of a session finished (caught up, nobody answered, or out of rounds) and when, so sessions without a "caught up" time say why.
- **Home only reads:** the week's leader is remembered when kills records change (`Kills.TrackWeek`), not while Home draws.
- **Old saved settings tidied:** leftovers of removed features (`chatcheck`, `lfgAlerts`) are cleared at load.

**UX**
- **Guild news filters:** "Kills" and "Wish" are now "Top issuer" and "Wishes".

## 1.4.1

**Fixes**
- **Promote, Demote and Remove work again:** the game blocked them ("the game blocked Promote()"), even typed into chat, because the addon had opened the chat box. They're now secure buttons on the roster's right-click menu, which the game treats like your own macro. Click once and the button asks you to click again; the second click does it. In combat the menu tells you the command to type instead.
- **Guild news filters:** the seven filter buttons ran under the search box. They're narrower now, and a test checks every list page for this.
- **Settings labels:** the long "online and offline" label ran off the window. It's shorter, and every setting's label now stays inside its column (a long one ends in "...").

## 1.4.0

**Features**
- **Quest buddies (new Quests tab):** your elite, dungeon and raid quests that guildmates are also on, with who (online first, then in your zone, then nearest your level). Click to whisper, right-click to invite everyone online. "By place" lists the dungeons and zones where online guildmates have group quests. Quests guildmates share get a green "2 guild" beside them in the quest log, and the guildmates are listed in the quest's tooltip and on quest links. Only group quests are shared, by id (names never travel), in the character sheet. Setting: "Share my group quests".
- **Wishlists (Crafting > Wishlists):** alt-click any item (bags, chat links, loot) to wish for it, and again to take it off, or shift-click it into the page's box, or use `/iwt wish`. The page lists every wish in the guild with who wants it and who can make it; item tooltips say "Wanted by 2 guildmates: ...". When a wished item reaches your bags it comes off the list by itself, and the guild news says so ("Mem got Lionheart Helm!"). Up to 30 items each, shared in the character sheet. Settings: "Alt-click an item to wish for it", "Guildmates' wishlists on item tooltips".
- **Tissue Issuer of the Week:** a weekly race for the most honorable kills, from one weekly reset to the next. Home shows this week's leader under Elite Soldier, and when the week ends the guild news says who won ("Bo Finch won the week with 212 kills"). Counted by the game where it can, else from your total at your first login of the week.
- **Guild news page (Home > Guild news):** the last month of joins, leavers, level 60s, promotions, weekly winners and wishes that came true, with filters and a name search. Home shows the three newest in short ("Bo Finch hit 60"); click them for the page.

**Performance**
- **Smaller saved chat:** the game's server already keeps recent guild and officer chat, so messages are no longer saved between sessions when it has them. Only the last 100 online/offline and message of the day lines are kept. Saved chat was the biggest thing in the saved data. When the server gives no history for a channel, everything is saved as before.

**UX**
- **Home fits the window:** Home's cards stack themselves one under another, and the page scrolls if they ever run longer than the window.

**Refactoring**
- **`UI.Stack` and `UI.ScrollPage`:** a column of cards that places each row under the last, and a page that scrolls with the mouse wheel. Home is built with them, so a taller card no longer needs every card below it moved by hand.
- **Character sheet:** three more fields (group quests, wishlist, and wishes that came true in the last week), left off when empty. 1.3 clients read the sheet as before.
- **Kills data version 2:** the kills record gains the week and this week's kills (`hk;mobs;s;week;gain`). 1.3 clients keep the last version 1 copy they had; 1.4 upgrades version 1 records as they arrive.

## 1.3.4

**Performance**
- **Cheaper roster reads:** the roster was the busiest code in the session stats (about 0.6 ms a read, 70 to 80 reads a session). It's now updated in place, with changes spotted while reading, instead of building a fresh copy of every member and comparing the two. Names are parsed once and remembered. About ten times faster in the 500-member speed test.
- **Search waits for a pause:** search boxes (Crafting, Members, Raid, Loot notes and the other lists) filter 0.15 seconds after you stop typing, instead of on every letter. Enter still acts on everything typed at once.
- **Fewer Chat redraws:** the Chat page used to redraw every line every 30 seconds to move "5 min ago" on. It now redraws only when a label shown would actually read differently, and never while the chat is quiet for over an hour (until midnight, when today's times gain their day).

**Features**
- **Hide online/offline lines:** a new setting, "Show \"has come online\" and \"gone offline\" in chat", leaves those lines out of the Chat page. They're still kept, so turning it back on shows them again.

**Functionality**
- **Quiet when away:** a guildmate who is AFK waits 8 seconds longer before answering a catch-up, so someone at the keyboard answers first. They still answer within the round if nobody else does.

**Refactoring**
- **One check for game text:** `ns.Readable(v)` returns text the addon may read, or nil for a secret value or anything that isn't text. Names, system lines and "joined the guild" messages go through it.
- **Repeating jobs in `ns.TIMERS`:** the Chat label check and the Comm sweep run through `ns.Every(name, fn)`, next to every other timer.
- **Professions split:** reading the profession window and the recipe scan moved to `ProfessionScan.lua`; `Professions.lua` keeps the recipe data. New file: restart the game rather than /reload after updating.

## 1.3.3

**Fixes**
- **Chat errors after a reload:** the game sometimes hands addons a guild chat line's text or author as a "secret" value, which can be shown but not read and isn't saved. After a reload those saved lines came back empty and every redraw of the Chat page errored ("attempt to concatenate field 'm'"). Empty lines are now dropped at load, and a line that can't be drawn is skipped instead of breaking the page.
- **Secret text everywhere it's read:** chat lines, names, online/offline and "joined the guild" messages and the message of the day are checked first (`ns.IsSecret`). A secret line is shown as the game gave it for this session, and is never matched, searched or looked up in the roster (which is what errored in 1.3.1: "attempt to index a secret string value").

## 1.3.2

**Performance**
- **Gentler sending:** messages are paced by size, and when the game refuses one for going too fast, the addon halves its pace and then speeds back up a quarter every 10 seconds without a refusal. Before, it kept sending at full speed and resent each refused piece 1.5 seconds later (up to 43 refusals in one session while answering catch-ups).
- **Answering is shared out:** a guildmate who answered a catch-up in the last 5 minutes waits 5 seconds longer before answering the next, so someone who hasn't answered lately goes first.
- **Fewer roster scans:** the game can send several roster updates a second; the addon now reads the roster at most once a second.

**Functionality**
- **No answer means up to date:** guildmates only answer a catch-up when they hold something you lack. If nobody answers while their addons are online, the catch-up now ends there (counted as caught up). If no guildmate's addon has said hello yet, it asks again a minute later (twice) instead of waiting for the 10-minute catch-up.
- Session stats know the character is in the guild from the roster; the game already says "not in a guild" while logging out, so 1.3.1 marked every session as outside it.

**Refactoring**
- **Timing tests:** the test harness has a clock (`W.Run`) that runs timers in order with messages going through the paced queue, so catch-up rounds, the send pace, answer sharing and roster scans are tested as they really run.

## 1.3.1

**Performance**
- **Catching up ends sooner:** after each round the addon checks whether its data now matches what the guildmates who answered hold, and stops there instead of asking again. A round is also judged a few seconds after its last record arrives instead of always waiting 20 seconds. A catch-up that took 2 minutes and 3 rounds should now usually finish in one round of about 15 seconds.
- **Smaller catch-up answers:** sets of 8 to 31 records are now split into 8 buckets, like big sets are into 16, so one changed record brings that bucket (a few records) instead of the whole set. Older versions still answer with the whole set.
- **Fewer roster redraws:** the game sends roster updates every few seconds, usually with nothing new. Pages now hear about them only when someone joins, leaves, comes online or changes rank, level or last seen; zone and note changes only redraw the Roster page.

**Functionality**
- Session stats say whether the character is in the guild, so the site's performance page can leave out sessions on characters outside it.

**Refactoring**
- **Sync split in two:** Sync.lua keeps the records (storing, accepting, live changes, data versions); SyncCatchUp.lua holds catching up (fingerprints, buckets, asks, answers, rounds).
- **List.lua:** the list page builder moved out of Widgets.lua into its own file.

## 1.3.0

**Performance**
- **Much smaller recipe data:** recipes are shared as item ids (spell ids for enchants) written as base 36 gaps, and each PC looks up and remembers the names, asking the game for them in batches of 100. A profession's record is about 6 times smaller than in 1.2. Records from 1.2 are upgraded as they arrive; 1.2 clients can't read the new ones, so everyone should update.
- **One character sheet:** attunements, keys and saved raids travel in one small record per character, read at login and after a quest hand-in, a bag change or a boss kill, and sent only when something in it changed.
- **New installs catch up privately:** when a new install asks for everything, the answer is whispered to them, so the rest of the guild doesn't unpack data it already has.
- **Faster send queue:** outgoing messages wait in a ring instead of a list that was shifted for every packet, so a big catch-up costs the sender less.
- **Quiet in dungeons too:** in a dungeon the addon sends slowly (one packet a second) and doesn't ask for or answer catch-ups, as in raids.
- **Old data cleaned up:** each character deletes its old Cooking recipes and your votes on polls that are no longer listed at login, and kill and vote records of characters who left the guild are dropped after 3 days, like professions.

**Functionality**
- **Raid page** (Members, officers and the Guild Master only for now): who is attuned to Molten Core, Onyxia, Blackwing Lair and Naxxramas, who holds the dungeon keys (UBRS seal, Scholomance, Stratholme, Dire Maul, Blackrock Depths) and the Aqual Quintessence, and who is saved to which raid with bosses killed and when it resets. Filters for online, level 60 and not saved; hover a name for details. `/iwt raid` prints your own.
- **Officers page** (Members, officers and the Guild Master only): everyone away 30 days or more with rank, level, last seen and alts (right-click to demote or remove), and which addon version each guildmate runs, older versions first (click to whisper them).
- **Remove from guild** on the roster's right-click menu for officers. As with promote and demote, it types the game's `/gremove` command into chat for you to confirm with Enter.
- **Cooking dropped from Crafting:** nearly everyone has it, so it swamped the list. It is no longer read, shared or shown.
- **Kawaii Day class colours:** hand-picked for the light background, each readable and different from the others (Priest is slate instead of mauve).
- Voting on a new poll no longer drops your vote on a poll that closed in the last week, whose result is still shown.
- **Session stats for the guild site:** at logout (and /reload) the addon saves a small record of how the session went: memory, start-up time, how long catching up took, messages sent and heard, refused and dropped packets, errors, and records and saved size per set. Numbers only, with no names or chat.

**Features**
- **Solarized Dark and Solarized Light themes**, based on Ethan Schoonover's Solarized palette.
- **Theme drop-down** in Settings instead of a row of buttons.
- **Lists remember your view:** Roster, Raid and Officers have sortable columns and remember your sort and filter.

**User experience**
- **First-run tour:** the welcome card's "Take the tour" shows Home, Chat and Crafting with a short tip on each (also `/iwt tour`).
- **"5 min ago" times:** chat lines from the last hour say how long ago they were written, and older ones show the day when it wasn't today. Hover a time for the full date. Settings can turn it off. Loot note and Officers tooltips say how long ago too.

**Refactoring**
- **One place for timers:** every login delay and repeating wait is in `ns.TIMERS` (Core.lua), spread out so nothing runs in the same frame.
- **One record format helper (Record.lua):** every shared set (kills, professions, recipes, sheets, alts, polls, votes, loot notes, donations) reads and writes its data through one set of helpers, and a test round-trips each set's sample, so a new set without a format fails the build.
- **Declared settings:** every setting is declared once in Core.lua (default, label, kind), and the Settings page builds itself from that list. Values are checked as they're saved.
- **Shared list builder:** every list page (Roster, Raid, Officers, Crafting, Loot notes, Polls, Donations) is built by one helper with sortable columns, filter buttons, search and a count line.
- **Chat.lua split** into Chat.lua (lines, sending, events), ChatHistory.lua (the server's history), ChatOnline.lua (who's online) and ChatBox.lua (the page).

## 1.2.3

- New versions reach CurseForge on their own: each GitHub release now uploads its zip to CurseForge straight away. Nothing changes in game.

## 1.2.2

- **Faster first sync:** a new install keeps asking the guild every minute until someone answers, and asks straight away when a guildmate with the addon logs in. Before, it asked twice: at login and 10 minutes later.
- **Catch-up in rounds:** after the first answer the addon asks again while answers still bring something new, so anything one guildmate was missing comes from another a few seconds later.
- **Smaller catch-ups:** big data sets (recipes, loot notes) are fingerprinted in 16 parts, and guildmates send only the parts that differ instead of everything. A new install's empty sets get one answer instead of one from everyone online.
- **Nothing lost when the game says "too fast":** messages the game refuses for sending too quickly are sent again a moment later, in order. Before, a refused piece broke the whole message.
- **Sync now:** a button in Settings (and `/iwt sync`) asks the guild for anything you're missing. Home shows "Syncing with the guild: 340 of 1,200" while it runs.
- Guildmates in combat or a raid don't answer catch-ups, so someone who's free does. `/iwt bug` shows the sync state and how many messages the game refused.

## 1.2.1

- **Kawaii Day chat is readable:** on light themes the chat text drops the game's thick black outline, and guild and officer chat use darker greens.
- **Guild key:** the welcome card (and this update's What's new) offers to make your guild key (J unless you changed it) open Issues with Tissues instead of the game's Guild & Communities. It only changes on your click, and Key Bindings can change it back.

## 1.2.0

- **"Guild craftable" on item tooltips:** a green line when someone in the guild has shared the recipe for the item, or already knows the recipe a Pattern, Plans, Formula or Schematic teaches. Nothing is shown otherwise. Settings can turn it off.
- **Promote and demote fixed:** WoW: Forever doesn't let addons change ranks directly, so the roster's Promote and Demote now type the game's own command into the chat box (for example `/gpromote Sara Exe`). Press Enter to do it, or Escape to change your mind.
- **Guild news on Home:** who joined, left, reached level 60 or was promoted this week, in a third column of What's on (hover for the whole week). It's worked out from roster changes on your own PC, including while you were offline, so nothing extra is shared.
- **New member nudge:** officers get a line in chat when someone joins the guild, to say hi (with a sound when alert sounds are on).
- **Notes on the roster:** hovering over someone shows their public note, and officers also see the officer note.
- **Unread chat:** the Chat tab and the minimap button count guildmates' messages you haven't seen. Online and offline lines and your own messages don't count.
- **Open on Home or Chat:** Settings chooses which tab the window opens on (minimap button, key binding, `/iwt`): the last one used (as before), Home or Chat.
- **Minimap tooltip:** members online, open polls and the donation goal at a glance.
- **Empty lists explain themselves:** Crafters and Loot notes say why they're empty and what to do, instead of showing nothing.
- **Quieter in fights:** the addon's messages wait while you're in combat and go out slowly in a raid. Catching up with guildmates' data waits until you're out of the raid.
- For developers: shared records carry a data version, so a future change to a record's format can upgrade older data, and older clients leave newer data alone.

## 1.1.0

- **Crafting tab:** Crafters has its own tab, between Members and Guild life, so Members is just the roster.
- **Roster:** the Professions column is replaced by Rank and Last seen (where someone is, or how long ago they were on). Both sort. Professions still show when you hover over someone.
- **Right-click menu on the roster:** whisper or invite to group. Officers and the Guild Master also get Promote and Demote, following the game's rules (never to your own rank or above). Each asks before changing anything.
- The TOC also lists interface 11509, so CurseForge's packager can match the file to a game version.

## 1.0.2

- New versions are packaged for CurseForge automatically when they're tagged (`.pkgmeta`), so the CurseForge app picks up updates. The package holds only the addon folder.

## 1.0.1

- Fixed the key bindings list: "Issues with Tissues" was showing as a bindable row of its own under Other. The two bindings now have their own expandable Issues with Tissues section in the game's Key Bindings, like other addons.

## 1.0.0

The first release on CurseForge.

- **Tidier saved data:** professions and recipes of characters who left the guild are cleared after they've been gone from the roster for three days, and shared recipes are capped at 1,500 records (oldest first). A roster that loads only partly is never taken as people leaving.
- `/iwt bug` shows the size of each part of the saved data (recipes, chat, loot notes...).
- The addon's page link is in its TOC, for the game's AddOns list and CurseForge.
- For developers: the window code is split into `UI.lua` (window and tabs), `Widgets.lua` (buttons, lists, inputs, the copy box) and `Buttons.lua` (minimap and guild-window buttons, key bindings). Luacheck (`.luacheckrc`) checks every file for stray globals and unused code.

## 0.9.0

Layer hopping goes, and the window gets nicer to use and quicker in a big guild.

- **Layer hopping removed:** Blizzard turns layer hopping off after Wednesday 25 November, so the Hop tab, `/iwt layer`, `/iwt hop` and the layer-hop setting are gone. The window is down to four tabs: Home, Chat, Members and Guild life. Messages from guildmates still on 0.8 are ignored.
- **Crafting professions only:** the addon now tracks Alchemy, Blacksmithing, Enchanting, Engineering, Leatherworking, Tailoring and Cooking. Gathering skills, First Aid and Fishing are no longer read or shared, and older records from guildmates on 0.8 that still list them are filtered out of the Roster, Crafters and Home.
- **Donations:** the Guild Master can change the donation goal without asking the officer who set it, and then owns it. Officers still ask the owner first.
- **Window size:** a slider in Settings sizes the window from 70% to 130%. `/iwt scale 90` does the same.
- **Window sounds:** the window makes the game's usual sound when it opens, closes or changes tab. Settings can turn this off.
- **Combat:** a setting hides the window when combat starts and brings it back when combat ends. It's off by default.
- **Chat:** when you've scrolled up, a Newest button shows how many lines have come in since and takes you back to the bottom. Chat times can show as 2:05pm instead of 14:05.
- **Keyboard:** Ctrl+F jumps to the search box on Roster, Crafters and Loot notes, and Enter picks the first result (whispers the guildmate or crafter, or selects the loot note). The Roster has a new name search.
- **Quicker:** a big catch-up from guildmates at login is taken in small batches, so the game no longer hitches. The login timers are spread out. Crafters searches and chat history are faster in a big guild.
- `/iwt bug` and the profiler report now show the addon's memory use and how long each part took to start.
- The bug log clears itself: an error not seen for 24 hours is dropped, and the log starts afresh once it's a day old.
- For developers: a speed test with a 500-member guild runs on every push and fails if a redraw, search or sync gets slower than its limit.

## 0.8.2

- The welcome and What's new card now grows to fit its text, so its buttons no longer cover the last lines. It's a little wider too.

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
