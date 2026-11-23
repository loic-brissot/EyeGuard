---
id: TASK-9
title: Idle & natural break detection
status: Done
assignee: []
created_date: '2026-11-23T16:18:00Z'
updated_date: '2026-11-23T19:20:00Z'
labels:
  - smart-pause
milestone: m-1
dependencies: []
priority: medium
type: feature
ordinal: 9000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Detect passive user inactivity (via CGEventSource idle time) when the Mac stays unlocked, pausing the work timer and crediting qualifying away time as a natural break.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Configurable idle threshold to pause the countdown and reset after a qualifying natural break
- [x] #2 Respects video/fullscreen rules so passive watching is not mistakenly credited as stepping away
- [x] #3 Unit tests cover idle pause, natural break credit, and resume edge cases
<!-- AC:END -->
