---
id: TASK-2
title: Add optional Skip button and configurable strictness to break overlay
status: Done
assignee: []
created_date: '2026-11-23T16:18:00Z'
labels:
  - overlay
  - ux
milestone: m-0
dependencies: []
priority: high
type: feature
ordinal: 2000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Allow users to skip an active break (button and keyboard shortcut) when needed, with an optional skip delay or Strict Mode toggle to prevent reflex dismissals.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Break overlay displays a Skip action (button + Esc shortcut) when skipping is enabled
- [x] #2 Optional short button delay (e.g. 3s) or Strict Mode toggle prevents accidental skips
- [x] #3 Skipped breaks are recorded in local statistics and start a fresh work interval
<!-- AC:END -->
