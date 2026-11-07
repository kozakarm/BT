# Repository Guidelines

## Project Structure & Module Organization

This repository contains standalone Bash utilities for Linux backup and recovery:

- `dir-tools/`: archive the current directory to `/root/<directory>.tar.gz` and restore an archive into the current directory, preserving ownership, ACLs, and extended attributes.
- `incus/`: export node configurations and instance images, and synchronize instance backups with Btrfs snapshot retention.
- `urbackup/`: contains `run-after-urbackup.sh` for UrBackup integration.
- `docker/`: currently empty.

Keep new utilities in the directory matching their operational purpose. There are no dedicated test or asset directories.

## Build, Test, and Development Commands

There is no compilation step or package manager. Validate readable scripts without executing backup operations:

```bash
for f in dir-tools/*.sh incus/*.sh; do bash -n "$f" || break; done
```

Run `bash -n path/to/script.sh` for each additional changed script. If ShellCheck is installed, run `shellcheck path/to/script.sh`; it is an optional review tool, not configured repository tooling.

Operational examples, from the directory being backed up or restored:

```bash
sudo bash /path/to/BT/dir-tools/full-dir-backup2root-dir.sh
sudo bash /path/to/BT/dir-tools/full-tar.gz-restore2current-dir.sh /root/example.tar.gz
```

Directory tools require GNU tar and `pigz`. Incus utilities require a configured Incus installation; synchronization also uses `jq`, Btrfs tools, `flock`, and `timeout`.

## Coding Style & Naming Conventions

Use Bash and descriptive, hyphenated `.sh` filenames. Match the surrounding indentation: existing scripts use two or four spaces. Keep configuration variables near the top, use uppercase configuration names and descriptive function names, and quote path and argument expansions. Preserve each script's error-handling behavior deliberately; strict mode differs between utilities. Existing comments and operational messages are primarily Russian.

## Testing Guidelines

No automated test framework or coverage threshold exists. Check syntax, then exercise changed behavior using disposable directories or isolated Incus instances. Verify archive restoration, metadata preservation, failure recovery, and the original instance running state where applicable. Never use production backups as test fixtures.

## Commit & Pull Request Guidelines

There are no commits yet, so no established message convention exists. Use concise imperative subjects, such as `Fix Incus export failure recovery`. Pull requests should explain the affected utility, operational impact, dependencies, validation performed, and any changes to paths, retention, or downtime.

## Operational Configuration

Review hardcoded nodes, projects, storage paths, exclusions, and retention before execution. Scripts may stop instances, overwrite archives, or delete backup snapshots. Keep generated backups, configuration dumps, and credentials out of version control.
