---
id: TASK-7
title: Screen recording / sharing detection
status: To Do
assignee: []
created_date: '2026-11-23T16:18:00Z'
labels:
  - smart-pause
  - lookaway-inspired
milestone: m-1
dependencies: []
priority: high
type: feature
ordinal: 7000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Automatically pause breaks when screen sharing or screen recording is active so break overlays never cover a live presentation or recording.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Detects active screen sharing/recording sessions on macOS and defers due breaks
- [ ] #2 Displays pause status in the menu bar and resumes once capture stops
- [ ] #3 Gracefully degrades if required macOS permissions are not granted
<!-- AC:END -->
