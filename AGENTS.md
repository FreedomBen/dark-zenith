# Repository Guidelines

## Agent Instructions

- Commit after making changes.

## Project Structure & Module Organization

This repository is currently design-first. The primary project contract lives in `DESIGN.md`; keep it aligned with any implementation decisions. `LICENSE` declares AGPL-3.0-or-later. No application source tree has been scaffolded yet.

The intended application is an Elixir/Phoenix RPM repository service. When implementation begins, prefer the conventional Phoenix layout: `lib/` for application and domain code, `lib/dark_zenith_web/` for controllers, LiveViews, components, and API endpoints, `priv/repo/migrations/` for database migrations, `test/` for ExUnit tests, and `assets/` for frontend code.

## Build, Test, and Development Commands

There are no runnable build or test commands in the repository yet. After the Phoenix app is introduced, expected commands should be documented here and in `README.md`, for example:

- `mix setup` - install dependencies, create the database, and run migrations.
- `mix phx.server` - run the local Phoenix server.
- `mix test` - run the ExUnit test suite.
- `mix format` - format Elixir source and configuration files.

Update this section whenever commands are added, renamed, or removed.

## Coding Style & Naming Conventions

Use standard Elixir formatting via `mix format` once code exists. Prefer clear domain names that match `DESIGN.md`, such as `Repository`, `Package`, `ApiKey`, and `CollaboratorInvitation`. Use snake_case for variables, functions, database columns, and migration names; use PascalCase for modules.

When writing shell scripts, interpolate variables with braces, for example `"${VAR}"`. If Makefiles are added, default `PREFIX` to `/usr/local` and keep `make help` accurate.

## Testing Guidelines

Write tests for every code change once a test framework exists. For Phoenix code, place tests under `test/` with filenames ending in `_test.exs`. Cover authorization, metadata generation, signed URL behavior, upload flows, and API error responses because these are core product contracts.

## Commit & Pull Request Guidelines

Recent history uses concise imperative commit subjects such as `Clarify repository design contract` and `Resolve design review findings in DESIGN.md`. Follow that style: describe the change directly, without `feat:` or `bug:` prefixes. Commit bodies should explain what changed and why when the subject is not enough. Do not add Claude co-author lines.

Pull requests should include a short summary, test results or an explanation when tests do not apply, linked issues when relevant, and screenshots for UI changes.

## Agent-Specific Instructions

Do not read `TODO.md` or other TODO files. Do not create or switch branches, commit, or push unless explicitly instructed. Always update documentation when code changes affect documented behavior.
