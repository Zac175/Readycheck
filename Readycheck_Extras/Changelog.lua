------------------------------------------------------------------------
-- Readycheck_Extras - Changelog Data + Popup
-- RC.Changelog.versions is a pure data table, newest-first. Each entry:
--   { version = "x.y.z", date = "YYYY-MM-DD", title = "...", sections = {
--       { type = "added" | "changed" | "fixed", items = { "...", ... } },
--       ...
--   } }
-- Changelog items are plain English only - no implementation details, no
-- internal system or file names. Do not comment individual entries below.
--
-- AN ITEM FOR SOME GAME VERSIONS ONLY is a table instead of a string:
--   { "the line", feature = "world_tools" }       shown where that feature runs
--   { "the line", feature = { "a", "b" } }        shown where all of them run
--   { "the line", only = "tbc" }                  shown on that game version
--   { "the line", only = { "tbc", "forever" } }   shown on any of those
-- feature ids are Core_Flavor's (RC.FEATURE_FLAVORS, the table that takes
-- a feature's pages away where it does not run); game versions are
-- "era", "tbc" and "forever". A plain string shows everywhere. Tag a line
-- only when it is plainly about one thing. A version may also carry
-- titles = { tbc = "...", forever = "..." } for where its title names
-- something that game version does not have.
-- RC.Changelog.versions is what this game version sees (the other game
-- versions' lines taken out, empty sections and versions dropped);
-- RC.Changelog.allVersions is the whole history as written.
------------------------------------------------------------------------
local function InitializeChangelog()
    local RC = _G.Readycheck
    if not RC then
        C_Timer.After(0.1, InitializeChangelog)
        return
    end

    if RC.Changelog and RC.Changelog.initialized then
        return
    end

    if not RC.db then
        C_Timer.After(0.5, InitializeChangelog)
        return
    end

    if not RC.UI then
        C_Timer.After(0.5, InitializeChangelog)
        return
    end

    RC.Changelog = RC.Changelog or {}
    RC.Changelog.initialized = true

    local function GetGoldText()
        if RC.GetColor then
            return RC:GetColor("ui", "headerText")
        end
        return { r = 1, g = 0.82, b = 0, a = 1 }
    end

    local TEXT = RC.UI and RC.UI.TEXT or { light = {0.85,0.85,0.85,1}, white = {1,1,1,1}, gray = {0.6,0.6,0.6,1}, red = {1,0.5,0.5} }

    -- Shared section styling for every changelog renderer. This file loads
    -- before ExtrasSidebar.lua (see Readycheck_Extras.toc), which consumes
    -- this table for its sidebar cards instead of duplicating it.
    RC.Changelog.sectionStyles = {
        fixed   = { color = {0.4, 0.8, 0.4}, label = "Fixed" },
        added   = { color = {0.4, 0.7, 1.0}, label = "Added" },
        changed = { color = {1.0, 0.8, 0.3}, label = "Changed" },
        removed = { color = {0.9, 0.4, 0.4}, label = "Removed" },
    }

    RC.Changelog.versions = {
        {
            version = "5.0.7",
            date = "2026-11-12",
            title = "A changelog for the game version you play",
            sections = {
                {
                    type = "changed",
                    items = {
                        "What's New and the Changelog page list only the changes for the game version you are playing.",
                    },
                },
            },
        },
        {
            version = "5.0.6",
            date = "2026-11-12",
            title = "Standing route reminders, and timers that work with Nova again",
            titles = { tbc = "Standing route reminders", forever = "A solid resize corner" },
            sections = {
                {
                    type = "added",
                    items = {
                        { "Raid routes: standing reminders. A line such as \"hold your potion\" stays on the tracker from one step until a later one. Add it from a step's Add action menu.", feature = "raid_route" },
                        { "Route tracker, bar style: when your gear is swapped, a tick and the set's name show beside the step.", feature = "raid_route" },
                        { "Route tracker, bar style: for a few seconds after a swap the bar shows everything you are wearing, with the pieces that changed lit. Both have a switch on the route's Settings tab.", feature = "raid_route" },
                        { "Buff Timer Network: the Status card says which timer format is in use and warns when other players are on a newer one.", feature = "world_tools" },
                    },
                },
                {
                    type = "changed",
                    items = {
                        { "Buff Timer Network: timers are shared in the format the current Nova World Buffs uses, so they pass between the two addons again. Older Readycheck versions need this update to keep receiving.", feature = "world_tools" },
                        "Every window's resize corner is one solid corner that lights up under the mouse and while you drag it.",
                        { "Route tracker, bar style: the bar is one row shorter. The old gear swap line under it is gone.", feature = "raid_route" },
                    },
                },
                {
                    type = "fixed",
                    items = {
                        { "Songflower and other world buff timers were missing with a current Nova World Buffs installed.", feature = "world_tools" },
                        { "Route settings: the Auto width button no longer sits on the scale slider.", feature = "raid_route" },
                        { "Route tracker: \"show the next step\" works as soon as it is ticked.", feature = "raid_route" },
                    },
                },
            },
        },
        {
            version = "5.0.5",
            date = "2026-11-11",
            title = "One look for every control, and after-kill gear sets",
            titles = { forever = "One look for every control" },
            sections = {
                {
                    type = "changed",
                    items = {
                        "Checkboxes, dropdowns, sliders, tabs and text boxes look the same everywhere, inside the settings window and out.",
                        "Buttons and close buttons outside the settings window match the ones inside it.",
                        "Dark colours saved by older versions give way to the new lighter ones. Colours you picked yourself are kept.",
                        "The stats bar's background is the same grey as the windows.",
                    },
                },
                {
                    type = "fixed",
                    items = {
                        { "A gear set meant for after one boss no longer goes on after a later boss that has none set.", feature = "boss_gear_kill" },
                    },
                },
            },
        },
        {
            version = "5.0.4",
            date = "2026-11-10",
            title = "Commanding Shout, lighter windows and a faster search",
            sections = {
                {
                    type = "added",
                    items = {
                        { "TBC: the Battle Shout reminder can watch Commanding Shout instead. Pick the shout you keep up on its page.", only = "tbc" },
                    },
                },
                {
                    type = "changed",
                    items = {
                        "The pages in the sidebar are proper buttons, with a gold edge under the mouse and on the open page.",
                        "Tabs are raised buttons with a gold line on the open one.",
                        "Section titles have a gold mark and a line across the page.",
                        "Buttons have a raised face.",
                        "The window's corner buttons (reload, size, fold, close) are small raised buttons.",
                        "The Gear Manager's tabs match the rest of the window.",
                        "The \"What's New\" window's buttons match ZacUI's.",
                        "Options that do nothing on a game version are hidden on that version.",
                        { "Spec detection lists your talents on TBC and reads the new talent tree on WoW Forever.", only = { "tbc", "forever" } },
                        "The consumables checker, the bars and the trackers are a lighter grey instead of near-black.",
                        "On a new character more frames start in spots where they don't overlap. Characters you already have are not moved.",
                        "The settings search remembers what it has read, so it no longer stalls the first time you search each session.",
                    },
                },
                {
                    type = "fixed",
                    items = {
                        "The preview's small buttons no longer sit under the window's reload and close icons.",
                        "The settings window was darker than ZacUI's. It now uses the same colour.",
                        "Scrolling a long page no longer slows down near the top and bottom.",
                        "Slider handles have a thin dark outline.",
                        "The window's size is kept when you reopen it.",
                        "Typing in the settings search no longer lags.",
                        "The close button no longer glows white under the mouse, and the reload button is the same height as the others.",
                        "Sapphiron's reminders were greyed out on game versions without Polarity Mode.",
                    },
                },
            },
        },
        {
            version = "5.0.2",
            date = "2026-11-08",
            title = "A cleaner settings window",
            sections = {
                {
                    type = "added",
                    items = {
                        "A Twitch button next to the Discord one.",
                    },
                },
                {
                    type = "changed",
                    items = {
                        "Reload and the window's size are in the header; the extra Close button at the bottom is gone.",
                        "A sharper close button that matches ZacUI's.",
                        "Scrolling the settings is faster, and speeds up when you spin the wheel quickly.",
                        "The Discord and Twitch buttons sit next to the version number.",
                        "Known issue: some popups still don't fully match the new settings style. A full styling pass is coming in the next update.",
                    },
                },
            },
        },
        {
            version = "5.0.1",
            date = "2026-11-08",
            title = "A smoother setup",
            sections = {
                {
                    type = "added",
                    items = {
                        "A Discord button to contact Zac for help.",
                    },
                },
                {
                    type = "changed",
                    items = {
                        "The first-time setup is one short, smooth flow.",
                        "Popups and their headers match the new settings window.",
                    },
                },
            },
        },
        {
            version = "5.0.0",
            date = "2026-11-08",
            title = "A new settings window",
            sections = {
                {
                    type = "added",
                    items = {
                        "A new settings window: bigger, with a sidebar, the page title pinned at the top, banded rows, round sliders and a thin scrollbar. Drag it from anywhere, fold it down to its name, and change its scale from the bottom bar.",
                        "Search every setting from the box at the top of the sidebar, with each result showing where it lives.",
                        "Raid consume reminders: in a raid, the important consumables you are not using show in the reminders bar.",
                        { "More features now work on TBC Anniversary and WoW Forever instead of switching off.", only = { "tbc", "forever" } },
                    },
                },
                {
                    type = "changed",
                    items = {
                        { "On WoW Forever, the Battle Shout tracker counts the whole raid, since the shout reaches everyone nearby there.", only = "forever" },
                        "A reworked first-time setup.",
                    },
                },
                {
                    type = "fixed",
                    items = {
                        "An error from the minimap button some players saw at login.",
                    },
                },
            },
        },
        {
            version = "4.9.0",
            date = "2026-11-06",
            title = "TBC Anniversary and WoW Forever, and customize everything",
            sections = {
                {
                    type = "added",
                    items = {
                        "Readycheck now runs on TBC Anniversary and WoW Forever as well as Classic Era.",
                        "Features that only make sense in Classic Era switch themselves off on TBC and Forever, and their pages say why. This covers world buffs, Chronoboon, Classic raid boss setups and raid routes.",
                        "Type /rc flavor to see which features are on for your game version.",
                        { "Consumables follow your game version. TBC and Forever get their own items, potions, stones, oils and poisons on the bars, in the checker and in the reminders.", only = { "tbc", "forever" } },
                        { "In TBC, a battle elixir and a guardian elixir no longer count as clashing. A flask covers both.", only = "tbc" },
                        "Almost every text can now be moved and reworded: bar button texts and timers, the reminder popup, the raid buff and boss debuff trackers, the TTK display, the stats bar, the route tracker, the repair reminder, nameplate auras, the consumables checker, gear buttons and the World Buffs board.",
                        "Most bars and windows have fade, opacity, shadow, glow, layer and scale settings.",
                        "The reminder popup can grow in any direction and has its own look for each state.",
                        "The raid buff and boss debuff trackers can change their look as time runs low and play an urgent sound.",
                        "Live previews for every visual feature, including the World Buffs board, the consumables checker window, world map pins, the minimap button, the stats bar buff list and the gear set picker.",
                        "Move mode now includes the spec popup, the must-have items alert and the gear swap notice, and shows the position while you drag.",
                    },
                },
                {
                    type = "changed",
                    items = {
                        "Settings pages are split into tabs, and rows of buttons that picked a value are now dropdowns.",
                        "Checkboxes and tabs have a cleaner look with a gold tick.",
                        "Previews take up less room.",
                        "Settings pages use less memory.",
                        { "In TBC, poisons no longer warn about low charges, since they last an hour.", only = "tbc" },
                        { "A finished raid route shows the last gear swap, then folds the tracker bar away.", feature = "raid_route" },
                    },
                },
                {
                    type = "fixed",
                    items = {
                        "Weapon stone and oil buttons could click a game popup while you were dead.",
                        "Consumables bar buttons didn't resize when you changed the button size.",
                        "Some previews were blank.",
                        "Previews could flicker while a page resized.",
                        "\"Can't measure restricted regions\" errors from nameplate auras and animations.",
                        { "Boss buttons on the raid page could overlap.", feature = "raid_configs" },
                    },
                },
            },
        },
        {
            version = "4.8.4",
            date = "2026-10-25",
            title = "Smoother gear swaps and raid config fixes",
            sections = {
                {
                    type = "changed",
                    items = {
                        "Less lag in raids. Looting, zoning and procs are much lighter on your game.",
                        "Consumable voice warnings now play at your Show before expiry time. Short buffs are called out as soon as you use them.",
                        { "Raid configs now show a boss as set up when it only has gear swaps.", feature = "raid_configs" },
                        { "Item lists in raid configs and routes only show what's in your bags, plus one Target Dummy.", feature = "raid_configs" },
                        "The next-trinket icon on the gear buttons is smaller, and the button text shows on top of it.",
                        "Trinket swaps show right away on both the trinket bar and the gear buttons.",
                    }
                },
                {
                    type = "fixed",
                    items = {
                        "Gear swaps queued in combat could put on the wrong item if your bags changed.",
                        "Picking a trinket in combat on both the gear buttons and the trinket bar put both on after combat. Now only your last pick counts.",
                        "Clicking the item in your other trinket, ring or weapon slot in a gear button's menu did nothing. Now it swaps them.",
                        "A gear button's menu opened right after a swap could show your old items.",
                        "Taking gear off could fail if your first free bag slot was in a herb, ammo or soul bag.",
                        "Trinket auto-swap could hold a used trinket for 30 seconds after its buff was gone.",
                        "Voice warnings for short buffs played too late.",
                        "Countdown numbers could get stuck on consumables bar buttons.",
                        "Weapons in your bags could be missing from the weapons bar after logging in.",
                        { "After-kill and on-target consumable reminders didn't work if you carried a different version of the item.", feature = "raid_configs" },
                        { "Raid config: the shared Four Horsemen setup could stop working, route gear sets sometimes weren't put on, and the raid page could edit the wrong profile or go blank.", feature = "raid_configs" },
                        "Changing the font could make some text the wrong size.",
                    }
                },
            }
        },
        {
            version = "4.8.3",
            date = "2026-10-23",
            title = "Thaddius timer, new route tracker, rogue poisons",
            titles = { tbc = "A new route tracker, and rogue poisons", forever = "Rogue poisons" },
            sections = {
                {
                    type = "added",
                    items = {
                        { "Polarity Mode: a timer starts when Thaddius dies and counts down to your Death Wish, then to Sapphiron. Turn it on or off on the Polarity Mode Sources tab.", feature = "polarity" },
                        { "A new route tracker: a small panel or a one-row bar, with each mob's kill count and what happens when the step is done.", feature = "raid_route" },
                        { "Kill times remember the class you played. Predictions can use only your class's kills, or include kills from related raid setups.", feature = "ttk" },
                        "Rogue poisons on the weapons and consumables bars, with a separate poison for each hand and a warning when the time or the charges run low.",
                        "Class items for every class in the consumables checker.",
                        "More looks for the reminder icons: border style, glow size and colours, under Reminders > Position > Icon Display.",
                    }
                },
                {
                    type = "changed",
                    items = {
                        "Consumable voice warnings were rebuilt so they are no longer skipped, and voice alerts that come at the same moment wait their turn instead of being lost.",
                        "Trinket auto-swap no longer takes off a trinket that is ready to use or still active. Set your own priority number for each trinket, or pick by list order instead.",
                        "A consumable used with a keybind, a macro or from your bags shows its cooldown on the consumables bar.",
                    }
                },
                {
                    type = "fixed",
                    items = {
                        { "Polarity Mode picks up DBM and BigWigs pull timers again.", feature = "polarity" },
                        { "Syncing raid profiles with a raid mate no longer turns your routes off.", feature = "raid_route" },
                        "An error in combat when a consumable buff ran out, which also stopped the consumables bar updating after the fight.",
                        "Some weapon oils and poisons showed the wrong name.",
                        "Bars with their background turned off can be moved right up to the edge of the screen.",
                        { "Searching the settings for a raid boss works again.", feature = "raid_configs" },
                    }
                },
            }
        },
        {
            version = "4.8.2",
            date = "2026-10-15",
            title = "Hide gear from menus, buff push-off history, quieter alerts",
            titles = { tbc = "Hide gear from menus, quieter alerts", forever = "Hide gear from menus, quieter alerts" },
            sections = {
                {
                    type = "added",
                    items = {
                        "Hide items and gear sets from the gear button hover menus: Ctrl+Right-click them. Hold Shift over the menu to see them again.",
                        { "Buff cap: the last 40 buffs that got pushed off, what pushed them and where, on the stats bar settings page.", feature = "buff_pushoff" },
                        "The consumables and potion bars can now fit up to 40 buttons in a row.",
                    }
                },
                {
                    type = "changed",
                    items = {
                        "The repair reminder stays out of the way in combat and shows after the fight.",
                        "Short potions now warn just before they run out, not a minute early.",
                        { "World buff \"cooldown ready\" and \"dropped elsewhere\" alerts are silent again. You can still pick a sound for them.", feature = "world_tools" },
                        "The minimap icon flips over when you mouse over it, like the icon on the windows.",
                    }
                },
                {
                    type = "fixed",
                    items = {
                        "Voice alerts no longer say \"Potion\" while your potions are on cooldown.",
                        "Items you hid from the bars no longer get voice alerts.",
                        "Trinket reminders no longer repeat over and over for trinkets you can't use.",
                        { "Routes: a kill step no longer gets skipped when the same mob is in two steps in a row.", feature = "raid_route" },
                        "The main hand and off hand stone buttons show the right weapon after a swap.",
                    }
                },
            }
        },
        {
            version = "4.8.1",
            date = "2026-10-11",
            title = "Routes from Warcraft Logs, must-have items, buff cap counter",
            titles = { tbc = "Routes from Warcraft Logs, and must-have items", forever = "Must-have items" },
            sections = {
                {
                    type = "added",
                    items = {
                        { "Build a raid route from a Warcraft Logs report on the website: Routes > From Logs.", feature = "raid_route" },
                        "Copy my character: one string that takes your gear and consumables to the website.",
                        { "Buff cap counter on the stats bar, with a warning when a buff gets pushed off.", feature = "buff_pushoff" },
                        "Must-have items: big icons in the middle of your screen if you enter a raid without one.",
                        "Default list: LIP, Elixir of Poison Resistance, target dummy. Edit it in Consumables Checker.",
                    }
                },
                {
                    type = "changed",
                    items = {
                        "The weapon skill warning only shows when you zone into a raid.",
                        { "The in-game raid map and route builder are gone; the website does both better.", feature = "raid_route" },
                    }
                },
                {
                    type = "fixed",
                    items = {
                        "Throwing Dynamite no longer makes the consumables bar announce Holy Water.",
                        "No more LibSharedMedia errors at login next to WeakAuras.",
                    }
                },
            }
        },
        {
            version = "4.8.0",
            date = "2026-10-05",
            title = "Buff and debuff trackers, hotswap queue, smoother swaps",
            titles = { forever = "Raid buff tracker, hotswap queue, smoother swaps" },
            sections = {
                {
                    type = "added",
                    items = {
                        "Raid Buff Tracker: shows how long your raid buffs have left and warns you before they run out.",
                        { "Boss Debuff Tracker: shows the raid's debuffs on the boss and warns you when one is about to drop.", feature = "boss_debuff_tracker" },
                        "Both trackers can whisper whoever cast a buff or debuff when it runs out. Off by default.",
                        "Hotswap macros now work in combat: the gear swap waits and happens when combat ends.",
                        "Gear waiting to be swapped is shown on your gear buttons and character sheet.",
                        "Settings search now finds single options and jumps to them.",
                        "New installs get a short tour of the settings window. Replay it with /rc tutorial.",
                        { "A boss can ask which gear set to wear next when it dies.", feature = "boss_gear_prompt" },
                        { "Warning when your Darkmoon Faire debuff gets pushed off.", feature = "buff_pushoff" },
                        { "Move or copy kill history between raid profiles.", feature = "ttk" },
                        "Reminder icons have a glow you can set to pulse, stay steady or turn off.",
                    }
                },
                {
                    type = "changed",
                    items = {
                        "Gear and trinket swaps show instantly and fade in smoothly.",
                        "Nameplate debuff icons run much faster in big pulls.",
                        "Consumables Checker pop-ups got the new look.",
                        "Cleaner gear swap menu.",
                        "New look for window title bars and the character stats bar.",
                        "Gear set icons show everywhere a set is listed.",
                        { "Kill history is a compact paged list and stays fast with lots of kills.", feature = "ttk" },
                        "The minimap button's menu lists every settings page.",
                        "Save & lock in Edit Mode now locks every bar.",
                    }
                },
                {
                    type = "fixed",
                    items = {
                        "No more false 'gear swap failed' message after a boss.",
                        { "Battle Shout tracker shows the right attack power.", feature = "battle_shout_party" },
                        { "World buff board: Rend and Onyxia timers are right again.", feature = "world_tools" },
                        "Gold totals across your characters are right again.",
                        "FPS on the stats bar updates again.",
                        { "Routes pasted from Discord or a text file now import.", feature = "raid_route" },
                        "Fixed an error when a trinket swap failed with an empty trinket slot.",
                        "Fixed an 'action blocked' error in combat.",
                    }
                },
            }
        },
        {
            version = "4.7.9",
            date = "2026-09-28",
            title = "Route fixes, bar visibility and a simpler colour editor",
            titles = { forever = "Bar visibility and a simpler colour editor" },
            sections = {
                {
                    type = "fixed",
                    items = {
                        { "Routes no longer skip ahead when you kill mobs that belong to a later step.", feature = "raid_route" },
                        { "Editing a route mid-raid keeps you on the step you were on.", feature = "raid_route" },
                        { "Routes pick up properly on a fresh run of the same raid.", feature = "raid_route" },
                        "Bars set to show only in raids or only in cities no longer pop back up when you zone or rest.",
                        "The Weapons Bar's 'In Cities' option now works.",
                        "Fire-toasted Bun and Dark Desire are now treated as the same buff, so the bar warns when one would replace the other.",
                        "The raid profile picker no longer flashes when you pick a profile.",
                        "Fixed an error from the equipment reminder on some saved settings.",
                    }
                },
                {
                    type = "added",
                    items = {
                        "Battle Shout reminder can now track just your own shout, and show everywhere.",
                        "Every bar can now be shown only while you are in a group, and you can pick exactly which raids count as 'raids'.",
                        "Trinket, Weapons and Potions bar settings pages got the same fresh look as the rest.",
                    }
                },
                {
                    type = "changed",
                    items = {
                        "Battle Shout reminder and tracker 'Inside Raids' now only show inside a raid.",
                        "Picking a raid profile is now one click.",
                        "Readycheck has an Edit Mode button to move its frames.",
                        "The colour editor is much easier to use: search for a colour, click it and adjust it right there with sliders, a hex box or the colour wheel. Changed colours are marked and can be reset one at a time.",
                        "Mesh sync rules now list every feature with a few simple choices each (settings, position, look, saved data), with tabs and a search box.",
                        "Settings pages were tidied up: clearer labels, confirmations before anything is deleted, and less clutter.",
                    }
                },
            }
        },
        {
            version = "4.7.8",
            date = "2026-09-21",
            title = "New look",
            sections = {
                {
                    type = "changed",
                    items = {
                        "Every window, menu and pop-up has been given a cleaner, flatter look that matches across the whole addon.",
                        { "Boss pages now put all the abilities and gear options in one row along the top. Click one and its settings open underneath, full width.", feature = "raid_configs" },
                        { "Trash pages work the same way now.", feature = "raid_configs" },
                        { "Ability settings can be copied to every other boss in the raid with one button.", feature = "raid_configs" },
                        "Green now means something is switched on, gold means it is the one you are looking at. They no longer get mixed up together.",
                        "Menus with nothing in them now say so, and tell you where to add something.",
                    }
                },
            }
        },
        {
            version = "4.7.7",
            date = "2026-09-05",
            title = "Minor bug fixes",
            sections = {
                {
                    type = "fixed",
                    items = {
                        "A few small fixes.",
                    }
                },
            }
        },
        {
            version = "4.7.6",
            date = "2026-08-27",
            title = "Minor bug fixes",
            sections = {
                {
                    type = "fixed",
                    items = {
                        "A handful of small fixes.",
                    }
                },
            }
        },
        {
            version = "4.7.5",
            date = "2026-08-22",
            title = "Split into smaller addons, buff warnings that travel further, and a fuller equipment reminder",
            titles = { tbc = "Split into smaller addons, and a fuller equipment reminder", forever = "Split into smaller addons, and a fuller equipment reminder" },
            sections = {
                {
                    type = "changed",
                    items = {
                        "Readycheck is now split into more addons, so you can switch off the bits you do not use from the AddOns list. Your settings stay put either way.",
                        "The equipment reminder now shows everything it has flagged at once. Before, if more than one watched item was on - a shield and a utility item, say - you only ever saw one of them. Up to nine can show now.",
                        "The extra icons pack into the same box you sized in the options, so the reminder takes up no more of your screen with six items than it did with one. The label underneath only fits when a single icon is showing, so it steps aside when there is more than one.",
                    }
                },
                {
                    type = "fixed",
                    items = {
                        { "Warnings that a world buff is about to drop now reach your other characters. Before, the warning only travelled to people in your guild or group, so a character in a different guild never got the countdown. Rend, Onyxia, Nefarian and Zandalar warnings now go out to your linked accounts as well.", feature = "world_tools" },
                        { "A buff warning now tells you whether it came from your guild or from your linked accounts.", feature = "world_tools" },
                        "The equipment reminder no longer goes stale. Equipping a watched item that is not a weapon - a belt, chest or trinket - now updates the reminder straight away, instead of leaving the old icon up until you next changed weapons.",
                        { "Turning off the buff timer network now works. The tickboxes on that page were saving the wrong thing, so unticking one turned it on. Anything left in a mess gets reset to off when you log in.", feature = "world_tools" },
                        { "That switch also works straight away now instead of needing a reload, and the page updates as you click.", feature = "world_tools" },
                        { "You can use /wbtnet on, off or toggle from chat. /wbtnet diag tells you why nothing is syncing.", feature = "world_tools" },
                        "Gold from your other characters no longer disappears from the gold list after a few minutes.",
                        "Characters you hear about second-hand no longer lose their race.",
                        "The new addons switch themselves on when you update, even if your addon manager installed them turned off. Anything you had already turned off by hand stays off.",
                    }
                },
            }
        },
        {
            version = "4.7.4",
            date = "2026-08-16",
            title = "World Tools, Buff Timer Network and a smarter trinket swap",
            titles = { tbc = "A smarter trinket swap, and macros that write themselves", forever = "A smarter trinket swap, and macros that write themselves" },
            sections = {
                {
                    type = "added",
                    items = {
                        { "New World Tools section. Buff Drops shows timer bars and plays a sound when a world buff is about to drop. Automation can accept summons, click through gossip, and do common turn-ins for you.", feature = "world_tools" },
                        { "New Buff Timer Network page. See when Rend, Onyxia, Nefarian and Songflower are coming up on each layer, shared between Readycheck users. No separate addon needed.", feature = "world_tools" },
                        "New Target Range tab on the Nameplates page. Add a mob and your nameplate distance changes to what you picked while you target it, then goes back to normal.",
                        "Smart Macros can now write the macro for you. Pick an action, type a name, and it shows you the finished macro. No macro knowledge needed.",
                        "Smart macro rules can check more things: a specific boss or mob, world boss, elite, enemy, friendly, not-undead, or no target. One rule can hold up to five of these. A rule can also need an item in your bags that is ready to use.",
                        "Farm route steps can now do things when you finish them: swap a gear set or trinket, equip an item, or remind you to pot - with a sound, an icon, and an optional delay. Steps can be copied, and the mob picker can filter by wing.",
                        "The sync page now lets you pick single settings, not just whole groups. New Only button sends just one thing. New preset buttons send or receive everything or nothing. The page tells you in plain words what this character sends.",
                        "Nameplate settings, the world buff board, your docked gear buttons, the sync transfer bar's position, and the Buff Timer Network settings can now sync between accounts.",
                        { "Smart macros can now be set to only run in Onyxia's Lair, Zul'Gurub or Ruins of Ahn'Qiraj, and every raid's trash is now sorted into wings.", only = "era" },
                        "/rc mesh now lists what you send and receive by name. /rc mesh undo puts your old send choices back.",
                        "If part of the addon is turned off in the AddOns list, you now get a login message saying what is missing and how to turn it back on.",
                    }
                },
                {
                    type = "changed",
                    items = {
                        "Trinket auto-swap is smarter. It waits for your cast to finish, finishes blocked swaps after combat, grabs whichever trinket is ready sooner, saves the slot for a Priority trinket, and stops pointless back-and-forth swapping on shared cooldowns.",
                        "Queue order now matters for trinket auto-swap: when more than one trinket is ready, the one higher in the queue wins.",
                        "If you equip a trinket yourself, the auto-swap now leaves it alone until that trinket has done its job.",
                        "A smart macro's raid setting now sits on the macro, not on each rule. If you had set it per rule, set it once on the macro instead.",
                        "The minimap button is now named Readycheck in addons that collect minimap buttons. You may need to grab or hide it again in those addons.",
                    }
                },
                {
                    type = "fixed",
                    items = {
                        "The docked button spacing slider now keeps its value after a reload.",
                        "Macros using the addon's old name fix themselves next time you log in.",
                        "Gear sets that unequip a slot now finish after combat instead of quietly giving up, and tell you when your bags are full.",
                        "Boss trinket swaps can no longer be yanked out mid-swap by the auto-swapper, and a passive trinket can no longer get a slot stuck forever.",
                        "Swapping in a trinket that was in your other slot no longer locks the pushed-out trinket in place.",
                        "Spamming a gear set macro no longer fires the swap over and over.",
                        "Sync errors now say what went wrong in plain words - wrong password, config too big and which one, or where to go to retry.",
                        "Moving things is now pixel perfect. Dragging snaps to real screen pixels, and each arrow press in the mover moves exactly one pixel, at any UI scale.",
                        "The Berserking troll racial now tracks for warriors and rogues. Each class has its own version of the spell, and only the caster classes' version was being watched.",
                        "Gear buttons you line up by hand no longer drift out of alignment after a reload.",
                        { "While remote editing someone's raid config, creating, deleting, renaming, merging, importing or exporting a profile now works on their config instead of failing with 'profile does not exist'.", feature = "raid_configs" },
                        "In /rc moveui, the box around a group of docked buttons now sits over the buttons instead of off to one side, and dropping it puts them exactly where you left the box.",
                        "Snowballs are now tracked in the consumables checker under Utilities & Tools, with a recommended count of 5.",
                        { "Trinket reminders, utility items, post-death consumables, defensive cooldowns and bulk trash edits now change the config of the character you are remote editing. They were quietly editing your own settings instead, then reporting success.", feature = "raid_configs" },
                        { "The route page's boss gear set picker now edits the config you have open when remote editing, instead of moving the gear set out of their route and into your own boss setup.", feature = "raid_configs" },
                        { "Opening a trash page while remote editing no longer stamps your own race and class onto your profile.", feature = "raid_configs" },
                        { "Editing someone's raid config remotely now keeps syncing. Only your first change was being sent - everything after it was silently dropped for several minutes as a duplicate, so sliders, checkboxes and timers looked like they stopped working.", feature = "raid_configs" },
                        { "Deleting, renaming or merging a profile while remote editing now actually reaches the other character. Only the profile they had open was ever sent, so removed profiles used to live on forever on their end.", feature = "raid_configs" },
                        { "Switching raid profile from the zone-in popup or the boss notes page always switches your own profile, even with a remote edit window open.", feature = "raid_configs" },
                        { "Renaming someone else's raid profile no longer renames your own boss notes.", feature = "raid_configs" },
                        "Settings that arrive from another character now take effect straight away. They were being saved but nothing on screen moved until you reloaded, which looked exactly like sync not working.",
                        "Chat reliably tells you what arrived when a sync lands - one line per sender, listing the categories. Automatic syncs never announced themselves before, only manual pushes did.",
                        "Changing a setting your character isn't set to send now tells you so once, instead of silently doing nothing.",
                    }
                },
            }
        },
        {
            version = "4.7.3",
            date = "2026-08-08",
            title = "Import without the crash",
            sections = {
                {
                    type = "fixed",
                    items = {
                        "Importing settings no longer crashes the game. Export strings are much shorter now.",
                        "Vulture Gizzard is now counted in your bags.",
                        "The voice warning no longer says oil when a sharpening stone is about to fall off your weapon.",
                    }
                },
            }
        },
        {
            version = "4.7.2",
            date = "2026-08-06",
            title = "Minor bug fixes",
            sections = {
                {
                    type = "fixed",
                    items = {
                        { "Trinkets equipped by a boss gear swap can no longer be swapped off by the trinket auto-swap while the boss is alive - including trinkets that come from the full gear set, not just the per-slot overrides.", feature = "raid_configs" },
                        "The missing-consumables warning on raid entry now only lists items you have none of, instead of also naming things you are merely low on.",
                        "The raid-entry warning no longer claims weapon stones are missing when the stones are sitting in your bags.",
                        { "Polarity Mode now counts from the moment the boss is actually engaged, so the potion and dummy reminders land at the same instant every single pull. The potion reminder now sits at 5 seconds out of the box.", feature = "polarity" },
                        { "Using a Blasted Lands buff or a Zanza potion now hides all the others as conflicting on the consumables bar, in both directions.", only = "era" },
                        "Right-clicking an item in the consumables checker once again opens the recommended-amount editor, so you no longer have to dig through the settings page.",
                    }
                },
            }
        },
        {
            version = "4.7.1",
            date = "2026-08-03",
            title = "Speaks your language",
            sections = {
                {
                    type = "added",
                    items = {
                        "Readycheck is now translated: German, French, Spanish, Italian, Portuguese, Russian, Korean and Chinese clients see the menus, pages and buttons in their own language.",
                        "Russian, Korean and Chinese clients automatically get a font that can display their language.",
                        "The consumables, potions, weapons and trinket bars can now show item tooltips on hover - off by default, with a checkbox on each bar's settings page.",
                        "The sync rules page was rebuilt: choose exactly what each connected account sends and receives, category by category.",
                        "New sync choices for stats bar looks, enchant preferences and farm routes.",
                    }
                },
                {
                    type = "changed",
                    items = {
                        "The Nameplate Debuffs page is now called Nameplates, and its groups collapse so the page stays short.",
                        "Choosing who you accept data from now lives in one place on the Network tab.",
                    }
                },
                {
                    type = "fixed",
                    items = {
                        "Syncing between accounts is faster and more reliable, with less chat traffic.",
                    }
                },
            }
        },
        {
            version = "4.7.0",
            date = "2026-07-31",
            title = "Raid pages and weapon buttons",
            titles = { forever = "Weapon buttons" },
            sections = {
                {
                    type = "added",
                    items = {
                        { "Boss and trash pages redesigned: pick an ability or mob on the left, set it up on the right.", feature = "raid_configs" },
                        "Anything already set up shows a green marker.",
                        "The consumables bar now has Main Hand, Off Hand and Bag Weapon buttons - the full weapon set without needing the Weapons Bar.",
                        "Right-click a weapon button to pick which stone or oil to use. The menu opens toward the middle of the screen.",
                        "Right-click now uses regular consumables just like left-click.",
                        "Mark must-have items as Priority (right-click an item in the checker) and optionally have the raid-entry warning only mention those.",
                    }
                },
                {
                    type = "fixed",
                    items = {
                        { "Route tracker no longer skips ahead when mobs with the same name live in more than one wing.", feature = "raid_route" },
                        "Right-clicking a weapon button no longer applies the stone.",
                        "Weapon buttons now work for every class and for staves - healers get their mana oil.",
                        "A used consumable can no longer stay invisible on the bar.",
                        "Fixed an error when zoning into a raid with the missing-consumables warning on.",
                        { "Clicking trash mobs no longer closes the wrong section.", feature = "raid_configs" },
                        "The settings window is faster and no longer slows down the game over long sessions.",
                    }
                },
            }
        },
        {
            version = "4.6.9",
            date = "2026-07-30",
            title = "One trinket system",
            sections = {
                {
                    type = "added",
                    items = {
                        "Ctrl-click a bar trinket to make it first in the queue.",
                        "Pick your own trinket button clicks - only add the ones you want to change.",
                        "/rc equip(Item Name,13) - equip or queue any item from a macro.",
                        "Zone into a raid missing consumables and it shows on screen.",
                    }
                },
                {
                    type = "fixed",
                    items = {
                        { "Route can't skip ahead when extra trash dies.", feature = "raid_route" },
                        "Queued trinkets look the same everywhere.",
                        "Queue badge shows on the slot being replaced.",
                        "One queued icon on dock trinkets, not two.",
                        "Food from your bags starts the bar timer.",
                        "Eating again refreshes the timer.",
                        "No more black squares after using stuff in combat.",
                        "Dockable buttons move with the UI mover.",
                        "Trinket settings page error fixed.",
                        "Custom trinket order stays put.",
                        { "Boss death trinkets can't get overwritten by the auto swapper.", feature = "raid_configs" },
                        "Shift-click cancels queued trinkets on dock buttons.",
                    }
                },
                {
                    type = "changed",
                    items = {
                        "One trinket queue system everywhere.",
                        "Click your equipped trinket to use it; click others to equip.",
                        "Right-click dock buttons to use them; Alt+Left locks.",
                        "Move mode highlights are subtler.",
                    }
                },
            }
        },
        {
            version = "4.6.8",
            date = "2026-07-29",
            title = "Ability reminders for every class",
            sections = {
                {
                    type = "added",
                    items = {
                        { "Ability reminders for every class - each class gets its own list of raid abilities to set up per boss. You only see what your character actually knows.", feature = "raid_configs" },
                        "Racials for everyone - Stoneform, Escape Artist, Will of the Forsaken, War Stomp, and more.",
                        "Type /rc abilities to see your class list.",
                        { "Drag route steps to reorder them.", feature = "raid_route" },
                        "Gear Set button border: green = wearing it, gold = own it, red = missing pieces.",
                        "Dockable buttons can be moved in move mode.",
                    }
                },
                {
                    type = "fixed",
                    items = {
                        "Stats bar shows up at login again and can't get stuck off screen.",
                        { "Boss kill-time display works on its own, and long boss names fit.", feature = "ttk" },
                        { "Sapphiron bar matches the pull countdown.", feature = "polarity" },
                        { "World Buffs board: no more vanishing toons, same list on every client, logouts show within seconds. /rc wb purge clears old junk.", feature = "world_tools" },
                        "Weapon bar clicks work again.",
                        { "Deselecting a boss no longer swaps your gear back.", feature = "raid_configs" },
                        "Troll Berserking shows for all classes.",
                        "Dropdowns open on top like they should.",
                        "Fixed some login errors.",
                    }
                },
                {
                    type = "changed",
                    items = {
                        "Disabled addon parts hide their menu pages.",
                        "Logging out shows on other toons instantly.",
                    }
                },
            }
        },
        {
            version = "4.6.7",
            date = "2026-07-25",
            title = "The voice update, rock-solid sync and speedrun routes",
            titles = { forever = "The voice update and rock-solid sync" },
            sections = {
                {
                    type = "added",
                    items = {
                        "Natural speech is the voice of everything now - loud, clear, in the voice you pick, working out of the box with no extra downloads. The recorded voice pack is an optional extra for anyone who prefers it.",
                        "Ready calls are short category words: Trinket ready, Item ready, Potion ready - and Stone, Oil and Potion on the bars. Potion strictly means the real shared-cooldown potions. Every bar item row now has a Say box next to its TTS toggle - type your own spoken name there and it wins over everything.",
                        { "Boss and trash notes can be read aloud, with a Speak button on every note editor to preview from anywhere.", feature = "boss_notes" },
                        { "The route catches up when the raid gets ahead of it, and its ready call covers every on-use item it equips - not just trinkets.", feature = "raid_route" },
                        "Shift+left-click cancels queued swaps: a slot button for that slot only, the Gear Set button for the whole queued set. When a full set is queued, shift-clicking a slot now removes just that slot from the coming swap (click again to restore it) - and clicking a slot with nothing queued is silent instead of chatty.",
                        { "Targeting a boss whose setup uses a full gear set plus slot overrides now equips each slot exactly once: the set skips the overridden slots instead of equipping its own weapon or offhand first and re-swapping it moments later.", feature = "boss_gear_target" },
                        "If TrinketMenu runs alongside, the Trinket Manager page says so instead of the two addons silently fighting over your slots.",
                    }
                },
                {
                    type = "fixed",
                    items = {
                        { "Speedrun-proof kill detection: chain-pulled packs, simultaneous deaths and look-alike mobs from other wings all count correctly, and the route can no longer skip a run of steps by mistake.", feature = "raid_route" },
                        { "Chronoboon reading is exact - every stored buff shows its own remaining time, Sayge's Dark Fortune included - and world buff timers can no longer drift when the game changes.", feature = "chronoboon" },
                        { "Names no longer vanish from the World Buffs window, and other characters' rows stay put while they are offline.", feature = "world_tools" },
                        { "Re-booning updates the window immediately: grabbing fresh buffs into the chronoboon no longer shows the previous boon's contents until you hover it.", feature = "chronoboon" },
                        "Mesh sync is finally quiet: characters verify first and send only what the other is missing. The endless re-syncing on every reload is gone at its root, and several accounts can log in together cleanly.",
                        "Speech never repeats itself, never reads raid icons aloud, and never goes silent - lines without a recording speak naturally at full volume.",
                        "Berserking reminders clear on cast for every class.",
                        "Buttons that could be hovered but not clicked after the game patch work everywhere again.",
                        "Frames move flush to screen edges, dropdown menus stay attached while scrolling, search leaves no ghost text behind, and Save & Lock recovers a stuck mover.",
                        "The TTS settings page is reorganized around the new voice system.",
                        "Under the hood, every tooltip the addon reads (enchant labels, weapon stones, chronoboon contents) now goes through one shared modern reader with a single fallback - one pattern, one place to fix.",
                        "Under the hood, the addon reads buffs through the game's modern named fields everywhere - the whole class of patch-shifted timers is closed for good - and buff-change handling wakes systems only when a buff they care about actually changed, cutting invisible work during heavy raid combat.",
                    }
                },
            }
        },
        {
            version = "4.6.6",
            date = "2026-07-22",
            title = "ItemRack import",
            sections = {
                {
                    type = "added",
                    items = {
                        "Import your ItemRack gear sets with one click - button on the Gear Manager settings page, shown only while ItemRack is enabled. Sets come over exactly as they were, and your existing sets are never overwritten.",
                        "Shift+left-click a gear button to cancel that slot's queued after-combat swap, and shift+left-click the Gear Set button to cancel a whole queued set (toggle in Gear Manager settings).",
                        "Docked button spacing slider in Gear Manager settings - live preview, 0 restores the classic look.",
                        "Trinket bar option to pin equipped trinkets to the front - now OFF by default.",
                    }
                },
            }
        },
        {
            version = "4.6.5",
            date = "2026-07-19",
            title = "Pinned buttons and Horde Mode",
            sections = {
                {
                    type = "added",
                    items = {
                        "Pin a gear set or a single item as its own one-click button: Alt+click it in the gear menus. Unlock and hit the X to remove one.",
                        "The big trinket button now shows the active config's trinkets under its name.",
                        "Option to swap the trinket button's clicks: left opens the menu, right toggles it. Off by default.",
                        "Trinket bar option to show only bag trinkets.",
                        "A progress bar for big syncs - one for sending, one for receiving - with a time estimate.",
                        "Readycheck also works on Burning Crusade Anniversary realms.",
                        "Readycheck has its own icon in the AddOns list now.",
                        "Moving frames works with the game's new Edit Mode: open it and every Readycheck frame gets a drag handle. A small button under the Edit Mode window opens the full mover panel.",
                        "The profiler now shows CPU numbers measured by the game itself.",
                        "The Naowh font is included in the font list.",
                    }
                },
                {
                    type = "changed",
                    items = {
                        "Horde characters start with Horde Mode on, and Horde Mode now hides main hand stone and oil buttons on every bar.",
                        "Stone buttons only show for classes that use stones.",
                        "The stone picker is one searchable list instead of a wall of buttons.",
                        "The trinket bar keeps your equipped trinkets first and no longer shuffles around when you swap.",
                        "Syncing is faster and much quieter: only new kills are sent, all raids go in one batch, every online character receives at once, and once everyone matches it goes silent.",
                        "If a sync fails to arrive, both characters say so in chat and it re-sends itself - no more fake Received messages.",
                        "Sync chat messages are one color.",
                        "The frame mover lists every movable frame, even ones you have not opened yet.",
                    }
                },
                {
                    type = "fixed",
                    items = {
                        "Wiping your kill history or raid configs on one character now refills properly from your others - no more blank Default raid page after a sync.",
                        "Two characters on the same account no longer overwrite each other's gear sets just because the sets share a name.",
                        "Button settings, name text and the lock now apply on your other characters right after syncing instead of fighting the old values.",
                        "Route changes sync right away instead of waiting for the next login, and a few settings that never synced at all now do - route tracker settings, stats bar picks, enchant picks and the Raid Planner.",
                        { "A character no longer shows up twice on the world buff board.", feature = "world_tools" },
                        "Broken or missing fonts no longer turn text invisible after the patch - they fall back to the standard font and tell you.",
                        "Closing the frame mover with Escape no longer leaves the drag handles stuck until a reload.",
                        "The weapons bar stone list no longer errors and shows every stone and oil.",
                        "Buttons that use items - gear buttons, trinkets, the consumable bars and the reload button after an import - respond to clicks again after the patch.",
                    }
                },
            }
        },
        {
            version = "4.6.4",
            date = "2026-07-14",
            title = "Route tracker, sync stability & smarter equips",
            titles = { forever = "Sync stability & smarter equips" },
            sections = {
                {
                    type = "added",
                    items = {
                        { "A boss can switch your trinket auto-swap config when it dies - set it on the boss's Gear tab under After Boss Dies.", feature = "raid_configs" },
                        { "The route tracker has prev/next step arrows with a visibility slider and position picker, and can be unlocked and dragged anywhere.", feature = "raid_route" },
                        { "The tracker can preview upcoming steps, with a depth slider.", feature = "raid_route" },
                        "Duplicate items with different enchants are distinct and pinnable - in the route slot picker (small green line under the name) and on the Speed Item Swaps page. Every equip grabs the pinned copy.",
                        "New voice calls, each with a switch: Potion ready when the shared cooldown ends, and Use it when a route-equipped trinket comes off cooldown.",
                        { "Raid config weapon swaps can move a weapon worn in your other hand.", feature = "raid_configs" },
                    }
                },
                {
                    type = "fixed",
                    items = {
                        "Clicking a spell no longer throws Interface action failed. The addon was writing over Blizzard globals; it no longer writes any.",
                        "Running several characters at once no longer disconnects you - sync stays under the rate limit and heartbeats jump ahead of bulk data.",
                        { "The tracker reads shorter: names compress, a next step on the same boss shows only its verb, the kill count always shows, and gear swaps no longer take over the display.", feature = "raid_route" },
                        "Reminders skip items already on cooldown, potions respect the shared lockout, and any potion - right or wrong - advances a potion step.",
                        "Reloading no longer re-equips step gear over what you put on by hand, and speed item swap-back survives reloads.",
                        { "Sim, Test Actions and manual advance apply raid-config gear exactly like real events: set first, then overrides win their slots, fast and verified.", feature = "raid_configs" },
                        "The engi reminder picker is populated again and the Target Dummy variants are one combined entry.",
                    }
                },
            }
        },
        {
            version = "4.6.3",
            date = "2026-07-13",
            title = "Raid Route",
            titles = { forever = "Fixes" },
            sections = {
                {
                    type = "added",
                    items = {
                        { "New Raid Route feature: build a kill-order plan for a raid - trash packs to count and bosses as checkpoints - and the addon follows along as you clear, swapping gear and trinkets and showing reminders exactly when each step completes. Open a raid in the sidebar and click the new Route tab. Off by default; turn it on per character from that page.", feature = "raid_route" },
                        { "A route builder map for Naxxramas: click bosses and trash packs in your kill order to lay out the whole run, and reorder or trim it right there.", only = "era" },
                        { "While a route is running, a small movable tracker follows along: the current step at the top, its action icons and reminders inside the frame, and an optional dim line showing the next step at the bottom. The frame hugs its content (long text wraps, nothing is ever clipped), a Basic mode strips it down to icons and only the text that matters, the background can be made fully transparent, and scale is the one size control. When a step equips gear, a brief 'Equipping' flash bridges it to the next step - and if the step completed in combat, that flash waits for the swap at the end of combat.", feature = "raid_route" },
                        { "Each step fires everything it carries - gear swaps, trinkets, reminders, spoken alerts - at the moment its own trigger completes: the kill count filling for trash, or the chosen pull/kill event for bosses. Swaps queue safely to the end of combat when you're fighting. Reminders picked from your bags - potions, sappers, dynamite and other consumables - disappear the moment you actually use the item; a step carrying usable items holds until you've used ALL of them (or the next step's requirements complete), and spoken alerts read one compact line per step, always at the step's own completion, cutting off cleanly when the route moves on.", feature = "raid_route" },
                        { "Steps can count several different mobs at once, equip a full gear set, individual trinkets, or any mix of equipment slots, and your progress survives reloads and disconnects. Boss pulls automatically put the plan back on track after wipes or skipped packs.", feature = "raid_route" },
                        { "The world buff board tracks the Darkmoon Faire fortune lockout per character: it counts down only while that character is logged in, pauses on logout, clears after 8 straight hours logged out in a major city, and clears early if a full debuff bar pushes it off.", feature = "world_tools" },
                        { "Fire Festival buffs appear on the world buff board only while someone shown actually has them, and a '60s only' switch (on by default) keeps low-level alts off the board.", feature = "world_tools" },
                        "The consumables bar's blank-when-used-in-combat behaviour is now a toggle (on by default), and the route tracker's gold accent stripe can be turned off.",
                        { "Routes can be shared three ways now: an Export/Import string on the Route page, a Mesh Share button that pushes the route to every online mesh member instantly, and full remote editing - fetch a raider's config and build their route for them, live.", feature = "raid_route" },
                        { "Trash notes rebuilt from scratch: add each note yourself, pick exactly which trash mobs it watches (whole packs or single mobs, in any mix), write the text, then choose its trigger - fire once after a set number of kills and show for a set duration, or show whenever one of its mobs is your target. Targeting one of a note's mobs displays it silently; the note SPEAKS when its kill requirement is met. Existing blanket, pack and per-mob trash notes carry over automatically. Boss notes use the same add-a-boss flow now instead of listing every boss with an empty editor.", feature = "boss_notes" },
                    }
                },
                {
                    type = "fixed",
                    items = {
                        "The weapon oil picker now offers every oil - Brilliant, Blessed, regular, Lesser and Minor Wizard and Mana Oils and more - instead of a fixed handful.",
                        "Typing in the custom item ID boxes on the potions and consumables pages no longer gets its focus stolen or interrupted by the search filter.",
                        "Dropdown menus no longer stay stuck open when the panel refreshes behind them.",
                        "A gear set saved with empty slots now strips everything in a single click instead of one item per press.",
                        "Hotswap is out-of-combat only, as it always effectively was: pressing it in combat now just prints your combat message instead of pretending to queue.",
                        { "Characters on the same game account finally share world buff, songflower and fortune data reliably: logging out no longer wiped the session's recorded buffs, so your alts show what they really have.", feature = "world_tools" },
                        { "Sapphiron opener timers no longer start when you Bloodrage before the pull - entering combat by yourself doesn't count anymore; the countdown anchors to Sapphiron actually engaging.", feature = "polarity" },
                        { "FIXED THE RAID-CONFIG EATER: opening remote edit ran an old cleanup that deleted a raid's entire local config whenever it referenced a gear set name this character doesn't have - and gear sets are per-character, so configs synced from your other toons tripped it constantly. The deletion then synced account-wide. The cleanup is gone, raid deletions no longer propagate over mesh at all, and profile loads keep an automatic safety backup.", feature = "raid_configs" },
                        { "Raid configs can no longer LOOK deleted: when the active profile pointer names a profile that no longer exists (rename or sync drift), the addon switches to your richest existing profile and says so, instead of silently creating a blank one over intact data.", feature = "raid_configs" },
                        { "World Buffs presence is now unified with Mesh Sync: any message a character sends over the mesh counts as its board freshness, so unchanged characters send ZERO world-buff traffic between real changes.", feature = "world_tools" },
                        { "Darkmoon Faire buff cooldown: when NovaWorldBuffs is installed, its per-character DMF tracking is used directly.", feature = "world_tools" },
                        { "World Buffs mesh traffic cut hard with many characters online: unchanged 30-second heartbeats shrink to a tiny presence ping (full state goes out on change or every 5 minutes), only ONE toon gossips the offline roster per login event instead of all of them at once, and the background roster re-broadcast drops from every 90 seconds to a 10-minute safety net. Same board, same offline visibility, a fraction of the data.", feature = "world_tools" },
                        { "World Buffs updates arrive faster with many characters online: your own fresh buff changes now jump the shared mesh send queue instead of waiting behind roster relays and config syncs, and the login-time relay burst is spread out so it can't clog things.", feature = "world_tools" },
                        { "World Buffs board: duplicate character rows are merged automatically on every login (case drift and bare-name/realm-name twins fold together, richest record wins) - no more cache wipes, so the board also stops starting empty and slowly refilling after updates.", feature = "world_tools" },
                        "Text reminders show a note icon instead of the red question mark, and a held step whose gear swap has landed moves on automatically - out of combat about a second after the swap, in combat right after the regen-edge worker equips it. Steps with a use-item still wait for the use.",
                        "Quick character swaps sync reliably now: logging out of one character and straight into another used to beat the login-sync timers, so data only flowed one way. The push fires fast enough to win that race in both directions.",
                        { "Notes filed under renamed profiles are recovered AUTOMATICALLY on login - no command needed. They're copied into your current profiles wherever those have no note of their own.", feature = "boss_notes" },
                        { "Renaming a raid profile now carries every boss and trash note with it - renames used to orphan notes under the old profile name, which read as deletion.", feature = "boss_notes" },
                        { "Fixed the real cause of vanishing notes: syncing between your characters was REPLACING the whole notes store, wiping any per-profile notes the sending character didn't have. Sync now merges notes additively - nothing local is ever deleted - so logging each character once restores the account to the union of everyone's notes. A one-time cleanup also removes the wrong Default-profile copies an earlier repair spread around, and rescues AQ20 notes stranded by the old migration.", feature = "boss_notes" },
                        { "Route tracker text is never cut off: lines WRAP within the tracker's width instead of truncating with '...'. Width comes from its slider (plus scale); height follows the wrapped content and the frame grows DOWNWARD only - the top edge stays pinned where you placed it. The height slider is gone because height takes care of itself.", feature = "raid_route" },
                        { "A route ENDING on a boss step now finishes properly: the checkpoint path used to skip the whole finish - no 'Route complete' line, no spoken alert, tracker just vanished. Both completion paths finish identically now.", feature = "raid_route" },
                        { "Boss checkpoint steps now get the same 2-second 'Done' hold that kill steps get - completing a boss step (pulled or killed, simmed or real) shows what just finished on the tracker's main line with the next gate underneath, instead of flipping instantly.", feature = "raid_route" },
                        { "New /rc notesdump command prints every stored boss and trash note key so note issues are diagnosable on the spot.", feature = "boss_notes" },
                        { "Route reminders live entirely inside the tracker now - one frame, one entry in /rc moveui. The separate reminder plaque under it is gone; test fires render in the same frame too.", feature = "raid_route" },
                        { "The Remote Raid Config page matches normal raid editing: pick the toon, then click a raid - each raid is a one-click row showing its fetch or local-copy status inline.", feature = "raid_configs" },
                        { "Naxxramas gargoyles are named correctly: Plagued Gargoyle in the Spider and Military wings, Stoneskin Gargoyle in the Plague wing. If a saved route step or trash note referenced the wrong one for its wing, re-pick the mob in the editor.", only = "era" },
                        "Switching between characters on one account now triggers a full sync in both directions every time, and the world buff roster arrives together with it.",
                    }
                },
            }
        },
        {
            version = "4.6.2",
            date = "2026-07-02",
            title = "Kill history & Darkmoon Faire accuracy",
            sections = {
                {
                    type = "added",
                    items = {
                        { "You can now add many kill times at once. Next to the add-kill box there's a new Bulk button that opens a window where you can paste a whole list of times - like 1:32 105 2:03 - separated by spaces, commas or new lines. It shows how many kills it found and their average before you commit, and one click records them all.", feature = "ttk" },
                        { "When adding kills by hand - one at a time or in bulk - you can now mark them as having the Darkmoon Faire damage buff so they count toward the right averages. The add-kill row has a small orb you can light up, and the bulk window has a matching checkbox.", feature = "ttk" },
                        { "Editing a recorded kill now lets you correct whether the Darkmoon Faire buff was active for that kill.", feature = "ttk" },
                        { "The kill data browser now labels its Darkmoon Faire column, so the small orb next to a kill clearly means the buff was up for it.", feature = "ttk" },
                    }
                },
                {
                    type = "changed",
                    items = {
                        { "Kill time predictions now respect the Darkmoon Faire buff everywhere. The on-screen kill timer, pace comparisons, reminders that fire based on remaining fight time, and boss simulations all prefer averages from kills with the same buff state you have now, falling back to all kills when there isn't enough matching data.", feature = "ttk" },
                    }
                },
                {
                    type = "fixed",
                    items = {
                        { "Old kill records that could no longer be matched to a raid and boss are now removed automatically instead of piling up. The 'Unrecognized Data' section is gone.", feature = "ttk" },
                    }
                },
            }
        },
        {
            version = "4.6.1",
            date = "2026-06-27",
            title = "Repair reminder, gear tooltips & fixes",
            sections = {
                {
                    type = "added",
                    items = {
                        "The gear set button now warns you when a set is missing gear. If you don't have everything a set needs (worn or sitting in your bags), its name turns red, and its tooltip marks each missing piece and shows a 'missing gear' note - so you can tell at a glance which sets you can fully equip.",
                        "Changing the size of the dockable gear buttons now shows a reminder that a UI reload is needed for the new size to take effect, with a Reload UI button right there so you can do it on the spot. It never reloads on its own.",
                        "When your gear durability gets low, a repair reminder now appears on screen - an anvil icon with a 'Repair' label, shown where your other reminders appear - instead of only a chat message. It flags a repair when your overall durability or any single piece of gear drops below the threshold you set, it checks when you log in and when you enter a raid, and it clears once you repair.",
                        "You can now turn tooltips on or off for the dockable gear buttons and their hover menus, with an option to show them only while you are out of combat. They are off by default.",
                    }
                },
                {
                    type = "changed",
                    items = {
                        "While you're in combat, a consumable's icon now disappears the moment you use it, so a consumable you've already used reads as spent and you won't waste a click trying to use it again. This covers everything on the bar - potions stay hidden while they're on cooldown, and flasks, elixirs and food (which have no cooldown) stay hidden until their buff drops or combat ends. Out of combat the bar always looks normal.",
                    }
                },
                {
                    type = "fixed",
                    items = {
                        "Fixed the Trinket bar moving to the wrong spot after a reload when you positioned it with the UI Mover. Dragging the bar directly already worked; the UI Mover now saves its position correctly too.",
                        "Fixed Mesh Network sync so that logging a character in while another of your characters is already online now reliably sends the online character's synced data to the one that just logged in. This previously failed when the online character still had the other flagged as connected, and it now also works when several of your characters are online at the same time.",
                        "Equipping a gear set that uses two of the same weapon - or two identical rings or trinkets - now puts one copy in each slot instead of trying to fit a single item into both.",
                        "Fixed a grey edge that could appear along the top and left of the dockable gear buttons at certain UI scales.",
                        "The hover menus on the dockable gear buttons now match the size of the buttons themselves.",
                        "When gear button tooltips are turned on, they now appear cleanly beside the hover menu instead of partly hidden behind it.",
                    }
                },
            }
        },
        {
            version = "4.6.0",
            date = "2026-06-19",
            title = "Weapon toggles & search fixes",
            sections = {
                {
                    type = "added",
                    items = {
                        "The Weapons bar now lets you turn each weapon on or off individually. Open the Weapons tab and click a weapon's icon to show or hide it. This works for both your equipped weapons and your sharpenable bag weapons, and the icons update on their own when your weapons change.",
                        "The Consumables bar now has the same per-weapon icons, so you can choose exactly which weapons it tracks.",
                    }
                },
                {
                    type = "changed",
                    items = {
                        "Bag weapons now show on the Weapons bar by default.",
                        "The search boxes inside settings panels now match the look of the main sidebar search.",
                    }
                },
                {
                    type = "fixed",
                    items = {
                        "The Consumables bar now applies your weapon stone or oil even when the Weapons bar's click action is set to Nothing.",
                        "The Consumables bar and Weapons bar now control their bag weapons separately. Turning bag weapons off on one bar no longer turns them off on the other.",
                        "Fixed a settings search box that could cause lag or leave the keyboard stuck until you reloaded.",
                        "Fixed a settings search box stealing the cursor from the main sidebar search while you were typing in it.",
                    }
                },
            }
        },
        {
            version = "4.5.9",
            date = "2026-06-15",
            title = "Weapon bar equipping & sidebar search upgrades",
            sections = {
                {
                    type = "added",
                    items = {
                        "The Consumables, Potions and Weapons bar lists, and the warrior talent list, now have a search box at the top so you can filter long lists by typing part of a name",
                        "Sidebar search now finds individual settings and options, not just pages - searching things like 'text to speech', 'reminder sound' or 'weapon detection' takes you straight to the right place",
                        "Equipment Reminder can now give a separate spoken alert for each gear type, such as a missing weapon enchant or the wrong weapon equipped, each with its own repeat setting",
                        "Weapon bar buttons can now equip weapons, not just apply stones to them. By default, shift-clicking your equipped main-hand or off-hand button moves that weapon to the other slot, and shift-clicking one of your bagged weapons equips it - and weapon swaps work even during combat",
                        "What each click on a weapon bar button does is now fully configurable - left, right, shift-click and ctrl-click can each be set to apply a stone, open the stone picker, equip to main hand, equip to off hand, or do nothing, from the Weapons bar settings",
                        "Added a macro builder under Hotswap that creates an equip-this-item-to-this-slot macro - type an item name, pick a slot, and it makes a macro you can drag onto an action bar or bind to a key",
                    }
                },
                {
                    type = "changed",
                    items = {
                        "The Settings menu now expands to list its pages when selected, the same as the other menu sections, and the window opens straight to General & Behavior instead of a welcome screen",
                        "What's New now has its own page in the sidebar",
                        "Sidebar search no longer floods with results - it shows the most relevant matches first and a hint to type more when there are too many to list",
                        "Removed a large amount of unused code under the hood to keep the addon leaner",
                        "Reminders now use a single clean fade in and out. The other animation styles (pulse, flash, glow, bounce, shake, grow and slide) have been retired - they kept animating the whole time a reminder was on screen, which could cost frames during busy fights. If you had one of those styles selected, it has been switched to fade automatically.",
                        "The animation style dropdown and the per-ability animation overrides have been removed. The Fade In Duration and Fade Out Duration sliders now live under the Behavior tab in Reminder Settings.",
                    }
                },
                {
                    type = "fixed",
                    items = {
                        "Holding Backspace in a search box now keeps deleting instead of stopping after one character",
                        "The Mesh Network password box now stays hidden behind dots when you click into it, and you can still highlight it and copy it with Ctrl+C without revealing it",
                        "Importing or exporting your settings now also includes your hotswap gear set and sidebar layout, which were previously left out",
                        "Spoken reminders set to repeat now play the correct number of times",
                        "Smoother framerate during big fights: sitting down to eat no longer makes every reminder bar do extra work each frame, the Battle Shout party check no longer re-reads tooltips every second, and the trinket swap queue only redraws when something actually changes.",
                        "The icons on the weapon bar no longer go blank after you swap a weapon during combat",
                    }
                },
            }
        },
        {
            version = "4.5.8",
            date = "2026-06-14",
            title = "OmniCC support & in-combat trinket queue",
            sections = {
                {
                    type = "added",
                    items = {
                        "OmniCC support - if you also run OmniCC (or a similar cooldown-number addon), Readycheck now detects it automatically and steps aside on its consumable, potion, weapon and trinket bars and on the dockable gear buttons, letting OmniCC show the countdown numbers there so they no longer double up. With no such addon installed, Readycheck shows its own numbers everywhere as before",
                        "Trinket Menu swaps can now be queued in combat - click a trinket while fighting and a small icon appears on the slot it will fill, then it equips automatically the moment you leave combat, the same way queued gear sets work",
                        "The Trinket Menu now has a toggle to hide the 1 and 2 slot numbers shown on your equipped trinkets, under its General Settings",
                    }
                },
                {
                    type = "changed",
                    items = {
                        "Sidebar search now finds the Mesh Network, World Buffs and Remote Raid Config pages by more terms, including things like 'stuck', 'cross-faction', 'buff board' and 'remote edit'",
                        "The Readycheck chat tag is now shown in gold without the surrounding brackets",
                    }
                },
            }
        },
        {
            version = "4.5.7",
            date = "2026-06-12",
            title = "Cross-faction world buffs",
            titles = { tbc = "Minor bug fixes", forever = "Minor bug fixes" },
            sections = {
                {
                    type = "added",
                    items = {
                        { "Cross-faction world buffs - your Alliance and Horde characters can now share world buff status with each other over Battle.net. Turn it on under Connections, add your other account or a Battle.net friend as a cross-faction peer, and their buffs (and yours) show up together in the World Buff Tracker, even across factions and while offline", feature = "world_tools" },
                    }
                },
                {
                    type = "fixed",
                    items = {
                        "Minor bug fixes and performance improvements",
                    }
                },
            }
        },
        {
            version = "4.5.6",
            date = "2026-06-05",
            title = "World Buff Tracker & gear override picker",
            titles = { tbc = "Gear override picker", forever = "Gear override picker" },
            sections = {
                {
                    type = "added",
                    items = {
                        { "World Buff Tracker - open /wb to see which world buffs you and your other characters currently have, including buffs frozen in a Chronoboon. It shows the time left on each, tracks where Songflowers were last picked, and reports your Chronoboon and Hearthstone cooldowns. Buff data is shared over the Mesh Network, so even characters that are offline still show their last-known buffs", feature = "world_tools" },
                        "The per-slot gear override picker now lists each copy of an item you are carrying, so duplicates like multiple Goblin Rocket Boots all show up instead of collapsing into a single icon",
                    }
                },
                {
                    type = "fixed",
                    items = {
                        "Minor bug fixes and performance improvements",
                    }
                },
            }
        },
        {
            version = "4.5.5",
            date = "2026-06-01",
            title = "Consumable reminder fixes & Smart Macro scoping",
            sections = {
                {
                    type = "added",
                    items = {
                        { "Nameplate Debuffs - see key debuffs and procs right on enemy nameplates: armor reduction (Sunder Armor, Expose Armor, Faerie Fire), Overpower availability, Execute range, and more. Fully customizable groups, icon sizes, positions, colors and timers. Turn it on and tune it under Nameplate Debuffs in the sidebar", feature = "nameplate_debuffs" },
                        "Smart Macros can now be limited to a specific raid - and to a specific raid profile within it - with the 'Active in' option. Give several Smart Macros the same in-game macro name, each scoped to a different raid or profile, and that one macro will do different things depending on where you are",
                        "A Smart Macro with an empty body now clears (blanks) the in-game macro when its rule fires - handy for switching a macro off while targeting something",
                        "Dropdown lists can now be filtered by typing - start typing while a dropdown is open to narrow it instead of scrolling, for example when picking a boss or a trigger type",
                    }
                },
                {
                    type = "fixed",
                    items = {
                        { "On-target and post-boss-death consumable reminders now appear correctly", feature = "raid_configs" },
                        "Consumable reminders no longer show up when the consumable is not in your bags",
                        "Consumable reminders no longer disappear before you have a chance to use the consumable",
                    }
                },
            }
        },
        {
            version = "4.5.4",
            date = "2026-05-24",
            title = "Smart Macros & racial reminders",
            sections = {
                {
                    type = "added",
                    items = {
                        "Smart Macros - create a macro that rewrites itself based on what you are targeting. Set rules for creature type or mob name and the macro updates automatically. Found in the sidebar",
                        { "Blood Fury (Orc) and Berserking (Troll) are now available as reminder abilities on every boss and trash tab, with full support for all trigger types (target HP%, TTK, combat start, buff remaining, etc.) - only visible to the matching race", feature = "raid_configs" },
                        { "Post-Boss Consumables - configure any consumable (Zanza potions, elixirs, food, buffs, etc.) to remind you to use it either after a boss dies or when you first target the boss. Found in the Utility section of each boss tab. Pick items from a category browser so the list stays manageable", feature = "raid_configs" },
                        "Food buffs and bandages are now tracked on the consumable bar - toggle them individually in the Items tab. They are also available on the potion bar but hidden by default",
                        { "Remote raid config editing - open any Mesh Network member in the Raids sidebar and click Edit Config to fetch their full raid setup, edit it directly (boss abilities, gear swaps, timers, notes, everything), then push your changes back to them. Works even if they are offline", feature = "raid_configs" },
                    }
                },
            }
        },
        {
            version = "4.5.3",
            date = "2026-05-21",
            title = "Consumable TTS repeat & gear swap fix",
            sections = {
                {
                    type = "added",
                    items = {
                        "Consumable bar items now have individual TTS and Repeat toggles in the Items tab - enable or disable each consumable independently",
                        "Consumable TTS can repeat after the buff expires - set how many times and how long after expiry in the Behavior tab",
                    }
                },
                {
                    type = "fixed",
                    items = {
                        "Mesh Network now shows separate sync options for Battle Shout reminder settings and the Battle Shout party tracker, so you can enable each independently",
                        { "Post-boss gear set no longer fails to swap when adds are still alive when the boss dies(hopefully)", feature = "boss_gear_kill" },
                    }
                },
            }
        },
        {
            version = "4.5.2",
            date = "2026-05-14",
            title = "Remote gear editing & fixes",
            sections = {
                {
                    type = "added",
                    items = {
                        "Remote gear editing - open Gear Manager > Remote tab to view and edit another warrior's gear sets directly, then push your changes to them when they log in",
                        "Deleting a gear set now asks whether to remove it locally or also queue the deletion for your other mesh warriors",
                    }
                },
            }
        },
        {
            version = "4.5.1",
            date = "2026-05-13",
            title = "Mesh Network",
            sections = {
                {
                    type = "added",
                    items = {
                        "Mesh Network - sync your Readycheck settings across multiple accounts or characters automatically. Set up a shared channel name and password and your raid configs, boss notes, gear sets, ML Predictions data, consumables, and more stay in sync in real time",
                        { "Boss Exclusions in ML Predictions - uncheck any boss to stop recording fight data for it. Per-raid tabs for MC, BWL, AQ40, and Naxx so you are not scrolling through a wall of checkboxes", feature = "ttk" },
                    }
                },
            }
        },
        {
            version = "4.5.0",
            date = "2026-05-06",
            title = "Bug fixes & improvements",
            sections = {
                {
                    type = "fixed",
                    items = {
                        "Fixed some buttons and colors not working right in the settings",
                        { "Fixed Fungal Bloom gear swaps not working correctly", only = "era" },
                        "Trinket auto-swapper no longer swaps off a ready trinket immediately after login or reload",
                    }
                },
                {
                    type = "added",
                    items = {
                        { "Raid profile selector now visible at the top of every boss tab (Abilities, Gear, History)", feature = "raid_configs" },
                        { "ML Predictions data tab now shows kills from all profiles combined", feature = "ttk" },
                        { "Kills in ML Predictions can now be clicked to edit the time and profile", feature = "ttk" },
                    }
                },
                {
                    type = "changed",
                    items = {
                        { "Kill history scrollbar only appears when there are more kills than fit on screen", feature = "ttk" },
                    }
                },
            }
        },
    }

    -- WHAT THIS GAME VERSION SEES (2026-11-12, Zac: "can the changelog
    -- only show relevant things for that version of the game"). The list
    -- every reader walks (the popup, the What's New page) is the history
    -- with the other game versions' lines taken out. Worked out once: the
    -- game version is fixed for the session by the time this runs.
    RC.Changelog.allVersions = RC.Changelog.versions
    function RC.Changelog.Relevant(item, flavor)
        if type(item) ~= "table" then return true end
        local f = item.feature
        if RC.FeatureOn then
            if type(f) == "string" then
                if not RC:FeatureOn(f) then return false end
            elseif type(f) == "table" then
                for _, id in ipairs(f) do
                    if not RC:FeatureOn(id) then return false end
                end
            end
        end
        local only = item.only
        if type(only) == "string" then
            return only == flavor
        elseif type(only) == "table" then
            for _, fl in ipairs(only) do
                if fl == flavor then return true end
            end
            return false
        end
        return true
    end
    function RC.Changelog:BuildShown()
        local flavor = (RC.Flavor and RC:Flavor()) or "era"
        local out = {}
        for _, v in ipairs(self.allVersions) do
            local secs = {}
            for _, sec in ipairs(v.sections or {}) do
                local items = {}
                for _, item in ipairs(sec.items or {}) do
                    if self.Relevant(item, flavor) then
                        items[#items + 1] = type(item) == "table" and item[1] or item
                    end
                end
                if #items > 0 then secs[#secs + 1] = { type = sec.type, items = items } end
            end
            if #secs > 0 then
                out[#out + 1] = { version = v.version, date = v.date,
                    title = (type(v.titles) == "table" and v.titles[flavor]) or v.title, sections = secs }
            end
        end
        self.versions = out
        return out
    end
    RC.Changelog:BuildShown()

    -- (the version running: from the history as written - a version with
    -- nothing for this game version is still the current one)
    function RC.Changelog:GetCurrentVersion()
        return self.allVersions[1] and self.allVersions[1].version or "Unknown"
    end

    function RC.Changelog:ShouldShowPopup()
        if not ReadycheckDB then return false end
        if not ReadycheckDB.account then
            ReadycheckDB.account = {}
        end

        local seenVersion = ReadycheckDB.account.lastSeenVersion
        local currentVersion = self:GetCurrentVersion()
        if seenVersion == currentVersion then return false end
        -- an update with nothing in it for this game version: seen, quietly
        local top = self.versions[1]
        if not (top and top.version == currentVersion) then
            ReadycheckDB.account.lastSeenVersion = currentVersion
            return false
        end
        return true
    end

    function RC.Changelog:MarkAsSeen()
        if not ReadycheckDB then return end
        if not ReadycheckDB.account then
            ReadycheckDB.account = {}
        end

        ReadycheckDB.account.lastSeenVersion = self:GetCurrentVersion()
    end

    function RC.Changelog:CreatePopup()
        if self.frame then
            return self.frame
        end

        local frame = CreateFrame("Frame", "ReadycheckChangelogFrame", UIParent)
        frame:SetSize(420, 400)
        frame:SetPoint("CENTER", 0, 50)
        frame:SetFrameStrata("DIALOG")
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame:SetClampedToScreen(true)
        frame:SetToplevel(true)
        RC.UI:RegisterEscapeClose(frame)

        frame:SetScript("OnMouseDown", function(self)
            self:Raise()
        end)

        frame:SetScript("OnShow", function(self)
            self:Raise()
        end)

        local windowBgColor = RC:GetColor("ui", "windowBackground")
        local headerBgColor = RC:GetColor("ui", "headerBackground")
        local accentColor = RC:GetColor("ui", "accentGold")
        local headerTextColor = RC:GetColor("ui", "headerText")

        -- Window shell: flat ui.windowBackground fill, 1px black ring.
        local FLAT = RC.UI.FLAT or "Interface\\Buttons\\WHITE8X8"
        local bg = frame:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(FLAT)
        bg:SetVertexColor(windowBgColor.r, windowBgColor.g, windowBgColor.b, windowBgColor.a or 0.95)

        if RC.UI and RC.UI.CreateSimpleBorder then
            frame.border = RC.UI:CreateSimpleBorder(frame)
        end

        -- 30px flat title bar with the single gold rule along its bottom.
        local titleBar = CreateFrame("Frame", nil, frame)
        titleBar:SetHeight(30)
        titleBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
        titleBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
        titleBar:EnableMouse(true)
        titleBar:RegisterForDrag("LeftButton")

        titleBar:SetScript("OnDragStart", function(self)
            frame:StartMoving()
        end)
        titleBar:SetScript("OnDragStop", function(self)
            frame:StopMovingOrSizing()
        end)
        titleBar:SetScript("OnMouseDown", function(self)
            frame:Raise()
        end)

        local titleBg = titleBar:CreateTexture(nil, "BACKGROUND")
        titleBg:SetAllPoints()
        titleBg:SetTexture(FLAT)
        titleBg:SetVertexColor(headerBgColor.r, headerBgColor.g, headerBgColor.b, 1)

        local titleAccent = titleBar:CreateTexture(nil, "ARTWORK")
        titleAccent:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 0, 0)
        titleAccent:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
        titleAccent:SetHeight(1)
        titleAccent:SetTexture(FLAT)
        titleAccent:SetVertexColor(accentColor.r, accentColor.g, accentColor.b, 0.6)

        local titleIcon = RC.UI:AddTitleIcon(titleBar, 16, 8)
        -- the header art every Readycheck window wears (gradient fill, the
        -- stepped accent rule); replaces the flat fill and the single rule
        if RC.UI.ApplyHeaderArt then
            titleAccent:Hide()
            RC.UI:ApplyHeaderArt(titleBar, { fill = titleBg, stepX = 160 })
        end

        local title = titleBar:CreateFontString(nil, "OVERLAY")
        title:SetPoint("LEFT", titleIcon, "RIGHT", 8, 0)
        RC:ApplyCustomFont(title, 15, "OUTLINE")
        title:SetTextColor(headerTextColor.r, headerTextColor.g, headerTextColor.b, 1)
        title:SetText("What's New")
        frame.title = title

        if RC.trackedFonts then
            table.insert(RC.trackedFonts, title)
        end

        local versionText = titleBar:CreateFontString(nil, "OVERLAY")
        versionText:SetPoint("RIGHT", -36, 0)
        RC:ApplyCustomFont(versionText, 11, "")
        versionText:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3], 1)
        versionText:SetText("v" .. self:GetCurrentVersion())
        frame.versionText = versionText

        if RC.trackedFonts then
            table.insert(RC.trackedFonts, versionText)
        end

        local closeBtn = RC.UI:CreateXCloseButton(titleBar, 22, function()
            RC.Changelog:Hide()
        end)
        closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -5, 0)

        local scrollFrame = CreateFrame("ScrollFrame", nil, frame)
        scrollFrame:SetPoint("TOPLEFT", 6, -36)
        scrollFrame:SetPoint("BOTTOMRIGHT", -22, 54)
        frame.scrollFrame = scrollFrame

        local content = CreateFrame("Frame", nil, scrollFrame)
        content:SetSize(scrollFrame:GetWidth(), 1)
        scrollFrame:SetScrollChild(content)
        frame.content = content

        -- Themed scrollbar (framework widget). The anchor frame reproduces
        -- the old gutter geometry: slider spans -38 (below title bar) to 42
        -- (above button area), hugging the frame's right edge.
        local sbAnchor = CreateFrame("Frame", nil, frame)
        sbAnchor:SetWidth(16)
        sbAnchor:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -3, -30)
        sbAnchor:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -3, 36)
        local scrollBar = RC.UI:AttachScrollbar(scrollFrame, sbAnchor)
        frame.scrollBar = scrollBar

        local buttonArea = CreateFrame("Frame", nil, frame)
        buttonArea:SetHeight(48)   -- (taller buttons, as ZacUI's Got it)
        buttonArea:SetPoint("BOTTOMLEFT", 0, 0)
        buttonArea:SetPoint("BOTTOMRIGHT", 0, 0)

        -- 1px black rule between the list and the footer buttons.
        local footerRule = buttonArea:CreateTexture(nil, "ARTWORK")
        footerRule:SetPoint("TOPLEFT", buttonArea, "TOPLEFT", 1, 0)
        footerRule:SetPoint("TOPRIGHT", buttonArea, "TOPRIGHT", -1, 0)
        footerRule:SetHeight(1)
        local ruleCol = RC:GetColor("ui", "borderNormal")
        footerRule:SetTexture(FLAT)
        footerRule:SetVertexColor(ruleCol.r, ruleCol.g, ruleCol.b, ruleCol.a or 1)

        local fullBtn = RC.UI:CreateStyledButton(buttonArea, "View Full Changelog", 170, 30)
        fullBtn:SetPoint("LEFT", 14, 0)
        fullBtn:SetScript("OnClick", function()
            -- Same cached frame, just repopulated in "all versions" mode -
            -- no Hide()/Show() round trip (that only caused a visible flash
            -- now that the popup is built once). MarkAsSeen still runs so
            -- the login popup does not reappear for this version.
            RC.Changelog:MarkAsSeen()
            RC.Changelog:Show(true)
        end)

        -- Primary action wears the active look.
        local okBtn = RC.UI:CreateStyledButton(buttonArea, "Got it", 130, 30)
        okBtn:SetPoint("RIGHT", -20, 0)
        okBtn:SetActive(true)
        okBtn:SetScript("OnClick", function()
            RC.Changelog:Hide()
        end)

        -- Framework resize grip; same bounds as before. Repopulating stays
        -- on mouse-up (as the old grip did) rather than every size tick.
        local resizeGrip = RC.UI:AttachResizeGrip(frame, {
            minW = 350, minH = 200, maxW = 600, maxH = 700,
        })
        resizeGrip:HookScript("OnMouseUp", function()
            -- Once the player has sized the window by hand, PopulateContent
            -- must stop applying its own 420xN auto-size or the frame would
            -- snap back the instant the grip is released.
            frame.userSized = true
            content:SetWidth(scrollFrame:GetWidth())
            RC.Changelog:PopulateContent(frame.showingAll)
        end)

        -- the 5.0 popup look (UIF_Dialogs)
        RC.UI:SkinPopup(frame, { fill = bg, header = titleBar, title = title, close = closeBtn,
            dims = { versionText }, rules = { footerRule }, buttons = { fullBtn }, primary = okBtn })
        -- (2026-11-09, Zac likes ZacUI's Got it: a raised plate, the
        -- primary one with the accent on its edge and label)
        RC.UI:StyleSettingsButton(fullBtn)
        RC.UI:StyleSettingsButton(okBtn)

        self.frame = frame
        return frame
    end

    -- Pooled row fontstrings: reused by index across repopulates, extras
    -- hidden. Each is created (and registered with trackedFonts) once.
    function RC.Changelog:AcquireLine()
        self.linePool = self.linePool or {}
        self.lineCount = (self.lineCount or 0) + 1
        local fs = self.linePool[self.lineCount]
        if not fs then
            fs = self.frame.content:CreateFontString(nil, "OVERLAY")
            if RC.trackedFonts then
                table.insert(RC.trackedFonts, fs)
            end
            self.linePool[self.lineCount] = fs
        end
        fs:ClearAllPoints()
        fs:Show()
        return fs
    end

    -- Pooled 1px rules drawn under each version header, reused by index
    -- like the line pool.
    function RC.Changelog:AcquireRule()
        self.rulePool = self.rulePool or {}
        self.ruleCount = (self.ruleCount or 0) + 1
        local tex = self.rulePool[self.ruleCount]
        if not tex then
            tex = self.frame.content:CreateTexture(nil, "ARTWORK")
            tex:SetTexture(RC.UI.FLAT or "Interface\\Buttons\\WHITE8X8")
            tex:SetHeight(1)
            self.rulePool[self.ruleCount] = tex
        end
        local c = RC:GetColor("ui", "borderNormal")
        tex:SetVertexColor(c.r, c.g, c.b, c.a or 1)
        tex:ClearAllPoints()
        tex:Show()
        return tex
    end

    function RC.Changelog:PopulateContent(showAll)
        local content = self.frame.content
        local scrollFrame = self.frame.scrollFrame

        self.frame.showingAll = showAll
        self.lineCount = 0
        self.ruleCount = 0
        self.linePool = self.linePool or {}
        self.rulePool = self.rulePool or {}

        local contentWidth = scrollFrame:GetWidth() - 4
        local yOffset = -8

        local versionsToShow = showAll and self.versions or { self.versions[1] }
        local sectionStyles = self.sectionStyles

        for i, versionData in ipairs(versionsToShow) do
            -- 12px gold version header with a 1px black rule beneath it.
            local versionHeader = self:AcquireLine()
            versionHeader:SetPoint("TOPLEFT", 4, yOffset)
            versionHeader:SetWidth(contentWidth - 8)
            RC:ApplyCustomFont(versionHeader, 12, "")
            local goldText = GetGoldText()
            versionHeader:SetTextColor(goldText.r, goldText.g, goldText.b, 1)
            versionHeader:SetJustifyH("LEFT")
            versionHeader:SetText(versionData.title or ("Version " .. versionData.version))

            local headerRule = self:AcquireRule()
            headerRule:SetPoint("TOPLEFT", content, "TOPLEFT", 4, yOffset - 16)
            headerRule:SetWidth(contentWidth - 8)

            yOffset = yOffset - 22

            if versionData.sections then
                for _, section in ipairs(versionData.sections) do
                    local style = sectionStyles[section.type]
                    local color = style and style.color or {0.7, 0.7, 0.7}
                    local label = style and style.label or section.type

                    local sectionHeader = self:AcquireLine()
                    sectionHeader:SetPoint("TOPLEFT", 4, yOffset)
                    sectionHeader:SetWidth(contentWidth - 8)
                    RC:ApplyCustomFont(sectionHeader, 11, "OUTLINE")
                    sectionHeader:SetTextColor(color[1], color[2], color[3], 1)
                    sectionHeader:SetJustifyH("LEFT")
                    sectionHeader:SetText(label)

                    yOffset = yOffset - 16

                    for _, item in ipairs(section.items) do
                        local itemText = self:AcquireLine()
                        itemText:SetPoint("TOPLEFT", 12, yOffset)
                        itemText:SetWidth(contentWidth - 16)
                        RC:ApplyCustomFont(itemText, 11, "")
                        local bodyCol = RC:GetColor("text", "normal")
                        itemText:SetTextColor(bodyCol.r, bodyCol.g, bodyCol.b, 1)
                        itemText:SetJustifyH("LEFT")
                        itemText:SetText("|cff666666-|r " .. item)

                        local textHeight = itemText:GetStringHeight() or 12
                        yOffset = yOffset - textHeight - 3
                    end

                    yOffset = yOffset - 6
                end
            end

            yOffset = yOffset - 10
        end

        for i = self.lineCount + 1, #self.linePool do
            self.linePool[i]:Hide()
        end
        for i = self.ruleCount + 1, #self.rulePool do
            self.rulePool[i]:Hide()
        end

        local contentHeight = math.abs(yOffset) + 10
        content:SetHeight(contentHeight)

        local scrollBar = self.frame.scrollBar
        if scrollFrame and scrollBar then
            scrollBar:SyncRange(contentHeight, scrollFrame:GetHeight())
            scrollBar:SetValue(0)
        end

        if not self.frame.userSized then
            local frameHeight = 30 + 6 + math.min(contentHeight, 400) + 6 + 36
            frameHeight = math.max(frameHeight, 250)
            frameHeight = math.min(frameHeight, 550)
            self.frame:SetSize(420, frameHeight)
        end
    end

    function RC.Changelog:Show(showAll)
        -- The popup is built once and cached; each open only repopulates
        -- the pooled content rows below.
        local frame = self:CreatePopup()

        if frame.title then
            frame.title:SetText(showAll and "Full Changelog" or "What's New")
        end

        if frame.versionText then
            if showAll then
                frame.versionText:SetText("")
            else
                frame.versionText:SetText("v" .. self:GetCurrentVersion())
            end
        end

        self:PopulateContent(showAll)
        frame:Raise()
        -- Pop in only on a real open; a repopulate while already visible
        -- (View Full Changelog) must not replay the animation.
        if frame:IsShown() then
            if frame.popAnimation then RC.UI:StopAnimations(frame) end
            frame:SetAlpha(1)
            frame:SetScale(1)
        else
            RC.UI:PopIn(frame, 0.12)
        end
    end

    function RC.Changelog:Hide()
        if self.frame and self.frame:IsShown() then
            self:MarkAsSeen()
            if self.frame.popAnimation then RC.UI:StopAnimations(self.frame) end
            RC.UI:PopOut(self.frame, 0.1)
        end
    end

    function RC.Changelog:Toggle()
        if self.frame and self.frame:IsShown() then
            self:Hide()
        else
            self:Show()
        end
    end

    function RC.Changelog:CheckOnLogin()
        -- SETUP2: a fresh install's first login has nothing to compare
        -- against (and the setup wizard is on screen): it only writes the
        -- version down, so the popup first shows after a real update.
        local t = ReadycheckDB and ReadycheckDB.tutorial
        local acct = ReadycheckDB and ReadycheckDB.account
        if type(t) == "table" and t.fresh and (type(acct) ~= "table" or acct.lastSeenVersion == nil) then
            self:MarkAsSeen()
            return
        end
        -- never on top of the setup: while it is up (or waiting out a
        -- fight) the popup holds back, and the setup's Finish counts the
        -- version as seen and names /rc changelog in its one line
        local function SetupBusy()
            local W = RC.SetupWizard
            return W and W.IsBusy and W:IsBusy() or false
        end
        if self:ShouldShowPopup() then
            C_Timer.After(3, function()
                if SetupBusy() then return end
                if not UnitAffectingCombat("player") then
                    self:Show()
                else
                    local combatWatcher = CreateFrame("Frame")
                    combatWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
                    combatWatcher:SetScript("OnEvent", function(f)
                        f:UnregisterAllEvents()
                        C_Timer.After(1, function()
                            if SetupBusy() or not RC.Changelog:ShouldShowPopup() then return end
                            RC.Changelog:Show()
                        end)
                    end)
                end
            end)
        end
    end

    RC.Changelog:CheckOnLogin()

    RC:DebugPrint("Changelog system initialized", "system")
end

InitializeChangelog()
