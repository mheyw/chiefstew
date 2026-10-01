# Mockup

`states.html` shows every v1 menu-bar and panel state; `states.png` is its render. Re-render after editing:

```sh
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --hide-scrollbars \
  --force-device-scale-factor=2 --window-size=1064,1625 \
  --screenshot="$PWD/states.png" "file://$PWD/states.html"
```
