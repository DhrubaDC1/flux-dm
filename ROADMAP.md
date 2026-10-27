# Measurable implementation roadmap

`[x]` completed; `[ ]` pending. A roadmap entry is not a compatibility claim.

## M0: behavior specification

- [x] Pin the reference version so comparisons are reproducible.
- [x] Catalogue the reference dialogs, menus and user workflows.
- [x] Study reference segmentation and HTTP range-request behavior.
- [x] Write a confidence-labelled functional specification and architecture decision.
- [ ] Capture current-version live main/add/progress/options/scheduler workflows
  and traffic on Windows. Compare actual enabled states, defaults and transitions.

## M1: usable foreground download core

- [x] Real HTTP(S) streaming, fixed parallel ranges and sequential fallback.
- [x] Pause/resume, persisted partials and restart recovery with validators.
- [x] Strict range/length/encoding validation and bounded transient retries.
- [x] Queue concurrency, immediate/deferred downloads, stop/resume controls.
- [x] Collision-safe output, portable Unicode filenames and publication recovery.
- [x] Adaptive desktop/mobile UI with Add URL -> file info -> now/later,
  sortable list, categories/search, progress/segments, options and main queue.
- [x] Independent real-HTTP tests proving exact bytes and failure behavior.
- [ ] Native runtime smoke on every target OS/device. Linux passes
  `tool/linux_smoke.sh`; see live status of the others in CLAUDE.md.

Exit gate: clean static analysis, all meaningful core/widget tests pass, and
download/pause/reopen/resume/complete/delete workflows pass on each claimed OS.
This milestone alone does not meet full-product success criteria.

## M2: engine and queue fidelity

- [ ] Dynamic splitting/rebalancing matching shipped segmentation documentation.
  Prove faster completion on a controlled origin with deliberately uneven ranges,
  zero gaps/overlaps and exact output through pause/crash boundaries.
- [ ] Named download/synchronization queues, drag ordering/membership and distinct
  completion semantics. Test failed-item requeue, 30-second fallback/retry caps.
- [ ] Once/daily queue schedules with independent stop time and weekday boundaries;
  manual stop must suppress completion actions. Use a controllable clock in tests.
- [ ] Per-file/global speed limits, per-host connection limits, rolling quotas.
  Measure throughput within a documented tolerance without exceeding host caps.
- [ ] Duplicate choices, category-specific save paths and refresh-expired-address
  workflow. Verify destination changes cannot overwrite unrelated user files.
- [ ] Batch URLs, text import/export, clipboard capture and configurable policies.

## M3: native background operation

- [ ] Android foreground execution, notification actions, process recovery, scoped
  storage export and share receiver. Verify under screen-off and process death.
- [ ] iOS background URLSession, Files export/share, suspension and relaunch event
  reconciliation on a physical device. Expose OS-imposed transfer differences.
- [ ] macOS folder bookmarks, tray/menu integrations, desktop notifications and
  clean exit behavior on all desktop hosts.
- [ ] Platform capability tests: unsupported actions must be absent or explained,
  never silently do nothing.

## M4: advanced protocols and capture

- [ ] HTTP authentication/header/cookie/referer workflows and secure secrets;
  origin-change redirect and proxy credential-isolation tests.
- [ ] HTTP/SOCKS proxies and protocol adapters only where observable behavior
  can be established and covered by controlled-origin integration tests.
- [ ] Independently authored browser extension and mobile share integration.
  Test opt-in capture, exclusions, duplicate handling and malformed inputs.
- [ ] Bounded site grabber with crawl/depth/domain/path/size policies, saved
  projects, selection and scheduling; test cycles, redirects and robots policy.
- [ ] Supported non-protected media discovery/assembly with explicit format and
  site coverage. No DRM, licensing or access-control mechanisms are cloned.

## M5: production gate

- [ ] Reference comparisons for every supported workflow/default/edge case.
- [ ] Power-loss/process-kill fault injection at every persistence/assembly phase,
  manifest backup/migration, disk-full/unwritable folder and large-file tests.
- [ ] Profile throughput, memory and UI responsiveness against documented targets;
  isolate CPU-heavy verification only if measurements justify it.
- [ ] Keyboard navigation, screen readers, scaling, localization and dark mode.
- [ ] Reproducible signed packaging, installers, upgrade/rollback and release CI
  for Windows/Linux/macOS/Android/iOS. Apple distribution requires Apple tooling.
- [ ] Privacy, dependency/license and publication checks; third-party binaries
  and assets must remain outside all release artifacts.

Only completion of these platform and fidelity gates supports a claim of a
production-quality, high-fidelity five-platform replacement.
