---
id: TASK-8
title: Pause during Apple Calendar events
status: To Do
assignee: []
created_date: '2026-11-23T16:18:00Z'
labels:
  - smart-pause
  - calendar
  - lookaway-inspired
  - timeout-inspired
milestone: m-1
dependencies: []
priority: medium
type: feature
ordinal: 8000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Integrate with Apple Calendar (EventKit) to automatically pause or skip breaks during ongoing busy events across user-selected calendars.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Users can grant Calendar access and select which calendars/accounts to monitor
- [ ] #2 Breaks automatically pause during active non-all-day busy events (configurable skip vs postpone)
- [ ] #3 Unit tests cover overlapping events, all-day filtering, and calendar permission denied states
<!-- AC:END -->
