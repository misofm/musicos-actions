# Protocol Actions

## Sui Development Skills

Install community-maintained skills for Sui development:

```sh
npx skills https://github.com/MystenLabs/skills
```

## Official Resources

Use the Sui documentation MCP server at `https://sui.mcp.kapa.ai` when available. When unsure, verify against official sources rather than guessing or extrapolating from other blockchains:

- Move Book: https://move-book.com (use https://move-book.com/llms.txt)
- Sui Docs: https://docs.sui.io (use https://docs.sui.io/llms.txt)
- Sui Move examples: https://github.com/MystenLabs/sui/tree/main/examples/move

## Project Structure

- `release_revenue_distributor/` — Release revenue routing actions.

Each directory is an independently publishable Move 2024 package.

## Project Rules

- Keep actions custody-agnostic: accept raw protocol admin caps and never depend on Vault in production.
- Use composable `public fun` APIs, return created objects and released principal, and do not add `entry` wrappers.
- Preserve canonical parent derivations and validate every supplied Recording, pool, and routed stake.
- Do not add witnesses, installation state, plugin APIs, or convenience sharing wrappers.
- Pin every git dependency to a full immutable commit SHA. Vault is test-only.
- Use Move 2024 method syntax/macros, numeric `EPascalCase` errors, and past-tense event names ending in `Event`.
- Run `sui move build`, `sui move test --coverage`, and inspect production source coverage in every package.
