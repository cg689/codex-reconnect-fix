---
title: 'Harden cross-machine operation'
type: 'bugfix'
created: '2026-09-15'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '1c18b88539680b82d8d4d35584db657398e21989'
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The repair works on its original machine but can misdiagnose or damage another user's configuration when TOML syntax, proxy topology, Codex home, environment variables, or partial failures differ. Rollback also cannot currently guarantee restoration of the exact previous state.

**Approach:** Make Fix, Diagnose, Rollback, and their launchers share conservative input handling and truthful outcomes. Treat all writes as a recoverable transaction, preserve prior values exactly, and add isolated regression tests that never modify the developer's real Codex configuration or proxy settings.

## Boundaries & Constraints

**Always:** Support Windows PowerShell 5.1 and PowerShell 7; preserve existing public parameters and exit codes where possible; prefer refusing or reporting unverified over guessing; redact credentials from generated reports; keep tests isolated from real HKCU proxy state and user environment variables.

**Never:** Require administrator rights, install a persistent service, replace `model_provider`, silently overwrite complex corporate/PAC proxy routing, or claim health when a required probe was skipped or failed.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Standard repair | Default Codex home, live local HTTP proxy, ordinary TOML | Apply feature and selected proxy changes, create one unique backup | Any failed write restores earlier mutations |
| Environment-only repair | Existing user proxy variables | Save and later restore exact existence/value of each variable | Known-bad chain is refused unless Force |
| Complex configuration | Quoted TOML keys, table comments, inline comments, CRLF/LF | Update the logical feature without duplicate tables and retain unrelated content | Invalid/ambiguous TOML is refused before system mutation |
| Alternate proxy topology | ALL_PROXY, per-protocol ProxyServer, PAC/WPAD, non-common port | Diagnose the effective route conservatively; do not overwrite complex routing implicitly | Report unverified/problem instead of OK when route cannot be proven |
| Skipped/failed probes | SkipNetworkTest or failed proxied request | Never print healthy/OK; return a nonzero problem/unverified result | Explain which evidence is missing or failed |
| Rollback damage | Missing, malformed, or partial state.json | Do not claim complete rollback | Fail safely and state what was or was not restored |

</frozen-after-approval>

## Code Map

- `scripts/Fix-CodexReconnect.ps1` -- discovery, safety gate, backup schema, transactional writes, TOML update, environment persistence.
- `scripts/Diagnose-CodexReconnect.ps1` -- TOML/config route inspection, credential-safe reporting, live-probe verdict and exit code.
- `scripts/Rollback-CodexReconnect.ps1` -- backup validation and exact restoration with partial-failure handling.
- `Fix.cmd`, `Diagnose.cmd`, `Rollback.cmd` -- double-click trust boundary; unblock only the invoked target.
- `config/config.example.toml` -- safe merge guidance for an existing `[features]` table.
- `README.md`, `docs/03-常见问题.md`, `CHANGELOG.md` -- user-visible guarantees and limitations must match implementation.
- `tests/` -- new isolated regression suite for parsers, verdicts, transaction ordering, backup selection, environment restoration, and argument validation.

## Tasks & Acceptance

**Execution:**
- [x] `scripts/Fix-CodexReconnect.ps1` -- add parameter validation, CODEX_HOME resolution, safe TOML planning/atomic commit, unique mutation backups, exact prior environment state, all-write safety gate, and compensating rollback.
- [x] `scripts/Diagnose-CodexReconnect.ps1` -- align discovery and config parsing, recognize ALL_PROXY, redact proxy credentials, and make verdict depend on the route actually verified.
- [x] `scripts/Rollback-CodexReconnect.ps1` -- validate backup/state, select a real mutation backup, restore exact prior values, and never report full success after partial recovery.
- [x] `*.cmd` -- limit Unblock-File to the selected target script.
- [x] `tests/` -- add deterministic tests using temporary files and injectable/mocked state rather than real machine configuration.
- [x] `README.md`, `docs/03-常见问题.md`, `config/config.example.toml`, `CHANGELOG.md` -- document precise behavior, safe copying, and supported/unverified proxy modes.

**Acceptance Criteria:**
- Given any failure after the first mutation, when Fix exits, then all earlier mutations made by that invocation are restored or the output explicitly identifies an unrecovered surface.
- Given pre-existing user proxy variables, when Fix and Rollback complete, then each variable has its exact original value and existence state.
- Given skipped or failed network probes, when Diagnose renders its verdict, then it cannot emit `VERDICT: OK` or exit healthy.
- Given supported legal TOML forms, when Fix enables the feature, then the resulting file parses logically with one effective key and no duplicate feature table.
- Given a report containing credential-bearing proxy URLs, when it is printed or written, then userinfo and other credential material are not exposed.
- Given the full automated suite, when run under available PowerShell editions, then it passes without touching the real Codex home, HKCU Internet Settings, or user environment variables.

## Implementation Notes

## Spec Change Log

## Review Triage Log

## Design Notes

The safest architecture is to separate pure planning from side effects: parse current state, compute the intended config and state manifest, validate both, then commit mutations in a tracked order. Fix and Diagnose should reuse the same pure helpers so their port/config interpretation cannot drift. Backward-compatible rollback should understand old backups conservatively, while new backups record schema version, exact previous values, completed mutations, and whether the run changed anything.

## Verification

**Commands:**
- `powershell -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile(...)"` -- expected: zero parse errors for all scripts.
- `Invoke-Pester` or the repository's dependency-free test runner -- expected: all isolated cases pass.
- `git diff --check` -- expected: no whitespace errors.
