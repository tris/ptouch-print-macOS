# P-Touch Bridge for iOS

A small iOS app that prints labels on a Brother **PT-P910BT** over Bluetooth
when a web page asks it to. The web page puts the whole label into a URL:

```
ptouchbridge://print?text=Hello&x-success=https://example.com/done
```

iOS opens the app, the app connects to the printer, renders and prints the
label, then opens the `x-success` URL to send the user back to the web page.

It uses the same printer protocol as the macOS `ptouch-print` tool on the
`pt-p910bt` branch (reset, status, raster mode, print information, PackBits
raster lines, wait for the printer before disconnecting).

## How it talks to the printer

The PT-P910BT is a Bluetooth Classic printer. macOS reaches it through its
Serial Port Profile service; iOS does not let apps use SPP. The printer also
offers an Apple iAP service (the one `btMac.m` skips): it is an MFi
accessory, and iOS apps reach those through the **ExternalAccessory**
framework. The app declares Brother's protocol string in `Info.plist`:

```xml
<key>UISupportedExternalAccessoryProtocols</key>
<array><string>com.brother.ptcbp</string></array>
```

and sends the same raster commands over that session.

What this means in practice:

- **Pair the printer first**, in the app (Pair a printer…) or in iOS
  Settings > Bluetooth. After that iOS connects to it by itself whenever it
  is switched on; the app waits up to 10 seconds for it.
- **Building for your own devices works** with any Apple developer account
  (free or paid) through Xcode.
- **App Store or TestFlight distribution does not**, unless Brother adds the
  app to its MFi accessory list (Apple's review requires that for any app
  declaring an accessory's protocol). Brother's own SDK apps go through that
  process. A free account's builds also expire after 7 days.
- **Only the PT-P900 series** (560 pin, 360 dpi head) is supported, as in
  the macOS tool. Other Brother MFi printers answer to the same protocol
  string but need different raster data.

## Building

1. Open `ios/PTouchBridge.xcodeproj` in Xcode 16 or later.
2. Select the PTouchBridge target > Signing & Capabilities, choose your team,
   and change the bundle identifier if Xcode asks for a unique one.
3. Run it on an iPhone or iPad (iOS 16 or later). The simulator builds, but
   has no Bluetooth accessories.

The platform independent parts have quick checks:

```sh
swiftc ios/PTouchBridge/Sources/{RasterCommands,PrintRequest}.swift ios/Tests/main.swift -o /tmp/checks && /tmp/checks
```

## URL format

```
ptouchbridge://print?<parameters>
ptouchbridge://x-callback-url/print?<parameters>
```

Parameters are ordinary query parameters; `URLSearchParams` encoding
(including `+` for spaces) works.

| Parameter | Default | Meaning |
|---|---|---|
| `text` | | A line of text. Repeat it for more lines, or put `\n` in it. |
| `image` | | A PNG or JPEG instead of text, base64 or base64url encoded; a `data:image/png;base64,` prefix is fine. The image's height runs across the tape. |
| `scale` | `down` | Images only. `down`: shrink to the tape's printable height if taller. `fit`: scale up or down to that height. `none`: print 1:1, fail if too tall. |
| `font` | `Helvetica` | An iOS font name, such as `Helvetica-Bold`, `Menlo-Regular`, `AvenirNext-DemiBold`. Unknown names fall back to the system font. |
| `fontsize` | auto | Font size in pixels (360 per inch). By default the largest size where all lines fit across the tape. |
| `align` | `left` | `left`, `center` or `right`, for multi-line text. |
| `pad` | `0` | Blank pixels before and after the content, along the tape. |
| `copies` | `1` | 1 to 99. Copies are cut apart. |
| `cut` | `1` | `0` to leave the last label uncut. |
| `printer` | any | Use the connected printer whose name, model or serial number contains this. |
| `x-success` | | Opened after printing. |
| `x-error` | | Opened when anything fails, with `errorCode` and `errorMessage` added to its query. |

Printable height across the tape at 360 dpi: 3.5 mm 48 px, 6 mm 64 px,
9 mm 106 px, 12 mm 150 px, 18 mm 234 px, 24 mm 320 px, 36 mm 454 px. The app
reads the loaded tape from the printer, so a request does not need to know.

Requests that arrive while one is printing are queued.

### From a web page

```js
function printLabel(params) {
  const here = location.href.split('#')[0];
  const q = new URLSearchParams(params);
  q.set('x-success', here + '#printed');
  q.set('x-error', here + '#print-error');
  location.href = 'ptouchbridge://print?' + q.toString();
}

printLabel([['text', 'Box 42'], ['text', 'Cables'], ['copies', '2']]);

// or an image drawn on a canvas
printLabel({ image: canvas.toDataURL('image/png'), scale: 'fit' });
```

[`example/index.html`](example/index.html) is a complete page with both.

## Fewer taps

- Safari asks "Open in P-Touch Bridge?" every time a page opens a custom
  scheme URL. iOS has no setting to turn that off.
- **Universal links avoid that prompt.** The app already handles
  `https://<your domain>/…/print?<same parameters>`. To turn it on, add the
  Associated Domains capability with `applinks:<your domain>` (needs a paid
  developer account) and serve
  `https://<your domain>/.well-known/apple-app-site-association`:

  ```json
  { "applinks": { "details": [ {
      "appIDs": ["<TEAM ID>.com.github.tris.PTouchBridge"],
      "components": [ { "/": "/ptouch/print" } ]
  } ] } }
  ```

  Then link to `https://<your domain>/ptouch/print?text=…`. iOS only opens
  the app for a link the user taps on a page of *another* domain than the
  link's; serve the link from a different (sub)domain than the web app, and
  have that URL show a fallback page for devices without the app.
- Opening `x-success` brings Safari back, in a new tab if the page's tab was
  closed. Leave it out to stay in the app; the user can then go back with the
  "◀ Safari" button in the status bar.
