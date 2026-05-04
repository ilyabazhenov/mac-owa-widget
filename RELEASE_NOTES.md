## What's Changed

- Default meeting reminder lead time is 1 minute (still configurable in Settings).
- Meeting reminder scheduling uses a shared delay calculation for both system notifications and in-app banners; fixes missed reminders when sync runs inside the lead window.
- Optional in-app floating reminder banner (Settings → Notifications → reminder style: system, in-app, or both).
- OWA: if `GetCalendarView` fails with HTTP 500 "Cannot create an abstract class" while reusing an existing session, the client re-authenticates once and retries with the existing startup retry policy.
- Popover footer shows the app version string for support and release checks.
- Tests: `MeetingReminderScheduleTests` cover reminder delay edge cases.
