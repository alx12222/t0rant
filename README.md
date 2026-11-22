# t0rant

A Windows-style terminal for iPhone and iPad, with Python, Node.js and pip/npm built in.

## Features
- **Windows-style command prompt**: `dir`, `cd`, `copy`, `del`, `type`, `findstr`, pipes, `&&`, `>`, `%VAR%`, plus `.bat` scripts with `if`, `for` and `goto`
- **Unix tools**: `ls`, `cat`, `grep`, `head`, `tail`, `cut`, `tr`, `uniq`, `du`, `df`, `jq`, `zip`/`unzip`
- **Python 3.13** with `pip`, plus packages like requests, numpy and cryptography
- **Node.js 18** with `npm`, `npx` and `npm install -g`
- **Network tools**: `ping`, `curl`, `nslookup`, `portscan`, `whois`, `dig`, `headers`, `sslcheck`
- **Files tab** for browsing, editing, importing and sharing files
- **Settings tab** for themes, colors, font size and user name
- Your session is saved and restored when you reopen the app

## Requirements
- iOS 15.0 or later
- A sideloading tool (Sideloadly, AltStore or TrollStore)

## Limitations
iOS doesn't let apps run native binaries, WebAssembly or other programs (like git). npm and pip packages that depend on these won't fully work.
