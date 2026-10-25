# pickle_dealerships v1.2.6

## Fixes

- Use server-owned employee sale offers and NPC sessions and validate transaction inputs.
- Check payments and vehicle ownership writes, serialize mutations and protect auction stock.
- Settle auctions transactionally and retain offline refund credits and delivery receipts.
- Verify delivery rigs and nearby vehicle ownership for trade-ins and seizures.
- Restrict private management data, repossession exports, staffing changes and routing bucket entry.
- Improve conversion receipts and ID maps, catalog group migration and framework compatibility.

## Upgrade notes

- Allow trusted repossession resources in ServerConfig.RepoResources.
- Receipt and credit tables are created at startup. Inspect interrupted pending conversion receipts before retrying imports.
- Credits left in paying state and interrupted vehicle ownership/stock transfers may require operator reconciliation.
- Society payment adapters must confirm debit success; unconfirmed debits fail closed.

## Package and validation

- The ZIP contains one pickle_dealerships/ folder with the complete resource, installation files, license and runtime NUI assets where applicable. Unbuilt web/ sources, node_modules/ and Git metadata are excluded.
- Required local NUI scripts and stylesheets were checked before packaging. Prior remediation validation passed targeted mocked regressions and Lua/JavaScript syntax checks; this is not a live FiveM integration test.
- Test the resource with your installed frameworks, inventory, database and other integrations before use. Transactions spanning framework persistence, SQL and local KVP still have crash-recovery boundaries.

Source: [audit remediation PR #6](https://github.com/PickleModsCommunity/pickle_dealerships/pull/6), branch `fix/audit-remediation`. This release includes the PR changes without merging the PR.
