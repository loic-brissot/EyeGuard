---
id: TASK-4
title: Meeting / call auto-pause
status: To Do
assignee: []
created_date: '2026-11-23T16:18:00Z'
updated_date: '2026-11-23T16:31:00Z'
labels:
  - smart-pause
milestone: m-1
dependencies: []
priority: high
type: feature
ordinal: 4000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Automatically detect active meetings/calls (via microphone input activity and/or call-app rules) to defer breaks until the call ends, with an app exclusion list to avoid false positives.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Breaks automatically pause while an audio input device is active in a meeting/call
- [ ] #2 Users can exclude specific non-meeting apps that use the microphone
- [ ] #3 Menu bar shows the active pause reason and resumes cleanly after the call ends
<!-- AC:END -->
