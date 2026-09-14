# Pick List Tracker — Auto-Loaded Project Context

At the start of every session in this workspace, automatically read the two project
context files before doing any work:

1. Read `AGENTS.md` — architecture map, file structure, business rules, navigation flow.
2. Read `CONTEXT.md` — domain glossary, session lifecycle, status colours, column aliases.

Treat them as the single source of truth for all architecture, naming, and business logic
decisions. Do not duplicate what is already documented there.

## Quick Reference

- **Default admin PIN:** `1234`
- **Max units:** 40 (FIFO auto-prune on #41)
- **Session ID format:** `SESS-YYYYMMDD-INITIALS-SEQ`
- **FIFO scope:** always per Department — never cross-department
- **Backup rule:** always create `[name]_backup.xlsx` before overwriting
- **No Docker/external services** — pure Flutter + SQLite (WAL mode), offline-first
- **DB access:** always via `DatabaseService` — never raw SQLite from UI widgets
- **State management:** manual `setState` + constructor injection (no Provider/Riverpod)
- **Language:** all code comments and UI text in **English**
