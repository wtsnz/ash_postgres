<!--
SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# Locked reads and related data

Use a row lock inside a transaction to coordinate operations on the same record.
AshPostgres accepts `:for_update`, or strings such as `"FOR NO KEY UPDATE"`,
`"FOR UPDATE NOWAIT"`, and `"FOR UPDATE SKIP LOCKED"`. It locks the root table
with `OF <root>`. Related rows used by joins and aggregates are not locked.

## A lock does not refresh the statement's snapshot

At PostgreSQL's default READ COMMITTED isolation level, each statement gets a
snapshot when it starts. A locking read can wait for another transaction. After
that transaction commits, PostgreSQL can lock and return an updated version of
the root row, but it does not take a new snapshot for the rest of the statement.

Aggregates loaded in that read, including `sum`, `count`, `exists`, `first`, and
`list`, can miss related rows committed during the wait. Expression calculations
that use aggregates or relationships have the same limit. Correlated subqueries
and a lock-first CTE still use the same statement snapshot.

For example, a locked order read can return `refunded: 0` even though the transaction
it waited for committed a refund of 30. An ordinary relationship load is issued
after the base read, so its separate statement can see that refund.

## Lock first, then load

When a check needs values committed by the transaction that held the lock, load
them in a second statement inside the same transaction:

```elixir
MyApp.Repo.transaction(fn ->
  order = Ash.get!(Order, order_id, lock: :for_update)
  order = Ash.load!(order, [:refunded, :refund_count, :refundable])

  # Check the fresh values and perform the operation before this transaction ends.
  order
end)
```

Use a read action that does not add these loads to the first statement. An action's
preparations can add loads even when the caller does not pass `load:`. Preserve
the actor, authorization options, tenant, and `as_of` on both operations when they
are part of the read's meaning.

All operations that can change the value being checked must follow the same
locking protocol. A root row lock does not generally prevent changes to related
rows. `FOR NO KEY UPDATE` also allows foreign-key inserts that `FOR UPDATE` would
block, so neither should replace an explicit protocol for the business rule.

## Recheck related-row filters after locking

A condition such as `refunded < total`, or `not exists(refunds, true)`, is also
evaluated using the locking statement's snapshot. Even if PostgreSQL rechecks the
condition after a concurrent update to the root row, related values can stay stale.

For a known order, lock it by primary key first, then load and check the condition,
or run a second read with that primary key and the condition. Loading fresh values
does not recheck the first read's filter by itself. This also applies to the locked
re-read of an AshOban trigger whose `where` condition references related data.

A general query needs a separate selection policy. Rerunning it after locking can
choose different, unlocked rows when filters or sorts change. Restricting the
second read to locked primary keys avoids that problem, but it can shrink pages
and does not discover rows excluded by the first snapshot.

## Other lock modes and isolation levels

`NOWAIT` reports a lock conflict instead of waiting. `SKIP LOCKED` omits conflicting
rows. They do not provide a fresher snapshot of related data.

At REPEATABLE READ or SERIALIZABLE, the second statement retains the transaction's
snapshot. An actual concurrent update to a locked row can cause a serialization
failure, but waiting for a transaction that only locked the row need not do so.
SERIALIZABLE can protect a read-and-write business rule when the participating
transactions use it and the application retries the entire transaction on `40001`.
It does not guarantee fresh aggregate values after every lock wait.

See PostgreSQL's [transaction isolation documentation](https://www.postgresql.org/docs/current/transaction-iso.html),
[SELECT locking clauses](https://www.postgresql.org/docs/current/sql-select.html#SQL-FOR-UPDATE-SHARE),
and [row security race example](https://www.postgresql.org/docs/current/ddl-rowsecurity.html).
