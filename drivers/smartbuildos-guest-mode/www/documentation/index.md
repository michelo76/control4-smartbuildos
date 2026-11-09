# SmartBuildOS Guest Mode

Turns the booking calendars a short-let host already has into Control4
automation. Paste the iCal feed URLs from Airbnb, Booking.com or VRBO and the
driver knows who is in, who arrives today and when turnover is due, as
Composer events, variables and conditionals. Guests never see it; the dealer
programs the house around it: unlock and warm up before check-in, switch off
and lock after check-out, tell the cleaner when turnover is due.

Requires the SmartBuildOS Agent (`smartbuildos.c4z`) paired to a SmartBuildOS
system. The Agent is the licensing authority (SKU `SBOS_GUEST_MODE`);
**License Status** shows this driver's standing.

## Setup

1. Install and pair the SmartBuildOS Agent.
1. Add this driver (one per rental unit). Paste up to three **Calendar URL**s
   (the "export calendar" link of each platform).
1. Set **Check-in Time** and **Check-out Time** as the listing states them.
   All-day bookings become stays from check-in time on the arrival day to
   check-out time on the departure day.
1. Program the events: *Guest Arriving Today*, *Guest Checked In*, *Guest
   Checked Out*, *Turnover Due*, *Property Vacant*.

## Behaviour

- **Status** is one of `vacant`, `arriving_today`, `occupied`,
  `departing_today`, `turnover`. Conditionals *A guest is checked in*, *A
  guest arrives today* and *Turnover is due* read it.
- **Turnover** lasts **Turnover Window** hours after a check-out, or until the
  next check-in when a guest arrives the same day.
- **Blocked dates** ("Not available", "Blocked", owner stays, maintenance) are
  not guests. **Blocked Dates** = *Count As Occupied* treats them as a stay
  named Blocked.
- **Overlaps and back-to-back stays** never double check-in: a new booking
  while one is in progress is a check-out followed by a check-in.
- **Manual control.** *Check In Now* (walk-in or early arrival; open-ended
  until *Check Out Now* or the next calendar stay) and *Check Out Now* (an
  early departure stays departed; the turnover follows). *Clear Manual
  Override* forgets both.
- **Calendars** are polled every **Poll Interval** minutes. When every
  calendar fails, *Calendar Unreachable* fires once and the last good data
  stays in force; *Calendar Recovered* follows the next success.
- **Restart safe.** The last state is persisted; a Director restart replays
  no event.

## Guest PIN and Wi-Fi

With **Guest PIN** = *Per Stay*, a fresh code (**PIN Length** digits, never a
run or a repeat) is generated at each check-in and cleared at check-out:
variable `GUEST_PIN`, events *Guest PIN Changed* / *Guest PIN Cleared*. **The
driver never programs a lock.** Wire those two events to the lock driver's
own user-code programming in Composer. `GUEST_WIFI_PASSWORD` is whatever
*Set Guest Wi-Fi Password* last set, for a welcome screen or announcement.

## What is NOT claimed

- Times in a feed with a `TZID` are taken as controller-local; `Z` times are
  converted. Platforms publish all-day bookings, so this rarely matters.
- Guest names appear only when the platform includes them (Airbnb says
  "Reserved", shown as "Guest").
- No lock, no Wi-Fi controller and no platform API is written to.

## Actions

| Action | What it does |
| --- | --- |
| Poll Calendars Now | Load every calendar now |
| Print Stays | Every stay with its check-in / check-out instants |
| Print Guest Status | Status, licence, calendars, current and next stay |
| Regenerate Guest PIN | A new code now (fires Guest PIN Changed) |
| Clear Manual Override | Forget Check In Now / Check Out Now |

## Programming

- Commands: Check In Now (NAME), Check Out Now, Set Guest Wi-Fi Password
  (PASSWORD), Regenerate PIN, Poll Calendars.
- Variables: `GUEST_STATUS`, `GUEST_NAME`, `NEXT_CHECKIN`, `NEXT_CHECKOUT`,
  `GUEST_PIN`, `GUEST_WIFI_PASSWORD`, `STAYS_NEXT_30_DAYS`, `GUEST_PRESENT`,
  `CALENDARS_OK`, `LAST_ERROR`.

## Privacy

Calendar URLs are credentials: keep them in this driver only. Guest names
and descriptions from the feeds stay on the controller; nothing is uploaded.
The PIN and Wi-Fi password are stored encrypted and never logged.
