# SmartBuildOS Home Insights

Puts the Home Insights page on Control4 touchscreens and in the Control4 app
for iOS and Android. It is a web view: a button in a room's Navigator that
opens one web page, the read-only status page SmartBuildOS serves for this
property. This driver is the window; the SmartBuildOS Agent is the sensor.

The Agent (`smartbuildos.c4z`, whose own manual is titled SmartBuildOS
Connector) collects what the page shows and issues the page's address. This
driver does one thing: it tells the screens which address to open. It controls
nothing in the house and has no programming.

## What it needs

- A Home Insights URL for this property. It comes from a paired SmartBuildOS
  Agent in the project, or from SmartBuildOS itself.
- Control4 OS 3.0 or newer. Web views start there.
- Outbound HTTPS from the home's network. Nothing inbound, and no ports to
  open on the client's firewall.

## What it is for

| You want | Use |
| --- | --- |
| The homeowner to see what is playing, the temperatures and the system's health on a touchscreen | This driver, shown in the room's Navigator |
| The same page in the Control4 app | Nothing more: the button also opens in the app |
| A separate address for each panel, so one can be withdrawn without the others | One URL per panel from the Agent's *Generate Touchpanel URL* |
| To know why a panel is blank | **Status** |

## Setup

<!-- walkthrough: Put Home Insights on a screen -->
1. Install and pair the SmartBuildOS Agent, if the project does not have it.
1. Add SmartBuildOS Home Insights to the project.
1. Get a URL. In the Agent's properties, type a label for this panel in
   **Touchpanel Name**, run *Generate Touchpanel URL* and copy the value it
   writes into **Touchpanel URL**. Or, in SmartBuildOS, open the property, then
   Control4, then Touchpanels.
1. Paste it into this driver's **URL** property. **Status** reads
   `URL published (edited)` with the time.
1. Show the button where it should appear. This step is easy to miss: a web
   view is an experience button, and those are hidden from every room by
   default. Use the Navigator tab of the room to show it.
1. Open it on a screen.

## How it works

The driver hands the URL to the screens at three moments: when you edit
**URL**, when the driver loads, and once more 60 seconds after it loads. The
last one is for a controller restart, when the first can be sent before the
project has finished starting.

The URL is checked before it is sent. It must begin with `https://`, then a
host name, then a `/`. Anything else is not sent, and **Status** says so
instead of leaving a blank panel to puzzle over.

The page comes from the internet, so the first load takes a moment. As
SmartBuildOS serves it at the time of writing, it has five sections (Overview,
Rooms, Usage, Comfort, System) and three layouts chosen by the screen it lands
on. Both belong to the page and can change without a driver update.

| Surface | Layout |
| --- | --- |
| Control4 app on a phone | Bottom tab bar, portrait |
| 5-inch touchscreens and short viewports | Compact rail, tightened spacing |
| 7-inch and 10-inch panels | Rail, standard |
| 1080p, 1200p and 4K panels | Rail, scaled up for reading at a distance |

## The URL is a credential

Treat it like a password. It gives read access to this property's Home Insights
page and nothing else: no control of the house. Anyone holding it can see what
the house is doing.

- The **URL** property is not masked. Anyone who opens the project in Composer
  can read it.
- Each run of the Agent's *Generate Touchpanel URL* makes a new URL and leaves
  the earlier ones working, so each panel can have its own.
- A URL is withdrawn in SmartBuildOS, one at a time. Losing one panel does not
  mean redoing the others.

## Reading the status

| **Status** | Meaning | What to do |
| --- | --- | --- |
| `No URL set` | **URL** is empty | Paste the URL |
| `URL does not look right — expected https://…` | The text is not a full `https://` address | Paste the whole URL, from `https://` to the end |
| `URL published (edited)` and a time | Sent to the screens when you changed **URL** | |
| `URL published (load)` or `(startup)` and a time | Sent when the driver loaded, or 60 seconds later | |
| A line that mentions the Connector | Left by *Get URL From Connector*: no URL was obtained | Paste the URL by hand |
| The URL is published and a panel is still blank | The driver has done its part | Check that the button is shown in that room, that the home has internet, and that the URL has not been withdrawn in SmartBuildOS |

## Properties and actions

| Property | What it is |
| --- | --- |
| **Driver Name**, **Driver Version** | Identification |
| **URL** | The page's address. Empty until you paste one |
| **Status** | What the driver last did with the URL |

The Actions tab lists *Get URL From Connector* and *Reload Now*. Neither does
anything in this build: the driver does not yet read actions in the form
Composer sends them.

- *Get URL From Connector* is meant to ask the Agent for a URL so nobody copies
  one by hand. The Agent has no reply for that request in this release either.
  Paste the URL.
- *Reload Now* is meant to send the URL to the screens again. To do that today,
  clear **URL** and paste the address back.

## What is not claimed

- The driver shows a page; it does not produce what is on it. If the Agent is
  not paired or not reporting, the page has nothing new to show.
- "Published" means the address was handed to the screens. The driver cannot
  tell whether a screen loaded the page.
- What the page contains and how it is laid out is described from the previous
  manual, not from this driver's code.
- This manual describes what the driver's code does. It does not claim a bench
  confirmation.
