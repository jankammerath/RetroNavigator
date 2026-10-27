# RetroNavigator

A Netscape Navigator clone for macOS with support for Wayback Machine, Gopher and WAP, packed in the classic MacOS window style.

Browse today's web — or travel back to the web of 1999 — in a faithful recreation of Netscape Navigator 4 running in a Mac OS 9 Platinum window.

<p align="center">
  <a href="https://github.com/jankammerath/RetroNavigator/releases/latest/download/RetroNavigator.zip">
    <img src="https://img.shields.io/badge/Download-RetroNavigator%20for%20macOS-0B5FFF?style=for-the-badge&logo=apple&logoColor=white" alt="Download RetroNavigator for macOS" height="56">
  </a>
  <br>
  <sub><a href="https://github.com/jankammerath/RetroNavigator/releases">All releases</a> · Requires macOS 27 or later</sub>
</p>

![RetroNavigator showing Google in 1999](/Screenshots/screenshot1.png)

## Features

- **Classic Mac OS look** — a pixel-faithful Platinum window with pinstriped title bar, close, zoom and collapse (window shade) boxes, grow box and square corners.
- **Netscape Navigator 4 interface** — Back, Forward, Reload, Home, Print and Stop buttons, the animated "N" throbber, the Location bar and collapsible toolbars, just like Navigator on the Mac.
- **Classic scroll bars and status bar** — Platinum scroll bars with the arrows together at the bottom, and a status bar with loading progress ("Connect: Contacting host…", "Document: Done").
- **Wayback Machine time travel** — pick any date since 1996 and browse the web as it was on that day, served straight from [archive.org](https://web.archive.org) without the archive's banner.
- **Gopher support** — open `gopher://` addresses with Navigator-style menus, text documents and searchable indexes.
- **WAP support** — open mobile WAP pages like `wap.yahoo.de` or `wap.web.de` from 2001–2005 on an emulated phone screen, with WML, WMLScript and WBMP images.
- **Vintage preferences dialog** — set your home page and the time travel date in a Mac OS 9 style movable modal dialog.

## Download and install

1. **[Download RetroNavigator.zip](https://github.com/jankammerath/RetroNavigator/releases/latest/download/RetroNavigator.zip)** (latest release).
2. Double-click the downloaded zip file to unpack it.
3. Drag **RetroNavigator.app** into your **Applications** folder.
4. Open RetroNavigator from your Applications folder.

### Opening the app for the first time

RetroNavigator is not distributed through the Mac App Store and may not be notarized by Apple, so macOS can refuse to open it on the first launch. If that happens:

1. Try to open RetroNavigator once and dismiss the warning.
2. Open **System Settings → Privacy & Security**.
3. Scroll down to the message about RetroNavigator and click **Open Anyway**, then confirm.

Alternatively, remove the download quarantine flag in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/RetroNavigator.app
```

You only need to do this once.

## Using RetroNavigator

### Browsing

Type an address into the **Location** field and press Return. Addresses without a scheme, like `apple.com`, are opened as `http://apple.com`. Click the small tab on the left edge of a toolbar to collapse it, and click the tab again to bring it back — just like in Navigator 4.

### Time travel with the Wayback Machine

Open **RetroNavigator → Settings…** (⌘,), check **Browse the web as it was on a past date**, choose a month, day and year, and click **Apply**. The current page reloads as it looked on that date, and every page you visit from now on comes from the archive.

![Yahoo! in 1999 with the preferences dialog](/Screenshots/screenshot3.png)

Some things to keep in mind:

- The Wayback Machine shows the copy closest to your date. If a page wasn't archived around that time, you may see an older or newer version, or an error page.
- Only static content was archived: forms, logins and searches on old sites generally don't work.
- If the archived copies of a page keep redirecting to each other, RetroNavigator stops after a few attempts and shows a "Loop Detected" page instead of reloading forever. Try a different date.

Uncheck the option to return to the present day.

### Gopherspace

Enter a Gopher address such as `gopher://gopher.floodgap.com/` in the Location field. Menus are shown with Navigator-style icons for folders, documents, searches and images; text documents are shown as plain text, and searchable indexes (like Veronica-2) get a search field. Links to web pages in Gopher menus open in the browser as usual.

![The Floodgap Gopher server](/Screenshots/screenshot6.png)

### WAP pages

Before smartphones, mobile phones browsed the "mobile internet" with WAP: pages written in WML, small black-and-white WBMP images and WMLScript. Almost all WAP sites are gone, so the best way to visit them is through time travel:

1. Turn on time travel in **Settings…** (⌘,) and choose a date between 2000 and 2005.
2. Open a WAP address such as `wap.web.de` or `wap.yahoo.de`.

RetroNavigator recognizes WAP content and shows it on an emulated phone screen with a monochrome LCD, the card title at the top and softkeys at the bottom.

![WEB.DE's WAP portal in 2001](/Screenshots/screenshot7.png)

What's supported:

- **WML decks** — one card at a time with links between cards, timers, `onenterforward`/`onenterbackward`/`ontimer` events, `<do>` softkeys (including deck templates), `<go>`, `<prev>`, `<refresh>` and `<setvar>`, WML variables, input fields, selection lists, tables and text formatting.
- **WBMP images** — decoded and shown in black on the LCD, like on a real phone.
- **WMLScript** — scripts called from WML links (`script.wmls#function()`) run with the standard Lang, Float, String, URL, WMLBrowser and Dialogs libraries. Dialogs appear as classic Mac OS alerts.

Compiled WAP content (binary WMLC and compiled WMLScript), which phones received from WAP gateways, isn't supported. Archived sites usually store the text versions, which work.

### Home page

Set your home page in **Settings…** (⌘,). The Home button and every new launch open it. **Restore Default** brings back the original home page.

## Screenshots

![Google in 1999](/Screenshots/screenshot1.png)
*Google in 1999, shortly after its launch.*

![Yahoo! in 1999](/Screenshots/screenshot2.png)
*Yahoo! in autumn 1999.*

![Preferences dialog](/Screenshots/screenshot3.png)
*The Mac OS 9 style preferences dialog with the Wayback Machine settings.*

![Yahoo! on September 12, 2001](/Screenshots/screenshot4.png)
*Yahoo! on September 12, 2001.*

![CNN.com on September 12, 2001](/Screenshots/screenshot5.png)
*CNN.com on September 12, 2001.*

![Floodgap Gopher menu](/Screenshots/screenshot6.png)
*Browsing Gopherspace on gopher.floodgap.com.*

![WAP page rendering](/Screenshots/screenshot7.png)
*WEB.DE's WAP portal in 2001, shown on the emulated phone screen.*

## How time travel works

RetroNavigator contains a small built-in HTTP proxy, ported from [HttpTimeTravelProxy](https://github.com/jankammerath/HttpTimeTravelProxy). While time travel is enabled, the browser sends all of its requests to this proxy on your Mac (`127.0.0.1`), which fetches the closest archived copy from the Wayback Machine using its raw `id_` mode. Pages arrive exactly as they were archived, without the Wayback Machine's banner or rewritten links.

- Redirects the archived site made are passed on to the browser and followed at the time of the capture that issued them, so redirect chains stay consistent in time.
- Secure (`https://`) requests are answered by the proxy too, using a self-signed certificate bundled with the app. RetroNavigator only trusts that exact certificate, and only while time travel is enabled; all other connections are verified as usual.
- Nothing is sent anywhere except to archive.org. The proxy only listens on your own Mac and isn't reachable from other computers.

## Building from source

Requirements: Xcode 27 or later and macOS 27 or later.

1. Clone the repository:

   ```sh
   git clone https://github.com/jankammerath/RetroNavigator.git
   ```

2. Open `RetroNavigator.xcodeproj` in Xcode.
3. Select your development team under **Signing & Capabilities**.
4. Choose **Product → Run** (⌘R).

### Publishing a release

The download button always points to the file `RetroNavigator.zip` attached to the latest GitHub release. To publish a new version:

1. In Xcode, choose **Product → Archive**, then **Distribute App → Direct Distribution** (this signs and notarizes the app with a Developer ID certificate) and export it.
2. Zip the exported app, keeping the bundle intact:

   ```sh
   ditto -c -k --keepParent RetroNavigator.app RetroNavigator.zip
   ```

3. Create a new release on GitHub and attach the file, named exactly **RetroNavigator.zip**.

## Credits

- Archived pages are provided by the [Internet Archive's Wayback Machine](https://web.archive.org). Please consider [supporting the Internet Archive](https://archive.org/donate).
- The time travel proxy is based on [HttpTimeTravelProxy](https://github.com/jankammerath/HttpTimeTravelProxy).
- Gopher screenshots show the [Floodgap](gopher://gopher.floodgap.com/) Gopher server.
- Netscape and Netscape Navigator are trademarks of their respective owners. RetroNavigator is an independent hobby project and is not affiliated with or endorsed by them.

## License

RetroNavigator is licensed under the [Mozilla Public License 2.0](LICENSE).
