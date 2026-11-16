# SmartBuildOS Home Insights

A web view: a button in a room's Navigator that opens one web page on Control4
touchscreens and in the Control4 app for iOS and Android. The driver does one
thing: it tells the screens which address to open. It controls nothing in the
house and has no programming.

## Read this first: there is no Home Insights page to show today

The driver was written to show the SmartBuildOS Home Insights page, a read-only
status page for one property. In November 2026 SmartBuildOS stopped serving that
page for touchscreens:

- The SmartBuildOS Agent (`smartbuildos.c4z`) no longer has **Touchpanel Name**,
  **Touchpanel URL** or *Generate Touchpanel URL*.
- SmartBuildOS no longer has a Touchpanels page, and an address issued before
  then no longer opens.
- This driver's *Get URL From Connector* action is removed. It asked the Agent
  for that address, and the Agent has none to give.

What is left is the web view itself. It opens the `https://` address you paste
into **URL**, and it works without the Agent.

## What it needs

- An `https://` address for the page to show. SmartBuildOS does not issue one.
- Control4 OS 3.0 or newer. Web views start there.
- Outbound HTTPS from the home's network to that page. Nothing inbound, and no
  ports to open on the client's firewall.

## What it is for

| You want                                  | Use                                             |
| ----------------------------------------- | ----------------------------------------------- |
| One web page as a button on a touchscreen | This driver, shown in the room's Navigator      |
| The same page in the Control4 app         | Nothing more: the button also opens in the app  |
| To know why a panel is blank              | **Status**                                      |
| The Home Insights page on a touchscreen   | Not available: SmartBuildOS no longer serves it |

## Setup

<!-- walkthrough: Put a page on a screen -->

1. Add SmartBuildOS Home Insights to the project.
1. Paste the page's address into this driver's **URL** property. **Status**
   reads `URL published (edited)` with the time.
1. Show the button where it should appear. This step is easy to miss: a web view
   is an experience button, and those are hidden from every room by default. Use
   the Navigator tab of the room to show it.
1. Open it on a screen.

## How it works

The driver hands the URL to the screens at four moments: when you edit **URL**,
when you run *Reload Now*, when the driver loads, and once more 60 seconds after
it loads. The last one is for a controller restart, when the first can be sent
before the project has finished starting.

The URL is checked before it is sent. It must begin with `https://`, then a host
name, then a `/`. Anything else is not sent, and **Status** says so instead of
leaving a blank panel to puzzle over.

The page comes from the internet, so the first load takes a moment.

## Treat the URL with care

- The **URL** property is not masked. Anyone who opens the project in Composer
  can read it.
- If the address alone gives access to something private, treat it like a
  password.

## Reading the status

| **Status**                                       | Meaning                                                               | What to do                                                                                                                                                                     |
| ------------------------------------------------ | --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `No URL set`                                     | **URL** is empty                                                      | Paste the URL                                                                                                                                                                  |
| `URL does not look right — expected https://…`   | The text is not a full `https://` address                             | Paste the whole URL, from `https://` to the end                                                                                                                                |
| `URL published (edited)` and a time              | Sent to the screens when you changed **URL**                          |                                                                                                                                                                                |
| `URL published (load)` or `(startup)` and a time | Sent when the driver loaded, or 60 seconds later                      |                                                                                                                                                                                |
| `URL published (manual)` and a time              | Sent by *Reload Now*                                                  |                                                                                                                                                                                |
| A line that mentions the Connector               | Left by *Get URL From Connector* in an earlier version of this driver | Nothing: it is replaced the next time the URL is sent                                                                                                                          |
| The URL is published and a panel is still blank  | The driver has done its part                                          | Check that the button is shown in that room, that the home has internet, and that the address opens in a browser. An address from the retired Touchpanels page no longer opens |

## Properties and actions

| Property                            | What it is                                    |
| ----------------------------------- | --------------------------------------------- |
| **Driver Name**, **Driver Version** | Identification                                |
| **URL**                             | The page's address. Empty until you paste one |
| **Status**                          | What the driver last did with the URL         |

| Action       | What it does                                   |
| ------------ | ---------------------------------------------- |
| *Reload Now* | Sends the current **URL** to the screens again |

In earlier versions of this driver *Reload Now* did nothing when run from the
Actions tab. That is repaired in this version.

## What is not claimed

- "Published" means the address was handed to the screens. The driver cannot
  tell whether a screen loaded the page.
- Which pages a Control4 screen will display. The driver passes on any
  `https://` address; whether a given page renders on a touchscreen is up to the
  screen.
- This manual describes what the driver's code does. It does not claim a bench
  confirmation.
