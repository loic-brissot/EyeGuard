---
id: TASK-1
title: Rebrand Swift package, bundle metadata, and build scripts to EyeGuard
status: To Do
assignee: []
created_date: '2026-11-23T16:18:00Z'
labels:
  - foundation
  - rebrand
milestone: m-0
dependencies: []
priority: high
type: chore
ordinal: 1000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Rename Package.swift targets, executable, Info.plist bundle ID/name, Makefile, verification scripts, and Application Support data directory from TwentyGuard to EyeGuard.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Package.swift defines EyeGuardCore and EyeGuard targets
- [ ] #2 Info.plist uses EyeGuard bundle name and bundle identifier
- [ ] #3 make test, make test-lifecycle, and make dmg pass with EyeGuard.app and EyeGuard-v*.dmg
<!-- AC:END -->
