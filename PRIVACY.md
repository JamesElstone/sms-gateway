<!--
Copyright (c) 2026, James Elstone
SPDX-License-Identifier: BSD-3-Clause

This file is part of SMS Gateway:
https://github.com/JamesElstone/sms-gateway

See LICENSE for details.
-->
# Privacy and Backup Notes

SMS Gateway stores received SMS messages in a local database so API reads are
fast and independent per token. Treat this database as sensitive production
data.

## What Is Stored

The SMS cache stores message sender, content, modem timestamps, cache
timestamps, per-token read acknowledgements, modem metadata, and the raw decoded
modem payload. Messages remain in SQLite even after every enabled token has
read them and even after the modem copy is deleted.

## Access Risk

SMS messages can contain account recovery codes, personal data, service
notifications, and phone numbers. Anyone who can read the database file, system
backups, copied support bundles, or database dumps can read cached SMS content.

Protect:

- `config/tokens.json`
- `config/local.php`
- the SQLite database file
- `/var/log/sms-gateway/read.log`
- `/var/log/sms-gateway/send.log`
- filesystem and VM backups containing those files
- logs or diagnostics that include API responses

## File Permissions

On FreeBSD, prefer a persistent database path outside the web document flow,
for example:

```text
/var/db/sms-gateway/sms-gateway.sqlite3
```

The directory should be writable only by the service user that runs PHP, for
example `www:www` with mode `0750`. The database file should not be world
readable.

## Backups

Back up the SQLite database if SMS history and per-token read state matter.
Losing the database loses:

- cached messages already removed from the LTE modem
- per-token read logs
- modem deletion tracking

Use SQLite's backup tooling or stop the poller briefly before copying the file.
For example:

```sh
sqlite3 /var/db/sms-gateway/sms-gateway.sqlite3 ".backup '/secure/backup/sms-gateway.sqlite3'"
```

Store backups with the same sensitivity as the live database. Encrypt backups
when they leave the host or are kept on shared storage.

## Retention

The current default is to keep cached SMS messages indefinitely. Modem cleanup
only removes copies from the LTE device; it does not remove rows from SQLite.
If legal, operational, or privacy requirements demand expiry, add an explicit
retention policy before relying on this service for long-term message capture.

## Token Read Logs

Each enabled token has an independent read log keyed by token `name`. Replacing
a token secret while keeping the same token name keeps that read history. Adding
a new enabled token makes existing cached messages unread for that token.

## Service Text Logs

On FreeBSD, the rc.d service prepares `/var/log/sms-gateway/read.log` and
`/var/log/sms-gateway/send.log` as `www:www 0640`. `read.log` records token
names, client IPs, read modes, counts, and message IDs. `send.log` records token
names, client IPs, destination numbers, statuses, and URL-encoded SMS payloads.
Treat these logs and their rotated archives as sensitive message data.
