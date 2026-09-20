# V1 release checklist

A RiftVM release is ready when every item below passes on a real Omarchy guest
on this Mac. Unit tests and CI prove the code builds and its pure logic holds;
they cannot see a second cursor, a missing wallpaper or a lost click, so none of
these items may be skipped because CI is green.

Record the result of each run (date, RiftVM build, factory image, pass/fail and
a note) in the release note. When an item fails, attach the file from
**Omarchy ▾ → Save Diagnostics…** to the bug instead of describing it from
memory.

## Automated gates

Run before the manual pass; each must succeed.

```sh
swift build --build-tests && swift test --skip-build --filter RiftVMCoreTests
swift test --skip-build --filter RiftVMCLIKitTests
swift test --package-path Experiments/VZVirtioGPUPrototype
scripts/test-virgl-context-sync.sh
(cd GuestAgent/linux && go test ./... && GOOS=linux GOARCH=arm64 go vet ./...)
xcodebuild test -project RiftVM/RiftVM.xcodeproj -scheme RiftVMIntegrationTests \
  -allowProvisioningUpdates -only-testing:RiftVMIntegrationTests/RiftVMOmarchyTests
```

In the image repository, `tests/run` against an `omarchy-aarch64` checkout.

## Start and display

1. Cold start from a stopped machine goes full screen and reaches the desktop
   with no mode change after login (the display log line
   `VirGL display kept` appears; `display mode requested` does not).
2. The wallpaper is present after 10 consecutive cold starts.
3. The wallpaper is present after 5 host sleep/wake cycles with Omarchy running.
4. Leaving full screen, resizing the window and returning keeps the wallpaper
   and the guest mode (`hyprctl monitors` reports the boot size throughout).
5. Pause and resume keeps the desktop, wallpaper and input.

## Cursor

6. Exactly one pointer everywhere on the desktop, the terminal and a browser.
7. The pointer takes the guest's shape: an I-beam over terminal text, resize
   arrows on a window border.
8. Typing hides the pointer (Omarchy's `hide_on_key_press`); moving the mouse
   brings exactly one back.
9. The macOS arrow appears over the letterbox bars and the menu bar, and the
   guest cursor returns on re-entry.
10. During a screenshot selection and cursor zoom there is still one pointer.

## Input

11. 200 consecutive clicks on a button all register (count them in a web page
    or a terminal counter).
12. Click-and-drag selects text and moves a window by its title bar.
13. Right click and middle click open their menus and paste.
14. A fast typed paragraph has no lost, doubled or reordered characters.
15. Holding a key repeats it at a steady rate with no burst when it starts.
16. Caps Lock acts as Compose on every press (`Caps`, `'`, `e` → `é`, twice in a
    row).
17. `Command+Return` opens a terminal, `Command+K` shows the key bindings.
18. Vertical trackpad scrolling in a browser moves at a comfortable speed;
    horizontal scrolling moves a wide page sideways.
19. Holding a key while stopping or restarting the guest Agent leaves no key
    stuck after it reconnects.

## Graphics

20. 30 minutes of browser scrolling and a playing video show no flicker,
    partial frames or garbage, and the graphics log reports no presentation
    failures or fence timeouts.

## Clipboard (regression only)

21. Text and an image copy both ways between macOS and Omarchy.

## Shared folders

22. `ls -a /mnt/mac` shows `.riftvm` and one directory per shared
    folder; a file written on either side appears on the other.
23. A read-only folder refuses writes in Omarchy. Removing or adding a folder
    while Omarchy runs shows "Omarchy sees these changes after it restarts" and
    leaves running programs in shared folders untouched; after **Restart
    Omarchy** the new list is in place.
24. With every folder removed or read-only, the clipboard still works both ways.

## Developer day

25. Run the scripted developer pass ([Tools/DeveloperDay](../Tools/DeveloperDay/README.md)), described in the
    [0.4.0 record](validation/v0.4.0-developer-day-2026-09-19/README.md): Git,
    a Vite React build with HMR, Docker Compose, a pacman install and removal,
    and VS Code editing, plus the Command-as-Super shortcuts on an empty
    workspace.
