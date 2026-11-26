# Meio TSM Browse

For TradeSkillMaster: categories beside the Browse tab, like the standard auction house.

For WoW Forever. Recipe tooltips work as soon as it's installed; the category panel needs
a small TSM patch (see "TSM patch" below).

![Cloth hats up to your level in TSM's Browse tab: before, the filter typed by hand in TSM's
syntax; with MeioTSMBrowse, the same results from clicking Up to me and Armor > Cloth > Head
in the category tree beside it](docs/before-after.png)

## What it does

Click Recipe > Tailoring or Armor > Cloth > Head and TSM searches it, no filter syntax to
type. Recipe tooltips tell you whether you can learn a recipe and how long it gives skill-ups.

- **My professions** at the top of the tree, with your skill
- Required level: **Any**, **Up to me**, **Near me**, or type a range
- **Usable only**, **Recipes I can learn**, **Recipes that give skill-ups**
- Recipe tooltips anywhere in the game; hold Shift for the estimated orange / yellow /
  green / grey points

![Tailoring patterns in TSM's Browse tab: hovering Pattern: Shadow Hood shows "Learnable:
skill-ups until ~185 (you: 151)" and, with Shift, the orange, yellow, green and grey
points](docs/recipe-in-tsm.png)

Settings: Esc > Options > AddOns > MeioTSMBrowse.

## Commands

- `/tsmbrowse`: the list of commands, and whether TSM is patched
- `/tsmbrowse on`, `/tsmbrowse off`: show or hide the category panel
- `/tsmbrowse near <n>`: Near me starts n levels below yours (default 5)
- `/tsmbrowse span <n>`: skill points from a recipe's required skill to grey (default 50)
- `/tsmbrowse settings`: the Settings panel

## TSM patch (for the category panel)

TSM's Browse tab has no way for another addon to start a search, so the category panel needs
one small TSM patch; the recipe tooltips work without it. This repository's installer adds
it:

1. Install PowerShell 7: `winget install Microsoft.PowerShell` in a terminal.
2. Download [this repository](https://github.com/MeioNeiz/MeioTSMBrowse) (green **Code** button,
   **Download ZIP**) and extract it.
3. Close WoW, open a terminal in that folder and run
   `pwsh -ExecutionPolicy Bypass -File mods.ps1`
   (add `-AddOns "<your _forever_\Interface\AddOns folder>"` if WoW is installed elsewhere).
4. Start WoW; `/tsmbrowse` says whether TSM is patched.

The installer copies the addon, edits only the two TSM files the patch names
(`patches\14-tsm-browse-hooks.patch`, every new line marked `LOCAL FIX`), keeps a backup of
each in `backups\`, and changes nothing if TSM's code has moved on. Without MeioTSMBrowse the
patched TSM behaves exactly as before. A TSM update undoes the patch: run the installer
again (MeioTSMBrowse reminds you at login). To undo it:
`pwsh -ExecutionPolicy Bypass -File mods.ps1 revert 14-tsm-browse-hooks`, or reinstall TSM.

Skill-up points are estimates (the game has no colour data for recipes you haven't learned).
Made and tested on an English client with TradeSkillMaster v4.15.9.

## Install

You need [TradeSkillMaster](https://tradeskillmaster.com). Use your addon manager (CurseForge,
Wago), or unzip a GitHub release into `World of Warcraft\_forever_\Interface\AddOns` and
restart WoW fully; then add the TSM patch above for the category panel.

## Feedback

Bugs, ideas or just a thumbs up: leave a comment on the CurseForge or Wago page you got it from. [GitHub issues](https://github.com/MeioNeiz/MeioTSMBrowse/issues) are welcome too.

## More Meio addons

[Meio Trainer Compare](https://www.curseforge.com/wow/addons/trainercompare) | [Meio Next Stop](https://www.curseforge.com/wow/addons/leavebutton) | [Meio Auto Rank](https://www.curseforge.com/wow/addons/meio-autorank) | [Meio Meter Hover](https://www.curseforge.com/wow/addons/meterhover) | [Meio Map](https://addons.wago.io/addons/meiomap) | [Meio Alts](https://addons.wago.io/addons/meioalts) | [Meio DPS](https://addons.wago.io/addons/meiodps) | [Meio Nameplates](https://addons.wago.io/addons/meioplates) | [Meio Hub](https://addons.wago.io/addons/meiohub) | [Meio Pets](https://addons.wago.io/addons/meiopets) | [Meio Stats](https://addons.wago.io/addons/meiostats) | [Meio Bags](https://addons.wago.io/addons/meiobags) | [Meio Fixes](https://addons.wago.io/addons/meiofixes) | [Meio Flight Times](https://addons.wago.io/addons/meioflighttimes) | [Meio Tooltips](https://addons.wago.io/addons/meiotooltipfold) | [Meio Autorun](https://addons.wago.io/addons/meioautorunturn) | [Meio Mail](https://addons.wago.io/addons/meiomail) | [Meio QoL](https://addons.wago.io/addons/meioqol) | [Meio Shards](https://addons.wago.io/addons/meioshards) | [Meionomics](https://www.curseforge.com/wow/addons/meionomics) | [Meio Spike Check](https://addons.wago.io/addons/meiospikecheck) | [Meio BiS Extras](https://addons.wago.io/addons/meiobisextras) | [Meio Buff Thanks](https://addons.wago.io/addons/meiobuffthanks) | [Meio Flare Fixes](https://addons.wago.io/addons/meioflarefixes) | [Meio Flare Questie](https://addons.wago.io/addons/meioflarequestie)

## Licence

[MIT](LICENSE)
