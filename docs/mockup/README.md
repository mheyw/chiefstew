# Overview

`overview.png` is a one-page overview of Chief Stew: what it is, how it knows, the menu-bar icon, the panel in each
main state, notifications, the window, and setting up a repo. `overview.html` is its source.

The panel and window images in `img/` are the app's own offscreen renders, from the UI snapshot tests, so they match
the current code. All repos, builds and people in them are invented. After a UI change, re-render:

```sh
docs/mockup/render.sh
```

It runs the UI snapshot tests, copies the renders it uses into `img/`, and screenshots the page with Chrome.
