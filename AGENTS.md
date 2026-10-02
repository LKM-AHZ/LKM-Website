# Repository Guidelines

## Project Structure & Module Organization

This root repository owns local orchestration, `docker-compose.yml`, deployment assets in `deploy/`, and cross-project documentation. The application directories are independent Git submodules:

- `LKM-official-website/`: Astro SSR frontend; application code in `src/`, static files in `public/`, and browser tests in `tests/e2e/`.
- `LKM-service/`: FastAPI backend; business modules in `app/`, authentication in `auth/`, shared code in `core/`, migrations in `alembic/` and `alembic_auth/`, and tests in `tests/`.
- `LKM-bot/`: Python bot in `astrbot/`, dashboard in `dashboard/`, and tests in `tests/`.
- `LKM-on-VSCode/`: TypeScript extension in `src/`, with tests in `test/` and assets in `resources/`.

Make code changes and commits in the owning submodule. Check its own `AGENTS.md` when present; update the root submodule pointer separately.

## Build, Test, and Development Commands

Run `git submodule update --init --recursive` after cloning. From the root, `./dev.sh` installs dependencies and starts the frontend and backend; `./dev.sh --no-run` only installs them. `docker compose config` validates the full stack configuration before deployment.

Run checks from the relevant submodule:

- Frontend: `pnpm check && pnpm test && pnpm build`.
- Backend: `uv run pytest && uv run ty check && uv run ruff check && uv run python scripts/check_raw_sql.py`.
- Bot: `python -m pytest`.
- VS Code extension: `pnpm run compile && pnpm test`.

## Coding Style & Testing Guidelines

Use four spaces and `snake_case` for Python; backend Ruff uses an 88-character line limit. The frontend uses two spaces, ESLint, and Prettier. Follow existing TypeScript naming patterns (`camelCase` functions, `PascalCase` components). Name Python tests `test_*.py`; frontend browser tests use `*.spec.ts`. Add focused regression tests for behavior changes. Backend `pytest` excludes `integration` tests by default; database tests require PostgreSQL. No repository-wide coverage threshold is documented.

## Commit & Pull Request Guidelines

Recent root commits use short Chinese change summaries, without an enforced prefix. Use a specific subject that names the change. Commit submodule work in that repository first, then commit its updated pointer in the root. A pull request should explain the change, list checks run and results, link an issue when applicable, and call out migrations or configuration changes. Include screenshots for visible UI changes.

## Security & Configuration

Use `.env.example` as a template. Never commit `.env`, private keys, tokens, or database backups. Review `DEVELOPMENT.md` for local setup and `DEPLOYMENT.md` before production changes.
