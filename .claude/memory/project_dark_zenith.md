---
name: Dark Zenith Project
description: Core project context - Elixir/Phoenix RPM repository application with admin UI, API, and public package browser
type: project
---

Dark Zenith is an Elixir/Phoenix app that serves as a fully-functional RPM package repository.

**Why:** The user wants a self-hosted RPM repo solution with a modern web stack, supporting upload/management via admin UI and API, and serving standard repodata to dnf/yum/zypper clients.

**How to apply:** All work in this repo revolves around building this application. Key tech choices: Phoenix + LiveView (admin), Oban (background jobs), PostgreSQL, local/S3 storage, pure-Elixir RPM header parsing. Product design is documented in PRODUCT_DESIGN.md at the repo root.
