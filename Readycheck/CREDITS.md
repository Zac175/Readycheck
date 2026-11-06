# Readycheck — credits

Readycheck is written by Zac. Every Lua file in the Readycheck folders is
Readycheck's own code, except the libraries listed below, which are
bundled unchanged under their own licences.

## Libraries (in `Readycheck\Libs`)

| Library | Author(s) | Licence | Used for |
|---|---|---|---|
| LibStub | Kaelten, Cladhaire, ckknight, Mikk, Ammo, Nevcairiel | Public domain | Lets several addons share one copy of a library |
| CallbackHandler-1.0 | the Ace3 team (Nevcairiel and others) | see wowace.com/projects/callbackhandler | Events for the libraries below |
| LibSharedMedia-3.0 | Elkano | LGPL v2.1 | Sharing fonts, sounds and bar textures with other addons |
| LibDataBroker-1.1 | Tekkub | Public domain | The minimap button's data object |
| LibDBIcon-1.0 | the LibDBIcon authors | see curseforge.com/wow/addons/libdbicon-1-0 | The minimap button, so button-bag addons can collect it |
| LibSerialize | Ross Nichols | MIT (notice kept in the file) | Packing settings and sync messages |
| LibDeflate | Haoqian He (SafeteeWoW) | zlib (notice kept in the file) | Compressing exported strings and sync messages |

The full licence text of each library stays in its own file.

## Media

- **Font** — Red Hat Display SemiBold, © The Red Hat Project Authors,
  SIL Open Font License 1.1. Licence text: `Media\Fonts\OFL.txt`.
- **Sounds** (`Media\Sounds`) — notification sound effects chosen for
  Readycheck; they were not made for it and belong to their creators.
- **Textures** (`Media\*.tga`) — made for Readycheck.
- **Gear previews** (`Media\GearPreviews`) — pictures of Readycheck's own
  equipment window; the item icons in them are the game's
  (© Blizzard Entertainment).
- Icons shown in Readycheck's windows are drawn from the game's own files
  at run time and belong to Blizzard Entertainment.

## Designs and protocols

- **World buff timers.** The guild timer network Readycheck can listen
  to and share with speaks the message format designed by **Venomisto**
  for *Nova World Buffs*, so Readycheck users and Nova World Buffs users
  can exchange timers. Readycheck's implementation is its own; no Nova
  World Buffs code is bundled.

World of Warcraft and Blizzard Entertainment are trademarks of Blizzard
Entertainment, Inc. Readycheck is not affiliated with Blizzard.
