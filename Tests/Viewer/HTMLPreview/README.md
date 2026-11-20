# HTML preview manual acceptance (not yet executed)

Copy this whole fixture directory into an app-owned test workspace, preserving
its layout. Open `index.html` from the built DEB. Do not use a real trash item
or production data for negative tests.

1. Default: Chinese heading/body and blue local SVG show; CSS gives a pale blue
   background, margin and heading rule; vertical scrolling reaches 底部中文.
   The script-state stays 脚本默认关闭. The anchor scrolls inside the page.
2. Follow `pages/second.htm`. Its title, breadcrumb, Properties, Copy Filename,
   Rename prompt and Share must identify `second.htm`, not `index.html`. Use only
   the disposable copy for rename/share. Open As > Text must edit `second.htm`.
   Reload HTML as a new preview afterward. Within one HTML preview, the original
   directory and enabled session permissions must survive child navigation.
   Missing child pages must never expose the previous page's file actions or
   silently open the initial file as Text. XHTML still uses the text editor.
   Also follow `encoding-gbk.html`: both its heading and the CSS-generated suffix
   must display 中文. Both fixture files are real GBK bytes, not UTF-8 stand-ins.
3. Ellipsis > HTML Preview > Allow JavaScript reloads the real page; its state
   becomes 脚本已开启（仅本次预览）. Turn it off to restore the original string.
   Close/reopen the preview and confirm both permissions start off again.
4. While staying in the HTML renderer, use a controlled HTTPS resource/server to
   observe zero requests while HTTPS is off, successful allowed HTTPS loads after
   enabling, and rejection of HTTP,
   WSS, custom-app URLs, redirects to disallowed schemes and downloads. Do not
   infer network isolation merely because an image was blank.
5. Tap the explicit HTTPS link: the standard Fila card must show its URL and
   explain that Safari opens inside Fila. Cancel/dismiss opens nothing; Open
   finishes dismissing the card before presenting the system Safari interface,
   not initially dispatching the URL to a default-browser or associated app.
   Repeat a link while a card/browser is already open; close, replace or reload
   the preview during the card: no duplicate or stale Safari presentation.
   Safari follows its own browsing policy, not the HTML JavaScript/HTTPS toggles;
   those permissions and the local root FD must not be passed to it. Closing
   Safari returns to the same preview/session; closing/reopening HTML resets its
   toggles. Later user actions in Safari, including its browser-app control, are
   system-managed, not a global no-app-handoff guarantee from Fila.
   JavaScript-on WebRTC isolation also remains an unpassed runtime gate. With
   JavaScript enabled, open `rtc-check.html` with HTTPS off and then on: the main
   page and every permitted child frame must report RTC constructors absent.
   Record srcdoc/data/blob frames separately: a blocked or missing frame is not a
   passing exposure test. The target=_blank link and window.open button must open
   no page, tab, browser or associated app. Use controlled ICE/STUN/TURN endpoints
   and a traffic capture as well; this fixture deliberately creates no connection
   and is not proof of zero traffic. In isolated test builds, unsupported selector
   signatures and failed false-readback must prevent WKWebView construction and
   offer explicit failure, Retry and Text. Do not change preferences in the live
   app for negative tests, test untrusted scripted input, or treat source/selector
   inspection or CSP/content rules as proof of RTC isolation.
6. In disposable copies, reference a missing CSS file, encoded traversal, NUL,
   double encoding, another session host, an intermediate symlink and a final
   symlink. No outside bytes should be delivered. Expect explicit failure, a
   manual Retry, and Text under the HTML Preview/Open As menu, never body text
   pretending to be a successfully rendered page.
7. Close/switch/reload rapidly during pending opens and large resource reads;
   old callbacks must not change the replacement page and FD counts must return
   to baseline after work settles. Repeated process termination must not loop.
8. Open an Office/iWork/RTF sample and a text editor; verify conversion, editing,
   save/discard, shared file menu, navigation and overview animations still work.

All runtime items above require a built/signed app. Source-contract checks and
host URL/syscall tests do not establish these UI/WebKit results.
