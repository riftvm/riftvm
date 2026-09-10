# Chinese input in Omarchy

Install and configure your input method inside Omarchy. RiftVM does not preinstall
or enable a Chinese input engine, and Mac input-method passthrough is not planned.
Clipboard exchange remains available for Chinese text.

## Install an input engine

In an Omarchy terminal, install the engine and configuration tool:

```sh
omarchy pkg add fcitx5-chinese-addons
omarchy pkg add fcitx5-configtool
fcitx5-configtool
```

Keep **Keyboard — English (US)** in the input-method list and add **Pinyin** or
**Shuangpin**. For Xiaohe double pinyin, choose **Xiaohe** in Shuangpin's settings.
Choose your switching shortcut in Global Options.

This follows [Omarchy's input-method setup](https://github.com/omacom/omarchy/blob/quattro/manual/34-keyboard-mouse-trackpad.md).

## If tapping Shift does not switch languages

Omarchy's `shift:both_capslock_cancel` keyboard option conflicts with Fcitx's
modifier-only Shift shortcut. The Shift release can be interpreted as Caps Lock.
See [the upstream report](https://github.com/basecamp/omarchy/issues/7440).

To use Shift for switching, remove `shift:both_capslock_cancel` from `kb_options`
in `~/.config/hypr/input.lua`. If that option is inherited from Omarchy's defaults,
add an override such as:

```lua
hl.config({
  input = {
    kb_options = "compose:caps",
  },
})
```

Preserve any other keyboard options you use, then run `hyprctl reload`.
Removing this option also removes the two-Shift Caps Lock behavior. Alternatively,
keep the default mapping and choose a different input-method shortcut.

## Check your setup

Type `nihao` with Pinyin or `nihc` with Xiaohe. Select `你好` from the candidates,
press Space to commit, and check that Backspace removes one Chinese character.
Switch to English and type `english-ok`. Check the apps you use, since their
input-method support can differ.
