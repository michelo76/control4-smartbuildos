# SmartBuildOS Home Insights

Puts the Home Insights page on Control4 touchscreens and in the Control4 app for
iOS and Android. It is the window; the
[SmartBuildOS Connector](https://app.smartbuildos.io) is the sensor.

The page shows the homeowner five sections — **Overview, Rooms, Usage, Comfort,
System**. It is read-only and has no control of anything in the house.

## Installing

1. Add **SmartBuildOS Home Insights** to the project.
1. Get a Home Insights URL for this property. Either:
   - in SmartBuildOS, open the property → **Control4** → **Touchpanels**, or
   - in the **SmartBuildOS Connector** driver, run **Generate Touchpanel URL**
     and copy the value it writes into its own **Touchpanel URL** property.
1. Paste it into this driver's **URL** property.
1. Unhide the driver where it should appear. **This step is easy to miss:**
   WebView drivers are Experience Buttons and are **hidden from every room and
   every page by default**. Use the **Navigator** tab of Room View to show it in
   the rooms you want, under Watch, Listen, Comfort or Security.

The **Status** property says what the driver has actually done — whether a URL
was published, or why it was not. If a panel is blank, read Status first.

## The URL is a credential

Treat it like a password. It grants read access to this property's Home Insights
and nothing else — no control, no client name, no address, no IP addresses — but
anyone holding it can see what the house is doing.

Each URL is revocable on its own, so losing one panel does not mean re-doing the
others. Revoke and reissue in SmartBuildOS.

## Getting the URL automatically

**Get URL From Connector** asks the SmartBuildOS Connector in the same project
for a URL, so nobody has to copy a long token by hand.

This is **experimental and may do nothing**, depending on your Connector
version. It fails visibly rather than silently: if there is no answer, Status
says so and you paste the URL manually. That path always works.

## If the panel is slow to load

The page is served from the internet, so a cold load takes a moment. Control4's
guidance for this applies here: program the driver's **selection event** to fire
an Announcement, and set the Announcement to close a second or two before the
page normally appears.

## What it needs

- Control4 OS **3.0** or newer — WebView support starts there.
- Outbound HTTPS from the controller's network. **Nothing inbound**, and no
  ports to open on the client's firewall.

## Sizes

One page, three layouts, chosen by the screen it lands on:

| Surface                             | Layout                                    |
| ----------------------------------- | ----------------------------------------- |
| Control4 app, phone                 | Bottom tab bar, portrait                  |
| 5" touchscreens and short viewports | Compact rail, tightened spacing           |
| 7"/10" panels                       | Rail, standard                            |
| 1080p, 1200p and 4K panels          | Rail, scaled up for reading at a distance |

## Change log

- **1** — First release. Five sections, three layouts, URL published to the
  proxy on change and re-announced after a controller restart.
