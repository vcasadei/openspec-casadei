# Tasks

<!-- Each group lands its own tests and docs before the next group builds on
     it. There is no separate Tests or Documentation group: put a group's test
     and doc tasks inside that group. A group whose work calls for neither,
     such as scaffolding or dependency setup, carries neither.
     Every task states how to verify it: a test, a command, an observable
     behavior, or a delivered artifact. -->

## 1. <!-- Task Group Name -->

- [ ] 1.1 <!-- Task description and how it is verified -->
- [ ] 1.2 <!-- Task description and how it is verified -->
<!-- Not optional for a feature or fix: at least one automated test (unit,
     integration, or contract), mapped to the BDD scenario it covers. -->
- [ ] 1.3 <!-- Test covering scenario: <scenario name> -->
<!-- Delete if this group alters no behavior, configuration, or public
     interface. Same commit/MR as the code; PT-BR by default; tables and
     technical specs over prose. -->
- [ ] 1.4 <!-- Update /docs/<file>.md for what this group changed -->

## 2. <!-- Task Group Name -->

- [ ] 2.1 <!-- Task description and how it is verified -->
- [ ] 2.2 <!-- Test covering scenario: <scenario name> -->
- [ ] 2.3 <!-- Update /docs/<file>.md for what this group changed -->

## 3. Migration

<!-- Delete this group if the change alters no database schema. Order it by
     dependency - usually before the groups whose code reads the new shape.
     One task per expand-and-contract step, each verified here, plus
     rollback verification. -->
- [ ] 3.1 <!-- Expand: add new shape, dual-write; verify old and new readers both work -->
- [ ] 3.2 <!-- Migrate existing data; verify row counts / invariants -->
- [ ] 3.3 <!-- Contract: drop old shape; verify nothing still reads it -->
- [ ] 3.4 <!-- Run the `down` migration and verify it restores the prior shape -->

## 4. Quality Gates

<!-- Whole-branch integration checks only - never tests or docs an earlier
     group owed. Name the project's actual commands rather than describing
     them. -->
- [ ] 4.1 <!-- Build compiles cleanly: <command> -->
- [ ] 4.2 <!-- Linter and static analysis pass: <command> -->
- [ ] 4.3 <!-- Strict type checking passes: <command> -->
- [ ] 4.4 <!-- Coverage threshold is maintained or raised: <command> -->
