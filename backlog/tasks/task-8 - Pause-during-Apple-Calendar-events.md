---
id: TASK-8
title: Pause during Apple Calendar events
status: Done
assignee: []
created_date: '2026-11-23T16:18:00Z'
updated_date: '2026-11-23T19:15:00Z'
labels:
  - smart-pause
  - calendar
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
- [x] #1 Users can grant Calendar access and select which calendars/accounts to monitor
- [x] #2 Breaks automatically pause during active non-all-day busy events (configurable skip vs postpone)
- [x] #3 Unit tests cover overlapping events, all-day filtering, and calendar permission denied states
<!-- AC:END -->
