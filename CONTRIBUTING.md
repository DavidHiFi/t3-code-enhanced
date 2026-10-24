# Contributing to T3 Code Enhanced

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

[Open an issue](https://github.com/DavidHiFi/t3-code-enhanced/issues/new) and include:

- what you did, what you expected and what happened instead
- your T3 Code version (the version badge in the sidebar shows it after the channel label)
- the last lines of `%LOCALAPPDATA%\T3CodeEnhanced\guard.log`
- the patcher output: `pwsh -File "%LOCALAPPDATA%\T3CodeEnhanced\lib\patch-server-asar.ps1" -Status` (and the same for `patch-app-asar.ps1`)

## Suggesting a feature

Open an issue that describes what you want to do and why. A screenshot or a mock-up helps.

## Sending a pull request

1. Fork the repo and create a branch from `main`.
2. Clone with `--recurse-submodules` so `upstream/` is checked out, and test against copies of your own asar files, never your live install:

   ```
   pwsh -File src/lib/patch-server-asar.ps1 -Status -AsarPath C:\temp\server.asar -ConfigPath src/addons/local-patches.json -BackupDir C:\temp\backups
   ```

3. Run `node --check` on every add-on file you changed, and keep every patch the same length as the code it replaces. The patchers refuse differently sized edits by design.
4. Keep each pull request to one change, and say in the description how you tested it.

Style: tabs for indentation in the add-on scripts, and keep the header comments in each file current. Patches live in `src/lib/patch-*.ps1`; anything that cannot be a same-length edit belongs in an add-on under `src/addons`.

## License

By contributing, you agree that your work is released under this repo's [MIT license](LICENSE).
