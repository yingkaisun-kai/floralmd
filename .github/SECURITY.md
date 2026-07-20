<!-- Modified from Edmund by Yingkai Sun for FloralMD. -->
# Security Policy

## Supported Versions

Only the latest stable release of FloralMD is supported with security fixes.

| Version | Supported |
| ------- | --------- |
| latest  | ✅ |
| older   | ❌ |

## Reporting a Vulnerability

Please report security vulnerabilities privately using GitHub's
[private vulnerability reporting](https://github.com/yingkaisun-kai/floralmd/security/advisories/new)
(Security tab → "Report a vulnerability"). Do not open a public issue for
suspected vulnerabilities.

Include as much detail as you can: affected version, reproduction steps,
impact, and any proof-of-concept. You should get an initial response within
7 days.

Since FloralMD is a local, offline-first macOS app (no server, no accounts, no
telemetry), the main risk areas are:

- Malicious Markdown/HTML content leading to code execution, sandbox escape,
  or unintended network access when opening a file
- Sparkle auto-update integrity (signature/verification bypass)
- Arbitrary file read/write outside the file the user opened

If confirmed, a fix will be released and credited in the release notes
(unless you prefer to stay anonymous).

## Disclosure

Please give a reasonable amount of time to fix an issue before any public
disclosure. There is no bug bounty program.
