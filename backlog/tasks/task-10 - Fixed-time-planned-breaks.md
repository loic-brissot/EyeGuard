---
id: TASK-10
title: Fixed-time / planned breaks
status: To Do
assignee: []
created_date: '2026-11-23T16:18:00Z'
updated_date: '2026-11-23T16:31:00Z'
labels:
  - scheduling
milestone: m-2
dependencies: []
priority: medium
type: feature
ordinal: 10000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Support scheduling named breaks at fixed times of day (e.g. lunch, afternoon walk, end-of-day pause) that run alongside interval breaks and respect Smart Pause rules.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Users can create, edit, enable/disable named breaks with fixed start time, duration, and weekdays
- [ ] #2 Suppresses overlapping regular interval breaks around a planned break window
- [ ] #3 Respects Smart Pause (defers if busy in a meeting) and credits away time during the window
<!-- AC:END -->
